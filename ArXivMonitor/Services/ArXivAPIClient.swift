import Foundation

struct ArXivAPIClient {
    private static let baseURL = "https://export.arxiv.org/api/query"
    private static let maxResults = 100

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Build the arXiv API query URL for a saved search.
    static func buildQueryURL(for search: SavedSearch) -> URL? {
        let queryParts = search.clauses.map { clause -> String in
            switch clause.field {
            case .category:
                return "cat:\(escapeQuery(clause.value))"
            case .author:
                return "au:\(escapeQuery(clause.value))"
            case .keyword:
                let escaped = escapeQuery(clause.value)
                switch clause.scope ?? .titleAndAbstract {
                case .title:
                    return "ti:\(escaped)"
                case .abstract:
                    return "abs:\(escaped)"
                case .titleAndAbstract:
                    return "(ti:\(escaped) OR abs:\(escaped))"
                }
            }
        }

        guard !queryParts.isEmpty else { return nil }
        let separator = search.combineOperator == .or ? " OR " : " AND "
        var searchQuery = queryParts.joined(separator: separator)

        // For keyword/mixed searches, restrict to past 90 days via submittedDate
        if !search.isAuthorOnly {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMddHHmm"
            dateFormatter.timeZone = TimeZone(identifier: "UTC")
            let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
            let startDate = dateFormatter.string(from: ninetyDaysAgo)
            let endDate = dateFormatter.string(from: Date())
            searchQuery = "(\(searchQuery)) AND submittedDate:[\(startDate) TO \(endDate)]"
        }

        // Build URL manually to preserve literal brackets in submittedDate:[... TO ...]
        // URLComponents percent-encodes brackets (%5B/%5D) which arXiv does not recognize.
        guard let encodedQuery = searchQuery.addingPercentEncoding(
            withAllowedCharacters: .arXivQueryAllowed
        ) else { return nil }
        let urlString = "\(baseURL)?search_query=\(encodedQuery)&sortBy=lastUpdatedDate&sortOrder=descending&max_results=\(maxResults)"
        return URL(string: urlString)
    }

    /// Fetch papers for a saved search from the arXiv API.
    static func fetch(search: SavedSearch) async throws -> [MatchedPaper] {
        guard let url = buildQueryURL(for: search) else {
            throw ArXivError.invalidQuery
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ArXivError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let papers = try XMLAtomParser.parse(data: data)

        if papers.count >= maxResults {
            print("[ArXivMonitor] Warning: results may be truncated for search '\(search.name)' (got \(papers.count) results)")
        }

        return papers
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
        set.insert(charactersIn: "[]():") // arXiv needs these literally
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
