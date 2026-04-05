import Foundation

struct ArXivAPIClient {
    private static let baseURL = "https://export.arxiv.org/api/query"
    private static let maxResults = 100

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

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
        var searchQuery = queryParts.joined(separator: separator)

        // Apply date restriction using the search's effective "from" date
        if let fromDate = search.effectiveFetchFromDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMddHHmm"
            dateFormatter.timeZone = TimeZone(identifier: "UTC")
            let startDate = dateFormatter.string(from: fromDate)
            let endDate = dateFormatter.string(from: Date())
            searchQuery = "(\(searchQuery)) AND submittedDate:[\(startDate) TO \(endDate)]"
        }

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

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ArXivError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
            }

            let result = try XMLAtomParser.parse(data: data)

            // Update totalResults from the first page response
            if start == 0 {
                totalResults = result.totalResults
                if totalResults > maxTotalResults {
                    print("[ArXivMonitor] Query for '\(search.name)' matches \(totalResults) results, capping at \(maxTotalResults)")
                }
            }

            allPapers.append(contentsOf: result.papers)

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

    /// Escape special characters in query values for arXiv API.
    private static func escapeQuery(_ value: String) -> String {
        // Wrap multi-word values in quotes for phrase matching
        if value.contains(" ") {
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
        set.insert(charactersIn: "():") // arXiv needs these literally
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
