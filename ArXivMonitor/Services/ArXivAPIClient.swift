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
                    let escaped = escapeQuery(kw)
                    switch scope {
                    case .title:
                        return "ti:\(escaped)"
                    case .abstract:
                        return "abs:\(escaped)"
                    case .titleAndAbstract:
                        return "(ti:\(escaped) OR abs:\(escaped))"
                    }
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

    /// Fetch a single page with one retry on transient failures (timeout, HTTP 5xx).
    /// 4xx responses are returned without retry; the caller decides how to react.
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
            // Retry once on 5xx
            if httpResponse.statusCode >= 500 && httpResponse.statusCode < 600 {
                try await Task.sleep(nanoseconds: retryBackoffNanoseconds)
                let (retryData, retryResponse) = try await session.data(from: url)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw ArXivError.httpError(-1)
                }
                return (retryData, retryHTTP)
            }
            return (data, httpResponse)
        } catch let error as URLError where Self.transientURLErrorCodes.contains(error.code) {
            // Retry once on transient transport errors
            try await Task.sleep(nanoseconds: retryBackoffNanoseconds)
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ArXivError.httpError(-1)
            }
            return (data, httpResponse)
        }
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

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "Invalid search query"
        case .httpError(let code): return "HTTP error \(code)"
        case .parseError: return "Failed to parse arXiv response"
        }
    }
}
