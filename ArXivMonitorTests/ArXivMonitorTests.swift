import XCTest
@testable import ArXivMonitor

final class ArXivAPIClientTests: XCTestCase {

    // MARK: - Query Building Tests

    func testBuildQueryURL_category() {
        let search = SavedSearch(
            name: "ML papers",
            clauses: [SearchClause(field: .category, value: "cs.LG")]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("cat%3Acs.LG") || query.contains("cat:cs.LG"),
                       "Query should contain cat:cs.LG, got: \(query)")
        XCTAssertTrue(query.contains("sortBy=lastUpdatedDate"))
        XCTAssertTrue(query.contains("max_results=100"))
    }

    func testBuildQueryURL_author() {
        let search = SavedSearch(
            name: "Hinton papers",
            clauses: [SearchClause(field: .author, value: "Hinton")]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("au%3AHinton") || query.contains("au:Hinton"),
                       "Query should contain au:Hinton, got: \(query)")
    }

    func testBuildQueryURL_keywordTitle() {
        let search = SavedSearch(
            name: "Diffusion",
            clauses: [SearchClause(field: .keyword, value: "diffusion", scope: .title)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("ti%3Adiffusion") || query.contains("ti:diffusion"),
                       "Query should contain ti:diffusion, got: \(query)")
    }

    func testBuildQueryURL_keywordAbstract() {
        let search = SavedSearch(
            name: "Flow matching",
            clauses: [SearchClause(field: .keyword, value: "flow matching", scope: .abstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Multi-word value should be quoted
        XCTAssertTrue(query.contains("abs"), "Query should contain abs: prefix, got: \(query)")
    }

    func testBuildQueryURL_keywordTitleAndAbstract() {
        let search = SavedSearch(
            name: "Flow matching",
            clauses: [SearchClause(field: .keyword, value: "flow matching", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Should contain both ti: and abs: with OR
        XCTAssertTrue(query.contains("ti") && query.contains("abs"),
                       "Query should contain both ti: and abs: for titleAndAbstract scope, got: \(query)")
    }

    func testBuildQueryURL_keywordWithDateFilter_noDoubleEncoding() {
        let search = SavedSearch(
            name: "Test",
            clauses: [SearchClause(field: .keyword, value: "diffusion", scope: .titleAndAbstract)],
            fetchFromDate: "2026-03-01"
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertFalse(query.contains("%2520"),
                        "URL should not contain double-encoded spaces: \(query)")
        XCTAssertTrue(query.contains("OR"),
                       "URL should contain OR operator: \(query)")
    }

    func testBuildQueryURL_noDoubleEncodingRoundTrip() {
        let search = SavedSearch(
            name: "Test",
            clauses: [SearchClause(field: .keyword, value: "flow matching", scope: .titleAndAbstract)],
            fetchFromDate: "2026-03-01"
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let abs = url!.absoluteString
        XCTAssertFalse(abs.contains("%2520"), "Double-encoded space found: \(abs)")
        XCTAssertFalse(abs.contains("%2522"), "Double-encoded quote found: \(abs)")
    }

    func testBuildQueryURL_multipleClauses() {
        let search = SavedSearch(
            name: "ML papers by Hinton",
            clauses: [
                SearchClause(field: .category, value: "cs.LG"),
                SearchClause(field: .author, value: "Hinton")
            ]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("AND"), "Multiple clauses should be ANDed, got: \(query)")
    }

    func testBuildQueryURL_emptyClauses() {
        let search = SavedSearch(name: "Empty", clauses: [])
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNil(url, "Empty clauses should produce nil URL")
    }

    func testBuildQueryURL_hyphenatedKeywordIsQuoted() {
        let search = SavedSearch(
            name: "Gromov-Witten",
            clauses: [SearchClause(field: .keyword, value: "Gromov-Witten", scope: .title)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Hyphenated keyword should be quoted (percent-encoded quotes are %22)
        XCTAssertTrue(query.contains("%22Gromov-Witten%22"),
                       "Hyphenated keyword should be quoted in query, got: \(query)")
    }

    func testBuildQueryURL_hyphenatedAuthorIsQuoted() {
        let search = SavedSearch(
            name: "Author search",
            clauses: [SearchClause(field: .author, value: "Kontsevich-Soibelman")]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("%22Kontsevich-Soibelman%22"),
                       "Hyphenated author should be quoted, got: \(query)")
    }

    /// Bug 1B: date filtering is now done CLIENT-SIDE in fetch(). The URL
    /// must NOT contain submittedDate or lastUpdatedDate as a search_query
    /// field, even when the search has an explicit fetchFromDate.
    /// The explicit fetchFromDate value is still honored — it's applied
    /// client-side via SavedSearch.effectiveFetchFromDate and applyDateFilter.
    func testBuildQueryURL_omitsServerSideDateFilter_withExplicitDate() {
        let search = SavedSearch(
            name: "Test",
            clauses: [SearchClause(field: .keyword, value: "test", scope: .title)],
            fetchFromDate: "2026-01-01"
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertFalse(query.contains("submittedDate"),
                       "Date filter must NOT be in search_query — it's applied client-side. Got: \(query)")
        XCTAssertFalse(query.contains("lastUpdatedDate:["),
                       "lastUpdatedDate must NEVER appear as a query field — arXiv API silently ignores it. Got: \(query)")
        // Sort by lastUpdatedDate desc must remain — it's what makes early
        // termination of the client-side filter sound.
        XCTAssertTrue(query.contains("sortBy=lastUpdatedDate"),
                      "Must still sort by lastUpdatedDate desc, got: \(query)")
        XCTAssertTrue(query.contains("sortOrder=descending"),
                      "Sort order must be descending so client-side filter can early-terminate, got: \(query)")
    }

    /// Bug 1B: when fetchFromDate is NOT set, the URL still contains no date
    /// filter (the 90-day default is applied client-side, not server-side).
    func testBuildQueryURL_omitsServerSideDateFilter_noExplicitDate() {
        let search = SavedSearch(
            name: "Gromov-Witten",
            clauses: [SearchClause(field: .keyword, value: "Gromov-Witten", scope: .titleAndAbstract)]
            // fetchFromDate intentionally nil
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertFalse(query.contains("submittedDate"),
                       "No server-side date filter when fetchFromDate is unset, got: \(query)")
        XCTAssertFalse(query.contains("lastUpdatedDate:"),
                       "lastUpdatedDate must NEVER appear as a query field. Got: \(query)")
        XCTAssertTrue(query.contains("sortBy=lastUpdatedDate"),
                      "Must still sort by lastUpdatedDate desc to catch revisions, got: \(query)")
    }
}

// MARK: - Bug 1B: client-side date filter tests

final class ArXivAPIClientDateFilterTests: XCTestCase {
    private func paper(id: String, updatedAt: String) -> MatchedPaper {
        MatchedPaper(
            id: id,
            title: "T",
            authors: "A",
            primaryCategory: "math.AG",
            categories: ["math.AG"],
            publishedAt: updatedAt,
            updatedAt: updatedAt,
            link: "https://arxiv.org/abs/\(id)",
            matchedSearchIDs: [],
            foundAt: "2026-04-07T00:00:00Z",
            isNew: false
        )
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testApplyDateFilter_noFromDateKeepsEverything() {
        let papers = [
            paper(id: "1", updatedAt: "2026-03-09T12:00:00Z"),
            paper(id: "2", updatedAt: "2024-01-01T00:00:00Z"),
        ]
        let result = ArXivAPIClient.applyDateFilter(papers, fromDate: nil)
        XCTAssertEqual(result.kept.map(\.id), ["1", "2"])
        XCTAssertFalse(result.reachedCutoff)
    }

    func testApplyDateFilter_keepsPapersAtOrAfterCutoff() {
        let papers = [
            paper(id: "1", updatedAt: "2026-04-01T00:00:00Z"),
            paper(id: "2", updatedAt: "2026-01-07T00:00:00Z"),  // exactly at cutoff
            paper(id: "3", updatedAt: "2025-12-31T23:59:59Z"),  // before cutoff
        ]
        let result = ArXivAPIClient.applyDateFilter(papers, fromDate: date("2026-01-07T00:00:00Z"))
        XCTAssertEqual(result.kept.map(\.id), ["1", "2"])
        XCTAssertTrue(result.reachedCutoff)
    }

    func testApplyDateFilter_keptAndCutoffWhenLastIsOutOfWindow() {
        // The early-termination case: in-window papers MUST be kept even
        // when the page contains an out-of-window paper at the end.
        let papers = [
            paper(id: "1", updatedAt: "2026-03-09T21:29:57Z"),  // 2504.14273-like
            paper(id: "2", updatedAt: "2026-02-15T00:00:00Z"),
            paper(id: "3", updatedAt: "2025-11-30T00:00:00Z"),  // out of window
        ]
        let result = ArXivAPIClient.applyDateFilter(papers, fromDate: date("2026-01-07T00:00:00Z"))
        XCTAssertEqual(result.kept.map(\.id), ["1", "2"])
        XCTAssertTrue(result.reachedCutoff)
    }

    func testApplyDateFilter_emptyPage() {
        let result = ArXivAPIClient.applyDateFilter([], fromDate: date("2026-01-07T00:00:00Z"))
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertFalse(result.reachedCutoff)
    }

    func testApplyDateFilter_allOutOfWindow() {
        let papers = [
            paper(id: "1", updatedAt: "2024-12-31T00:00:00Z"),
            paper(id: "2", updatedAt: "2024-06-01T00:00:00Z"),
        ]
        let result = ArXivAPIClient.applyDateFilter(papers, fromDate: date("2026-01-07T00:00:00Z"))
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertTrue(result.reachedCutoff)
    }

    func testApplyDateFilter_paper2504_14273IsKept() {
        // Regression test for the original user-reported bug: paper 2504.14273
        // has updatedAt=2026-03-09T21:29:57Z and must be kept by the default
        // 90-day window (Jan 7 2026 cutoff for "today" 2026-04-07).
        let papers = [paper(id: "2504.14273", updatedAt: "2026-03-09T21:29:57Z")]
        let result = ArXivAPIClient.applyDateFilter(papers, fromDate: date("2026-01-07T00:00:00Z"))
        XCTAssertEqual(result.kept.map(\.id), ["2504.14273"])
        XCTAssertFalse(result.reachedCutoff)
    }
}

// MARK: - Bug 2: Retry helper tests

/// URLProtocol stub for testing ArXivAPIClient.fetchWithRetry.
/// Each test sets `MockURLProtocol.responses` to a queue of (status, body, error)
/// tuples; the protocol pops one per request. `error != nil` simulates a transport
/// failure (e.g. timeout); otherwise it returns an HTTPURLResponse with the given status.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        let error: Error?
    }
    static var responses: [Stub] = []
    static var requestCount = 0

    static func reset() {
        responses = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        guard !MockURLProtocol.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = MockURLProtocol.responses.removeFirst()
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.timeoutIntervalForRequest = 5
    return URLSession(configuration: config)
}

final class ArXivAPIClientRetryTests: XCTestCase {
    private let url = URL(string: "https://export.arxiv.org/api/query?search_query=ti:test")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        // Override the 5s production backoff so retry tests run in ~1ms instead of ~5s.
        ArXivAPIClient.retryBackoffNanoseconds = 1_000_000  // 1ms
    }

    override func tearDown() {
        MockURLProtocol.reset()
        ArXivAPIClient.retryBackoffNanoseconds = 5_000_000_000  // restore production default
        super.tearDown()
    }

    /// Bug 2: a 503 followed by a 200 should retry once and return the 200.
    func testFetchWithRetry_retriesOn5xx() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 503, body: Data(), error: nil),
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let (data, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "Should make exactly 2 requests (initial + 1 retry)")
    }

    /// Bug 2: a timeout followed by a 200 should retry once and return the 200.
    func testFetchWithRetry_retriesOnTimeout() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 0, body: Data(), error: URLError(.timedOut)),
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let (data, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "Should make exactly 2 requests (initial + 1 retry)")
    }

    /// Bug 2: networkConnectionLost (Wi-Fi flap) should also be retried.
    /// Locks in the expanded transient-error set.
    func testFetchWithRetry_retriesOnNetworkConnectionLost() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 0, body: Data(), error: URLError(.networkConnectionLost)),
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let (data, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    /// Bug 2: a 4xx must NOT be retried — it indicates a real client error.
    func testFetchWithRetry_doesNotRetryOn4xx() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 400, body: Data(), error: nil),
            .init(status: 200, body: Data("should-not-reach".utf8), error: nil),
        ]

        let (_, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "4xx must not trigger a retry")
    }

    /// Bug 2: a successful first response should not retry.
    func testFetchWithRetry_doesNotRetryOnSuccess() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let (_, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "Successful responses must not trigger a retry")
    }

    /// Bug 2: invariant — at most ONE retry on 5xx. A second 5xx returns
    /// the failure rather than retrying again. Locks in the retry budget.
    func testFetchWithRetry_doesNotDoubleRetryOn5xx() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 503, body: Data(), error: nil),
            .init(status: 503, body: Data(), error: nil),
            .init(status: 200, body: Data("should-not-reach".utf8), error: nil),
        ]

        let (_, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)

        XCTAssertEqual(response.statusCode, 503,
                       "After one retry, a second 5xx should be returned without further retry")
        XCTAssertEqual(MockURLProtocol.requestCount, 2,
                       "Should make exactly 2 requests — initial + 1 retry, never reaching the 200")
    }

    /// Bug 2: invariant — at most ONE retry on timeout. A second timeout
    /// propagates as URLError.timedOut. Locks in the retry budget.
    func testFetchWithRetry_doesNotDoubleRetryOnTimeout() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 0, body: Data(), error: URLError(.timedOut)),
            .init(status: 0, body: Data(), error: URLError(.timedOut)),
            .init(status: 200, body: Data("should-not-reach".utf8), error: nil),
        ]

        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected URLError.timedOut to be thrown after second timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut,
                           "Second timeout should propagate as URLError.timedOut")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 2,
                       "Should make exactly 2 requests — initial + 1 retry, never reaching the 200")
    }
}

final class XMLAtomParserTests: XCTestCase {

    func testParseValidAtomXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:arxiv="http://arxiv.org/schemas/atom">
          <entry>
            <id>http://arxiv.org/abs/2404.12345v1</id>
            <title>A Sample Paper on
              Mirror Symmetry</title>
            <published>2024-04-03T20:00:00Z</published>
            <updated>2024-04-03T20:00:00Z</updated>
            <author><name>Smith, A.</name></author>
            <author><name>Johnson, B.</name></author>
            <arxiv:primary_category term="math.AG"/>
            <category term="math.AG"/>
            <category term="hep-th"/>
            <link href="http://arxiv.org/abs/2404.12345v1" rel="alternate" type="text/html"/>
          </entry>
          <entry>
            <id>http://arxiv.org/abs/2404.67890v2</id>
            <title>Another Paper on Gromov-Witten Invariants</title>
            <published>2024-04-01T18:00:00Z</published>
            <updated>2024-04-03T19:00:00Z</updated>
            <author><name>Chen, L.</name></author>
            <arxiv:primary_category term="math.SG"/>
            <category term="math.SG"/>
            <category term="math.AG"/>
            <link href="http://arxiv.org/abs/2404.67890v2" rel="alternate" type="text/html"/>
          </entry>
        </feed>
        """
        let data = xml.data(using: .utf8)!
        let result = try XMLAtomParser.parse(data: data)
        let papers = result.papers

        XCTAssertEqual(papers.count, 2)

        // First paper
        XCTAssertEqual(papers[0].id, "2404.12345")
        XCTAssertEqual(papers[0].title, "A Sample Paper on Mirror Symmetry")
        XCTAssertEqual(papers[0].authors, "Smith, A., Johnson, B.")
        XCTAssertEqual(papers[0].primaryCategory, "math.AG")
        XCTAssertEqual(papers[0].categories, ["math.AG", "hep-th"])
        XCTAssertEqual(papers[0].publishedAt, "2024-04-03T20:00:00Z")
        XCTAssertEqual(papers[0].updatedAt, "2024-04-03T20:00:00Z")
        XCTAssertEqual(papers[0].link, "https://arxiv.org/abs/2404.12345")
        XCTAssertFalse(papers[0].isRevision) // published == updated

        // Second paper — revision
        XCTAssertEqual(papers[1].id, "2404.67890")
        XCTAssertEqual(papers[1].title, "Another Paper on Gromov-Witten Invariants")
        XCTAssertEqual(papers[1].authors, "Chen, L.")
        XCTAssertEqual(papers[1].primaryCategory, "math.SG")
        XCTAssertEqual(papers[1].categories, ["math.SG", "math.AG"])
        XCTAssertTrue(papers[1].isRevision) // updated > published
    }

    func testParseEmptyFeed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        </feed>
        """
        let data = xml.data(using: .utf8)!
        let result = try XMLAtomParser.parse(data: data)
        XCTAssertEqual(result.papers.count, 0)
    }

    func testExtractArXivIDStripsVersion() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:arxiv="http://arxiv.org/schemas/atom">
          <entry>
            <id>http://arxiv.org/abs/2301.00001v3</id>
            <title>Test</title>
            <published>2023-01-01T00:00:00Z</published>
            <updated>2023-01-01T00:00:00Z</updated>
            <author><name>Test Author</name></author>
            <arxiv:primary_category term="cs.AI"/>
            <category term="cs.AI"/>
            <link href="http://arxiv.org/abs/2301.00001v3" rel="alternate"/>
          </entry>
        </feed>
        """
        let data = xml.data(using: .utf8)!
        let result = try XMLAtomParser.parse(data: data)
        let papers = result.papers
        XCTAssertEqual(papers.count, 1)
        XCTAssertEqual(papers[0].id, "2301.00001")
        XCTAssertEqual(papers[0].link, "https://arxiv.org/abs/2301.00001")
    }
}

final class SavedSearchTests: XCTestCase {

    func testClausesEqualIgnoresOrder() {
        let clause1 = SearchClause(id: UUID(), field: .category, value: "cs.LG")
        let clause2 = SearchClause(id: UUID(), field: .author, value: "Hinton")

        let search1 = SavedSearch(name: "Test", clauses: [clause1, clause2])
        let search2 = SavedSearch(name: "Test", clauses: [clause2, clause1])

        XCTAssertTrue(search1.clausesEqual(to: search2))
    }

    func testClausesNotEqualDifferentValues() {
        let clause1 = SearchClause(field: .keyword, value: "diffusion", scope: .title)
        let clause2 = SearchClause(field: .keyword, value: "attention", scope: .title)

        let search1 = SavedSearch(name: "Test", clauses: [clause1])
        let search2 = SavedSearch(name: "Test", clauses: [clause2])

        XCTAssertFalse(search1.clausesEqual(to: search2))
    }

    func testClauseEquatable_ignoresID() {
        let clause1 = SearchClause(id: UUID(), field: .keyword, value: "test", scope: .title)
        let clause2 = SearchClause(id: UUID(), field: .keyword, value: "test", scope: .title)
        XCTAssertEqual(clause1, clause2)
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArXivMonitorTests-\(UUID().uuidString)")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "badgeStyle")
        defaults.removeObject(forKey: "soundName")
        defaults.removeObject(forKey: "launchAtLogin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "badgeStyle")
        defaults.removeObject(forKey: "soundName")
        defaults.removeObject(forKey: "launchAtLogin")
        super.tearDown()
    }

    func testAddAndDeleteSearch() {
        let state = AppState(dataDirectoryURL: tempDir)
        let search = SavedSearch(name: "Test", clauses: [SearchClause(field: .keyword, value: "test", scope: .title)])
        state.addSearch(search)
        XCTAssertEqual(state.savedSearches.count, 1)
        state.deleteSearch(search.id)
        XCTAssertEqual(state.savedSearches.count, 0)
    }

    func testDismissPaper() {
        let state = AppState(dataDirectoryURL: tempDir)
        let paper = MatchedPaper(
            id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
            categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
            matchedSearchIDs: [UUID()], foundAt: "2024-01-01T00:00:00Z", isNew: true
        )
        state.matchedPapers[paper.id] = paper
        XCTAssertEqual(state.unreadCount, 1)
        state.dismissPaper(paper.id)
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertNotNil(state.matchedPapers[paper.id], "Dismissed paper should still exist (trashed)")
        XCTAssertTrue(state.matchedPapers[paper.id]!.isTrash, "Dismissed paper should be trashed")
        XCTAssertFalse(state.matchedPapers[paper.id]!.isNew, "Trashed paper should not be new")
        XCTAssertTrue(state.allPapersSorted.isEmpty, "Trashed paper should not appear in sorted list")
    }

    func testRestorePaper() {
        let state = AppState(dataDirectoryURL: tempDir)
        let paper = MatchedPaper(
            id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
            categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
            matchedSearchIDs: [UUID()], foundAt: "2024-01-01T00:00:00Z", isNew: false,
            isTrash: true
        )
        state.matchedPapers[paper.id] = paper
        XCTAssertTrue(state.allPapersSorted.isEmpty)
        state.restorePaper(paper.id)
        XCTAssertFalse(state.matchedPapers[paper.id]!.isTrash)
        XCTAssertEqual(state.allPapersSorted.count, 1)
    }

    func testIsTrashBackwardCompatibility() throws {
        let json = """
        {"id":"test","title":"T","authors":"A","primaryCategory":"cs.AI",
         "categories":["cs.AI"],"publishedAt":"2024-01-01T00:00:00Z",
         "updatedAt":"2024-01-01T00:00:00Z","link":"https://arxiv.org/abs/test",
         "matchedSearchIDs":[],"foundAt":"2024-01-01T00:00:00Z","isNew":false}
        """
        let data = json.data(using: .utf8)!
        let paper = try JSONDecoder().decode(MatchedPaper.self, from: data)
        XCTAssertFalse(paper.isTrash, "Missing isTrash should default to false")
    }

    func testMarkUnread() {
        let state = AppState(dataDirectoryURL: tempDir)
        let paper = MatchedPaper(
            id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
            categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
            matchedSearchIDs: [UUID()], foundAt: "2024-01-01T00:00:00Z", isNew: false
        )
        state.matchedPapers[paper.id] = paper
        XCTAssertEqual(state.unreadCount, 0)
        state.markUnread(paperID: paper.id)
        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertTrue(state.matchedPapers[paper.id]!.isNew)
    }

    func testMarkReadPublic() {
        let state = AppState(dataDirectoryURL: tempDir)
        let paper = MatchedPaper(
            id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
            categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
            matchedSearchIDs: [UUID()], foundAt: "2024-01-01T00:00:00Z", isNew: true
        )
        state.matchedPapers[paper.id] = paper
        XCTAssertEqual(state.unreadCount, 1)
        state.markRead(paperID: paper.id)
        XCTAssertEqual(state.unreadCount, 0)
    }

    func testTrashedPapersFilteredFromSearchResults() {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchID = UUID()
        let paper = MatchedPaper(
            id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
            categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
            matchedSearchIDs: [searchID], foundAt: "2024-01-01T00:00:00Z", isNew: true,
            isTrash: true
        )
        state.matchedPapers[paper.id] = paper
        XCTAssertTrue(state.papers(for: searchID).isEmpty, "Trashed paper should not appear in search results")
        XCTAssertTrue(state.newPapers.isEmpty, "Trashed paper should not appear in new papers")
        XCTAssertEqual(state.unreadCount, 0, "Trashed paper should not count as unread")
    }

    func testDismissAll() {
        let state = AppState(dataDirectoryURL: tempDir)
        state.matchedPapers["a"] = MatchedPaper(
            id: "a", title: "A", authors: "A", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [UUID()],
            foundAt: "2024-01-01T00:00:00Z", isNew: true
        )
        state.matchedPapers["b"] = MatchedPaper(
            id: "b", title: "B", authors: "B", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [UUID()],
            foundAt: "2024-01-01T00:00:00Z", isNew: true
        )
        XCTAssertEqual(state.unreadCount, 2)
        state.markAllRead()
        XCTAssertEqual(state.unreadCount, 0)
    }

    func testDeleteSearchScrubsPapers() {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchID = UUID()
        let search = SavedSearch(id: searchID, name: "Test", clauses: [SearchClause(field: .keyword, value: "x", scope: .title)])
        state.addSearch(search)

        // Paper matched by this search only — should be removed
        state.matchedPapers["orphan"] = MatchedPaper(
            id: "orphan", title: "Orphan", authors: "A", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [searchID],
            foundAt: "2024-01-01T00:00:00Z", isNew: true
        )

        // Paper matched by this search and another — should keep the other
        let otherSearchID = UUID()
        state.matchedPapers["shared"] = MatchedPaper(
            id: "shared", title: "Shared", authors: "B", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [searchID, otherSearchID],
            foundAt: "2024-01-01T00:00:00Z", isNew: false
        )

        state.deleteSearch(searchID)
        XCTAssertNil(state.matchedPapers["orphan"], "Orphaned paper should be removed")
        XCTAssertNotNil(state.matchedPapers["shared"], "Shared paper should remain")
        XCTAssertEqual(state.matchedPapers["shared"]!.matchedSearchIDs, [otherSearchID])
    }

    func testUpdateSearchResetsOnClauseChange() {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchID = UUID()
        let clause = SearchClause(field: .keyword, value: "diffusion", scope: .title)
        var search = SavedSearch(id: searchID, name: "Test", clauses: [clause], lastQueriedAt: "2024-01-01T00:00:00Z")
        state.savedSearches = [search]

        // Add a matched paper
        state.matchedPapers["p1"] = MatchedPaper(
            id: "p1", title: "P", authors: "A", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [searchID],
            foundAt: "2024-01-01T00:00:00Z", isNew: false
        )

        // Edit clauses
        search.clauses = [SearchClause(field: .keyword, value: "attention", scope: .title)]
        state.updateSearch(search)

        XCTAssertNil(state.savedSearches.first?.lastQueriedAt, "lastQueriedAt should be reset on clause change")
        XCTAssertNil(state.matchedPapers["p1"], "Paper should be removed when its only search is edited (clause change)")
    }

    func testUpdateSearchNameOnlyDoesNotReset() {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchID = UUID()
        let clause = SearchClause(field: .keyword, value: "diffusion", scope: .title)
        let search = SavedSearch(id: searchID, name: "Old Name", clauses: [clause], lastQueriedAt: "2024-01-01T00:00:00Z")
        state.savedSearches = [search]

        var updated = search
        updated.name = "New Name"
        state.updateSearch(updated)

        XCTAssertEqual(state.savedSearches.first?.lastQueriedAt, "2024-01-01T00:00:00Z",
                        "Name-only edit should not reset lastQueriedAt")
    }

    func testIsRevisionDerived() {
        let paper1 = MatchedPaper(
            id: "a", title: "A", authors: "A", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [],
            foundAt: "2024-01-01T00:00:00Z", isNew: false
        )
        XCTAssertFalse(paper1.isRevision)

        let paper2 = MatchedPaper(
            id: "b", title: "B", authors: "B", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-03-01T00:00:00Z", link: "", matchedSearchIDs: [],
            foundAt: "2024-01-01T00:00:00Z", isNew: false
        )
        XCTAssertTrue(paper2.isRevision)
    }

    func testEmptyTrash() {
        let state = AppState(dataDirectoryURL: tempDir)
        state.matchedPapers["a"] = MatchedPaper(
            id: "a", title: "A", authors: "A", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [UUID()],
            foundAt: "2024-01-01T00:00:00Z", isNew: false, isTrash: true
        )
        state.matchedPapers["b"] = MatchedPaper(
            id: "b", title: "B", authors: "B", primaryCategory: "cs.AI",
            categories: [], publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z", link: "", matchedSearchIDs: [UUID()],
            foundAt: "2024-01-01T00:00:00Z", isNew: true
        )
        XCTAssertEqual(state.trashedPapers.count, 1)
        XCTAssertEqual(state.allPapersSorted.count, 1)
        state.emptyTrash()
        XCTAssertEqual(state.trashedPapers.count, 0)
        XCTAssertEqual(state.allPapersSorted.count, 1) // non-trashed paper still there
    }

    func testMoveSearch() {
        let state = AppState(dataDirectoryURL: tempDir)
        let s1 = SavedSearch(name: "First", clauses: [SearchClause(field: .keyword, value: "a", scope: .title)])
        let s2 = SavedSearch(name: "Second", clauses: [SearchClause(field: .keyword, value: "b", scope: .title)])
        let s3 = SavedSearch(name: "Third", clauses: [SearchClause(field: .keyword, value: "c", scope: .title)])
        state.addSearch(s1)
        state.addSearch(s2)
        state.addSearch(s3)
        XCTAssertEqual(state.savedSearches.map(\.name), ["First", "Second", "Third"])

        // Move "Third" to position 0 (before "First")
        state.moveSearch(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(state.savedSearches.map(\.name), ["Third", "First", "Second"])

        // Verify persistence: reload from same directory
        let reloaded = AppState(dataDirectoryURL: tempDir)
        XCTAssertEqual(reloaded.savedSearches.map(\.name), ["Third", "First", "Second"])
    }

    func testDataVersionBackwardCompatibility() {
        // Simulate data without dataVersion field (pre-versioning)
        let json = """
        {
            "savedSearches": [],
            "matchedPapers": {},
            "lastCycleFailedSearchIDs": []
        }
        """
        let data = json.data(using: .utf8)!
        let persisted = try! JSONDecoder().decode(PersistedData.self, from: data)
        XCTAssertEqual(persisted.dataVersion, 1)
        XCTAssertTrue(persisted.savedSearches.isEmpty)
    }

    func testLegacyDotBadgePreferenceMigratesToNone() {
        UserDefaults.standard.set("dot", forKey: "badgeStyle")

        let state = AppState(dataDirectoryURL: tempDir)

        XCTAssertEqual(state.badgeStyle, "none")
    }

    func testExportDataWritesCurrentStateWithoutBackingDataFile() throws {
        let state = AppState(dataDirectoryURL: tempDir)
        let search = SavedSearch(
            name: "Export Search",
            clauses: [SearchClause(field: .keyword, value: "diffusion", scope: .title)]
        )
        let paper = MatchedPaper(
            id: "paper-001",
            title: "Exported Paper",
            authors: "A. Author",
            primaryCategory: "cs.AI",
            categories: ["cs.AI"],
            publishedAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z",
            link: "https://arxiv.org/abs/paper-001",
            matchedSearchIDs: [search.id],
            foundAt: "2024-01-01T00:00:00Z",
            isNew: true
        )

        state.savedSearches = [search]
        state.matchedPapers = [paper.id: paper]

        let exportURL = tempDir.appendingPathComponent("export.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))

        try state.exportData(to: exportURL)

        let exportedData = try Data(contentsOf: exportURL)
        let persisted = try JSONDecoder().decode(PersistedData.self, from: exportedData)
        XCTAssertEqual(persisted.savedSearches.count, 1)
        XCTAssertEqual(persisted.savedSearches.first?.name, "Export Search")
        XCTAssertEqual(persisted.matchedPapers["paper-001"]?.title, "Exported Paper")
    }

    @MainActor
    func testExportDataButtonFlowWritesFileViaTestURL() throws {
        let state = AppState(dataDirectoryURL: tempDir)
        state.loadSampleData()

        let exportURL = tempDir.appendingPathComponent("button-export.json")
        state.testExportURL = exportURL

        // This calls the same code path as the "Export Data..." button
        state.exportData()

        // Verify file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path), "Export file should be created")

        let data = try Data(contentsOf: exportURL)
        let persisted = try JSONDecoder().decode(PersistedData.self, from: data)
        XCTAssertEqual(persisted.savedSearches.count, 3, "Should export 3 sample searches")
        XCTAssertEqual(persisted.matchedPapers.count, 4, "Should export 4 sample papers")
        XCTAssertEqual(state.exportStatusMessage, "Exported button-export.json.")
    }
}

final class PollSchedulerTests: XCTestCase {

    func testMostRecentScheduledRun() {
        let date = PollScheduler.mostRecentScheduledRun()
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = utcCalendar.component(.hour, from: date)
        XCTAssertEqual(hour, 4, "Most recent scheduled run should be at 04:00 UTC")
        XCTAssertTrue(date <= Date(), "Most recent scheduled run should be in the past or now")
    }
}
