import Foundation

struct ArXivAPIClient {
    private static let baseURL = "https://export.arxiv.org/api/query"
    private static let maxResults = 100

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    /// Backoff between the initial request and a single retry on transient failures.
    /// Tests override this to keep the suite fast (~1ms).
    static var retryBackoffNanoseconds: UInt64 = 5_000_000_000

    /// Backoff between the initial request and a single retry on HTTP 429
    /// (rate limiting). Semantically distinct from `retryBackoffNanoseconds`
    /// — 429 means the server is explicitly telling us to slow down, so a
    /// longer wait is warranted. Overridden only if `Retry-After` parsing
    /// finds a shorter/longer value (bounded to [15, 120] seconds) at the
    /// call site. Tests override the base default to keep the suite fast.
    static var rateLimitedBackoffNanoseconds: UInt64 = 30_000_000_000

    /// Test-only cap on the effective 429 backoff (including a server
    /// `Retry-After` value). Production leaves this at `UInt64.max` so the
    /// server-provided delay is honored in full. Tests lower it (alongside
    /// `rateLimitedBackoffNanoseconds`) so suites stay fast regardless of
    /// which stub path the fixture exercises.
    static var rateLimitedBackoffCapNanoseconds: UInt64 = .max

    /// Maximum jitter (in nanoseconds) added on top of the 5xx backoff.
    /// De-correlates retries if multiple searches ever hit a transient
    /// failure at the same time. Tests override this to 0 so timing stays
    /// deterministic.
    static var retryJitterMaxNanoseconds: UInt64 = 1_000_000_000

    /// Maximum jitter (in nanoseconds) added on top of the 429 backoff.
    /// Larger than `retryJitterMaxNanoseconds` because parallel rate-limited
    /// searches are more likely to retry in lockstep than transient 5xx ones.
    /// Tests override this to 0 so timing stays deterministic.
    static var rateLimitedJitterMaxNanoseconds: UInt64 = 5_000_000_000

    /// URLError codes that indicate a transient transport failure worth retrying.
    /// `timedOut` is the most common; the other two are common on menu-bar apps
    /// that survive Wi-Fi sleeps and network reconfigurations.
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
    ]

    /// Build the arXiv API query URL for a saved search, with pagination offset.
    static func buildQueryURL(for search: SavedSearch, start: Int = 0) -> URL? {
        let queryParts = search.clauses.map { clause -> String in
            switch clause.field {
            case .category:
                let cats = clause.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if cats.count > 1 {
                    let parts = cats.map { "cat:\($0)" }
                    return "(\(parts.joined(separator: " OR ")))"
                }
                return "cat:\(escapeQuery(clause.value.trimmingCharacters(in: .whitespaces)))"
            case .author:
                return "au:\(escapeQuery(clause.value))"
            case .keyword:
                let keywords = clause.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let scope = clause.scope ?? .titleAndAbstract
                let keywordParts = keywords.map { kw -> String in
                    // Explicit-phrase escape hatch: if the user wraps the
                    // keyword in literal double quotes, treat the inside as a
                    // single phrase token (preserving the pre-2026 behavior
                    // for users who want it).
                    if kw.hasPrefix("\"") && kw.hasSuffix("\"") && kw.count >= 2 {
                        let inner = String(kw.dropFirst().dropLast())
                        let escaped = escapeQuery(inner)
                        switch scope {
                        case .title:
                            return "ti:\(escaped)"
                        case .abstract:
                            return "abs:\(escaped)"
                        case .titleAndAbstract:
                            return "(ti:\(escaped) OR abs:\(escaped))"
                        }
                    }

                    // Website-equivalent behavior: split multi-word keywords
                    // on whitespace and AND the tokens within the scope. This
                    // matches papers where the words appear non-adjacently,
                    // whereas wrapping as a Lucene phrase would not. Each
                    // token still goes through escapeQuery so hyphens in a
                    // single token (e.g. "Gromov-Witten") remain quoted.
                    let tokens = kw
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                        .filter { !$0.isEmpty }
                    let tokenParts = tokens.map { tok -> String in
                        let escaped = escapeQuery(tok)
                        switch scope {
                        case .title:
                            return "ti:\(escaped)"
                        case .abstract:
                            return "abs:\(escaped)"
                        case .titleAndAbstract:
                            return "(ti:\(escaped) OR abs:\(escaped))"
                        }
                    }
                    if tokenParts.count > 1 {
                        return "(\(tokenParts.joined(separator: " AND ")))"
                    }
                    return tokenParts.first ?? ""
                }
                if keywordParts.count > 1 {
                    return "(\(keywordParts.joined(separator: " OR ")))"
                }
                return keywordParts.first ?? ""
            }
        }

        guard !queryParts.isEmpty else { return nil }
        let separator = search.combineOperator == .or ? " OR " : " AND "
        let searchQuery = queryParts.joined(separator: separator)

        // Bug 1B: date filtering is performed CLIENT-SIDE in fetch(), not here.
        // The arXiv API silently drops `lastUpdatedDate` as a search_query field
        // (it is only valid as a `sortBy` argument), and a `submittedDate`-only
        // filter would exclude revisions of older papers (e.g. 2504.14273 was
        // submitted 2025-04 but revised 2026-03 — a 90-day submittedDate window
        // in 2026 would miss it). We instead rely on
        // `sortBy=lastUpdatedDate&sortOrder=descending` plus a post-parse filter
        // on `MatchedPaper.updatedAt`. The user's explicit `fetchFromDate` and
        // the implicit 90-day default are both honored via
        // `SavedSearch.effectiveFetchFromDate`, passed to
        // `applyDateFilter(_:fromDate:)` during pagination.

        // Build URL manually to preserve colons, parentheses, and other query operators
        // that arXiv expects in the search_query parameter.
        guard let encodedQuery = searchQuery.addingPercentEncoding(
            withAllowedCharacters: .arXivQueryAllowed
        ) else { return nil }
        let urlString = "\(baseURL)?search_query=\(encodedQuery)&sortBy=lastUpdatedDate&sortOrder=descending&start=\(start)&max_results=\(maxResults)"
        return URL(string: urlString)
    }

    /// Maximum total results to fetch across all pages (safety cap).
    private static let maxTotalResults = 1000

    /// Fetch papers for a saved search from the arXiv API, paginating to get all results.
    /// - Parameters:
    ///   - search: The saved search to query.
    ///   - progressHandler: Called with (currentPage, estimatedTotalPages) before each page fetch.
    /// - Returns: All matching papers across all pages.
    static func fetch(
        search: SavedSearch,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async throws -> [MatchedPaper] {
        var allPapers: [MatchedPaper] = []
        var start = 0
        var totalResults = 0
        var currentPage = 1

        repeat {
            guard let url = buildQueryURL(for: search, start: start) else {
                throw ArXivError.invalidQuery
            }

            // Report progress before fetching
            let estimatedPages = totalResults > 0
                ? max(1, Int(ceil(Double(min(totalResults, maxTotalResults)) / Double(maxResults))))
                : 1
            progressHandler?(currentPage, estimatedPages)

            // 3-second delay between pages (skip before first page)
            if start > 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }

            let (data, httpResponse) = try await fetchWithRetry(url: url)

            guard httpResponse.statusCode == 200 else {
                // 429 should have been handled inside fetchWithRetry (either
                // retried to success or thrown as .rateLimited). Still map
                // it explicitly here so a straggler can't surface as a
                // generic httpError(429) and bypass the friendlier UI path.
                if httpResponse.statusCode == 429 {
                    throw ArXivError.rateLimited(retryAfterSeconds: nil)
                }
                throw ArXivError.httpError(httpResponse.statusCode)
            }

            let result = try XMLAtomParser.parse(data: data)

            // Update totalResults from the first page response
            if start == 0 {
                totalResults = result.totalResults
                if totalResults > maxTotalResults {
                    print("[ArXivMonitor] Query for '\(search.name)' matches \(totalResults) results, capping at \(maxTotalResults)")
                }
            }

            // Bug 1B: client-side date filter. Server-side filtering can't
            // catch revisions of older papers (the arXiv API silently drops
            // `lastUpdatedDate` as a query field), so we filter the parsed
            // page here using `updatedAt`. Pagination stops as soon as a page
            // contains any paper outside the window — subsequent pages
            // (sorted by lastUpdatedDate descending) are guaranteed older.
            let filterResult = ArXivAPIClient.applyDateFilter(
                result.papers,
                fromDate: search.effectiveFetchFromDate
            )
            allPapers.append(contentsOf: filterResult.kept)

            if filterResult.reachedCutoff {
                break
            }

            // If this page returned fewer results than max_results, we've hit the end
            if result.papers.count < maxResults {
                break
            }

            start += maxResults
            currentPage += 1

            // Safety cap: don't fetch beyond maxTotalResults
            let effectiveTotal = min(totalResults, maxTotalResults)
            if start >= effectiveTotal {
                break
            }
        } while true

        return allPapers
    }

    /// Fetch a single page with one retry on transient failures (timeout, HTTP 5xx, HTTP 429).
    /// 4xx responses other than 429 are returned without retry; the caller decides how to react.
    /// - Parameters:
    ///   - url: The URL to GET.
    ///   - session: URLSession to use. Defaults to the shared `ArXivAPIClient.session`.
    ///     Tests inject a session backed by a `URLProtocol` stub.
    static func fetchWithRetry(
        url: URL,
        session: URLSession = ArXivAPIClient.session
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ArXivError.httpError(-1)
            }
            // Retry once on 429 (rate limited). Honor a `Retry-After` header
            // if present; otherwise default to 30 seconds. Bounded so the
            // server can't stall us for many minutes.
            if httpResponse.statusCode == 429 {
                // Compute the EFFECTIVE cooldown once (applies the [15, 120]s
                // clamp) and thread the same value through both the sleep and
                // any thrown error. Using the raw parsed value in the error
                // would let the UI cooldown age out before the client's
                // actual retry wait elapses (e.g. Retry-After: 1 => wait 15s
                // but popover invites retry after 1s).
                let firstEffective = Self.effectiveRetryAfterSeconds(parseRetryAfter(from: httpResponse))
                let baseNanos = rateLimitedBackoffNanoseconds(forEffectiveSeconds: firstEffective)
                let jitterNanos = rateLimitedJitterMaxNanoseconds > 0
                    ? UInt64.random(in: 0..<rateLimitedJitterMaxNanoseconds)
                    : 0
                try await Task.sleep(nanoseconds: baseNanos &+ jitterNanos)
                let (retryData, retryResponse) = try await session.data(from: url)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw ArXivError.httpError(-1)
                }
                if retryHTTP.statusCode == 429 {
                    // Prefer the retry response's Retry-After (may have
                    // shifted); fall back to the first one if absent. Either
                    // way, surface the clamped/effective value so the UI and
                    // the client agree on the cooldown.
                    let retryEffective = Self.effectiveRetryAfterSeconds(parseRetryAfter(from: retryHTTP)) ?? firstEffective
                    throw ArXivError.rateLimited(retryAfterSeconds: retryEffective)
                }
                return (retryData, retryHTTP)
            }
            // Retry once on 5xx
            if httpResponse.statusCode >= 500 && httpResponse.statusCode < 600 {
                let jitterNanos = retryJitterMaxNanoseconds > 0
                    ? UInt64.random(in: 0..<retryJitterMaxNanoseconds)
                    : 0
                try await Task.sleep(nanoseconds: retryBackoffNanoseconds &+ jitterNanos)
                let (retryData, retryResponse) = try await session.data(from: url)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw ArXivError.httpError(-1)
                }
                return (retryData, retryHTTP)
            }
            return (data, httpResponse)
        } catch let error as URLError where Self.transientURLErrorCodes.contains(error.code) {
            // Retry once on transient transport errors
            let jitterNanos = retryJitterMaxNanoseconds > 0
                ? UInt64.random(in: 0..<retryJitterMaxNanoseconds)
                : 0
            try await Task.sleep(nanoseconds: retryBackoffNanoseconds &+ jitterNanos)
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ArXivError.httpError(-1)
            }
            return (data, httpResponse)
        }
    }

    /// Parse an HTTP `Retry-After` header into seconds. Accepts either an
    /// integer seconds value or an HTTP-date (RFC 1123). Returns nil if the
    /// header is missing or unparseable.
    static func parseRetryAfter(from response: HTTPURLResponse) -> Int? {
        // Header lookup is case-insensitive per RFC 7231.
        let raw: String?
        if let v = response.value(forHTTPHeaderField: "Retry-After") {
            raw = v
        } else if let v = response.allHeaderFields["Retry-After"] as? String {
            raw = v
        } else {
            raw = nil
        }
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = Int(value) {
            return seconds
        }
        // HTTP-date: try RFC 1123 first, then a couple of common variants.
        let formatters: [DateFormatter] = {
            let rfc1123 = DateFormatter()
            rfc1123.locale = Locale(identifier: "en_US_POSIX")
            rfc1123.timeZone = TimeZone(identifier: "GMT")
            rfc1123.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return [rfc1123]
        }()
        for f in formatters {
            if let date = f.date(from: value) {
                let delta = Int(date.timeIntervalSinceNow.rounded())
                return max(0, delta)
            }
        }
        return nil
    }

    /// Apply the [15, 120]-second clamp both the retry sleep and the thrown
    /// error surface. Returns nil when the server didn't provide a parseable
    /// positive value — the caller then falls back to the configured default
    /// (`rateLimitedBackoffNanoseconds`) and the popover uses a matching
    /// fallback cooldown. Exposed at the type level so tests can assert the
    /// clamp directly and AppState could use it if it ever needed to.
    static func effectiveRetryAfterSeconds(_ raw: Int?) -> Int? {
        guard let raw, raw > 0 else { return nil }
        return min(max(raw, 15), 120)
    }

    /// Compute the base backoff nanoseconds for a 429 retry from the already
    /// clamped effective value. `nil` means fall back to the configured
    /// default. The result is capped by `rateLimitedBackoffCapNanoseconds`
    /// (production: UInt64.max, tests: small) so suites don't stall on
    /// server-supplied long waits.
    private static func rateLimitedBackoffNanoseconds(forEffectiveSeconds effective: Int?) -> UInt64 {
        let base: UInt64
        if let effective {
            base = UInt64(effective) * 1_000_000_000
        } else {
            base = rateLimitedBackoffNanoseconds
        }
        return min(base, rateLimitedBackoffCapNanoseconds)
    }

    /// Result of applying a client-side date filter to a single page of papers.
    /// `kept` are the papers that satisfy `paper.updatedAt >= fromDate`.
    /// `reachedCutoff` is true when at least one paper in the input had
    /// `updatedAt < fromDate` — meaning subsequent pages (sorted by
    /// lastUpdatedDate descending) cannot contain in-window results.
    struct DateFilterResult {
        let kept: [MatchedPaper]
        let reachedCutoff: Bool
    }

    /// Filter a single page of papers by `updatedAt >= fromDate`. Because the
    /// caller fetches with `sortBy=lastUpdatedDate&sortOrder=descending`, once
    /// we see ANY paper with `updatedAt < fromDate`, the caller can stop
    /// paginating.
    ///
    /// Comparison is done lexicographically on canonical ISO8601 UTC strings
    /// (`yyyy-MM-ddTHH:mm:ssZ`), which is chronologically correct because
    /// arXiv emits `<updated>` in exactly that form and we format the cutoff
    /// with the same `ISO8601DateFormatter` options.
    ///
    /// - Parameters:
    ///   - papers: One page of papers, in lastUpdatedDate-descending order.
    ///   - fromDate: Inclusive lower bound. nil means no filtering.
    /// - Returns: kept papers and a `reachedCutoff` flag.
    static func applyDateFilter(_ papers: [MatchedPaper], fromDate: Date?) -> DateFilterResult {
        guard let fromDate else {
            return DateFilterResult(kept: papers, reachedCutoff: false)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]  // UTC, no fractional seconds — matches arXiv <updated> format
        let cutoffString = formatter.string(from: fromDate)

        var kept: [MatchedPaper] = []
        var reachedCutoff = false
        for paper in papers {
            if paper.updatedAt >= cutoffString {
                kept.append(paper)
            } else {
                reachedCutoff = true
                // Do NOT break — defensive: if a single page has ties on
                // updatedAt and they appear in arbitrary order, continue
                // scanning so we don't drop an in-window paper that follows
                // an out-of-window one within the same page. Cross-page
                // ordering is reliable enough for early termination in fetch().
            }
        }
        return DateFilterResult(kept: kept, reachedCutoff: reachedCutoff)
    }

    /// Escape special characters in query values for arXiv API.
    private static func escapeQuery(_ value: String) -> String {
        // Wrap values in quotes when they contain spaces (multi-word phrases)
        // or hyphens (Lucene interprets unquoted hyphens as NOT operator)
        if value.contains(" ") || value.contains("-") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

private extension CharacterSet {
    /// Characters allowed in the arXiv search_query parameter value.
    /// Preserves brackets, colons, and parentheses that arXiv expects literally.
    static let arXivQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=") // must encode these to avoid breaking query string
        set.insert(charactersIn: "()[]:") // arXiv needs these literally for query syntax and date ranges
        return set
    }()
}

enum ArXivError: Error, LocalizedError {
    case invalidQuery
    case httpError(Int)
    case parseError
    case rateLimited(retryAfterSeconds: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "Invalid search query"
        case .httpError(let code): return "HTTP error \(code)"
        case .parseError: return "Failed to parse arXiv response"
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "arXiv is rate-limiting us. Try again in about \(retryAfterSeconds) seconds."
            }
            return "arXiv is rate-limiting us. Try again in a minute."
        }
    }
}
