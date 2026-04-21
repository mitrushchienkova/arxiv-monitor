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
        // Multi-word keyword should split on whitespace and AND the tokens
        // within the abstract scope. No phrase-quoting.
        XCTAssertTrue(query.contains("abs:flow") || query.contains("abs%3Aflow"),
                       "Query should contain abs:flow, got: \(query)")
        XCTAssertTrue(query.contains("abs:matching") || query.contains("abs%3Amatching"),
                       "Query should contain abs:matching, got: \(query)")
        XCTAssertTrue(query.contains("AND"),
                       "Multi-word keyword must AND its tokens, got: \(query)")
        XCTAssertFalse(query.contains("%22flow") || query.contains("flow%20matching%22") || query.contains("%22flow%20matching%22"),
                        "Multi-word keyword must NOT be wrapped as a phrase, got: \(query)")
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
        // Multi-word keyword must AND tokens, not wrap as a phrase.
        XCTAssertTrue(query.contains("AND"),
                       "Multi-word keyword must AND its tokens, got: \(query)")
        XCTAssertFalse(query.contains("%22flow%20matching%22"),
                        "Multi-word keyword must NOT be wrapped as a phrase, got: \(query)")
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

    /// Bug: multi-word unquoted keyword must split on whitespace and AND the
    /// tokens, matching the arXiv website's unquoted-search semantics so users
    /// don't miss papers where the words appear non-adjacently
    /// (e.g. "osculating orbital elements" for input "osculating elements").
    func testBuildQueryURL_multiWordKeyword_splitsIntoAND() {
        let search = SavedSearch(
            name: "Osculating elements",
            clauses: [SearchClause(field: .keyword, value: "osculating elements", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Expected pre-encoding form:
        //   ((ti:osculating OR abs:osculating) AND (ti:elements OR abs:elements))
        // Post-encoding, spaces become %20 and colons are preserved literally.
        let expected = "(ti:osculating%20OR%20abs:osculating)%20AND%20(ti:elements%20OR%20abs:elements)"
        XCTAssertTrue(query.contains(expected),
                       "Multi-word keyword should split into AND of per-token (ti OR abs) groups. Expected substring: \(expected); got: \(query)")
        // Must NOT be wrapped as a phrase.
        XCTAssertFalse(query.contains("%22osculating%20elements%22"),
                        "Multi-word keyword must NOT be wrapped as a Lucene phrase, got: \(query)")
    }

    /// If the user wraps a keyword in literal double quotes, preserve the
    /// phrase form as an intentional escape hatch.
    func testBuildQueryURL_explicitQuotedKeyword_preservesPhrase() {
        let search = SavedSearch(
            name: "Mirror symmetry phrase",
            clauses: [SearchClause(field: .keyword, value: "\"mirror symmetry\"", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Phrase form: (ti:"mirror symmetry" OR abs:"mirror symmetry")
        XCTAssertTrue(query.contains("%22mirror%20symmetry%22"),
                       "Explicit-quoted keyword should be preserved as a phrase, got: \(query)")
        XCTAssertTrue(query.contains("ti:%22mirror%20symmetry%22") || query.contains("ti%3A%22mirror%20symmetry%22"),
                       "Phrase must apply to ti: field, got: \(query)")
        XCTAssertTrue(query.contains("abs:%22mirror%20symmetry%22") || query.contains("abs%3A%22mirror%20symmetry%22"),
                       "Phrase must apply to abs: field, got: \(query)")
        // Must NOT be AND-split.
        XCTAssertFalse(query.contains("ti:mirror%20AND%20ti:symmetry"),
                        "Explicit-quoted keyword must NOT be AND-split, got: \(query)")
    }

    /// Hyphenated single token must still be quoted (escapeQuery keeps the
    /// quote-escape that defeats Lucene's NOT operator on hyphens).
    func testBuildQueryURL_hyphenPlusWhitespace() {
        let search = SavedSearch(
            name: "Gromov-Witten invariants",
            clauses: [SearchClause(field: .keyword, value: "Gromov-Witten invariants", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        // Expected: ((ti:"Gromov-Witten" OR abs:"Gromov-Witten") AND (ti:invariants OR abs:invariants))
        XCTAssertTrue(query.contains("%22Gromov-Witten%22"),
                       "Hyphenated token must remain quoted even in a multi-word keyword, got: \(query)")
        XCTAssertTrue(query.contains("ti:invariants") || query.contains("ti%3Ainvariants"),
                       "Unhyphenated token must appear unquoted, got: \(query)")
        XCTAssertTrue(query.contains("AND"),
                       "Multi-word keyword must AND its tokens, got: \(query)")
        // Must NOT wrap the whole thing as a single phrase.
        XCTAssertFalse(query.contains("%22Gromov-Witten%20invariants%22"),
                        "Multi-word keyword must NOT be wrapped as a single phrase, got: \(query)")
    }

    /// Comma-separated keywords stay ORed at the outer level, and whitespace
    /// within each sub-keyword is AND-split.
    func testBuildQueryURL_commaSeparatedOuterOR_innerAND() {
        let search = SavedSearch(
            name: "Mixed",
            clauses: [SearchClause(field: .keyword, value: "osculating elements, Gromov-Witten", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("AND"), "Multi-word sub-keyword must AND tokens, got: \(query)")
        XCTAssertTrue(query.contains("OR"), "Comma-separated keywords must OR, got: \(query)")
        XCTAssertTrue(query.contains("%22Gromov-Witten%22"),
                       "Hyphenated sub-keyword must still be quoted, got: \(query)")
    }

    /// Single-token keyword unchanged: (ti:osculating OR abs:osculating).
    func testBuildQueryURL_singleTokenKeywordUnchanged() {
        let search = SavedSearch(
            name: "Osculating",
            clauses: [SearchClause(field: .keyword, value: "osculating", scope: .titleAndAbstract)]
        )
        let url = ArXivAPIClient.buildQueryURL(for: search)
        XCTAssertNotNil(url)
        let query = url!.absoluteString
        XCTAssertTrue(query.contains("ti:osculating") || query.contains("ti%3Aosculating"),
                       "Single-token keyword should produce ti:osculating, got: \(query)")
        XCTAssertTrue(query.contains("abs:osculating") || query.contains("abs%3Aosculating"),
                       "Single-token keyword should produce abs:osculating, got: \(query)")
        XCTAssertFalse(query.contains("AND"),
                        "Single-token keyword must not contain AND, got: \(query)")
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
        let headers: [String: String]?

        init(status: Int, body: Data, error: Error?, headers: [String: String]? = nil) {
            self.status = status
            self.body = body
            self.error = error
            self.headers = headers
        }
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
            headerFields: stub.headers
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
        // Disable jitter so timing stays deterministic in CI.
        ArXivAPIClient.retryJitterMaxNanoseconds = 0
    }

    override func tearDown() {
        MockURLProtocol.reset()
        ArXivAPIClient.retryBackoffNanoseconds = 5_000_000_000  // restore production default
        ArXivAPIClient.retryJitterMaxNanoseconds = 1_000_000_000  // restore production default
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

// MARK: - HTTP 429 rate-limit retry tests

final class ArXivAPIClientRateLimitTests: XCTestCase {
    private let url = URL(string: "https://export.arxiv.org/api/query?search_query=ti:test")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        // Keep the suite fast: collapse both backoff knobs to ~1ms, cap the
        // server-supplied Retry-After value, and disable jitter for determinism.
        ArXivAPIClient.retryBackoffNanoseconds = 1_000_000
        ArXivAPIClient.rateLimitedBackoffNanoseconds = 1_000_000
        ArXivAPIClient.rateLimitedBackoffCapNanoseconds = 1_000_000
        ArXivAPIClient.retryJitterMaxNanoseconds = 0
        ArXivAPIClient.rateLimitedJitterMaxNanoseconds = 0
    }

    override func tearDown() {
        MockURLProtocol.reset()
        ArXivAPIClient.retryBackoffNanoseconds = 5_000_000_000
        ArXivAPIClient.rateLimitedBackoffNanoseconds = 30_000_000_000
        ArXivAPIClient.rateLimitedBackoffCapNanoseconds = .max
        ArXivAPIClient.retryJitterMaxNanoseconds = 1_000_000_000
        ArXivAPIClient.rateLimitedJitterMaxNanoseconds = 5_000_000_000
        super.tearDown()
    }

    /// 429 on first request followed by 200 should retry and return success.
    func testFetchWithRetry_retriesOn429_thenSucceeds() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data("Rate exceeded.".utf8), error: nil),
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let start = Date()
        let (data, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "Should make exactly 2 requests (initial + 1 retry)")
        XCTAssertLessThan(elapsed, 1.0, "Test must complete quickly with overridden backoff (<1s)")
    }

    /// Two 429s in a row should throw `.rateLimited` rather than returning the response.
    func testFetchWithRetry_twoConsecutive429s_throwsRateLimited() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil),
            .init(status: 429, body: Data(), error: nil),
        ]

        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected ArXivError.rateLimited")
        } catch let error as ArXivError {
            guard case .rateLimited = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "At most one retry on 429")
    }

    /// `Retry-After: 45` on both responses should surface 45 in the thrown error.
    func testFetchWithRetry_429WithRetryAfterHeader_surfacesSeconds() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "45"]),
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "45"]),
        ]

        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected ArXivError.rateLimited(retryAfterSeconds: 45)")
        } catch let error as ArXivError {
            guard case .rateLimited(let seconds) = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 45, "Retry-After header value should surface in the error")
        }
    }

    /// `Retry-After` as an HTTP-date in the past or near future should not crash.
    /// When parseable, the app should honor it (bounded to [15, 120]); when
    /// unparseable, fall back to the default.
    func testFetchWithRetry_429WithHTTPDateRetryAfter_doesNotCrash() async throws {
        let session = makeStubSession()
        // An HTTP-date ~60 seconds in the future.
        let future = Date().addingTimeInterval(60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateStr = f.string(from: future)
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": dateStr]),
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": dateStr]),
        ]

        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected .rateLimited")
        } catch let error as ArXivError {
            guard case .rateLimited(let seconds) = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
            // We don't assert an exact number — parseable dates produce a
            // clamped [15, 120] value, unparseable ones nil. Both are fine,
            // the contract is simply "don't crash".
            if let seconds {
                XCTAssertGreaterThanOrEqual(seconds, 0)
                XCTAssertLessThanOrEqual(seconds, 120)
            }
        }
    }

    /// Unparseable `Retry-After` should fall back to the default backoff without
    /// crashing or hanging on the production 30s timer (overridden here to 1ms).
    func testFetchWithRetry_429WithUnparseableRetryAfter_fallsBackToDefault() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "soon maybe"]),
            .init(status: 200, body: Data("ok".utf8), error: nil),
        ]

        let (_, response) = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
        XCTAssertEqual(response.statusCode, 200, "Retry after unparseable Retry-After should still fire")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    /// `Retry-After: 1` (below the 15s floor) should surface the clamped
    /// value in the thrown error — otherwise the UI cooldown ages out before
    /// the client's actual retry wait elapses.
    func testFetchWithRetry_429WithRetryAfterBelowFloor_surfacesClamped() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "1"]),
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "1"]),
        ]
        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected .rateLimited")
        } catch let error as ArXivError {
            guard case .rateLimited(let seconds) = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 15, "Retry-After below the 15s floor should be clamped to 15")
        }
    }

    /// `Retry-After: 200` (above the 120s ceiling) should surface the clamped
    /// value in the thrown error so the UI doesn't wait longer than the
    /// client actually slept.
    func testFetchWithRetry_429WithRetryAfterAboveCeiling_surfacesClamped() async throws {
        let session = makeStubSession()
        MockURLProtocol.responses = [
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "200"]),
            .init(status: 429, body: Data(), error: nil, headers: ["Retry-After": "200"]),
        ]
        do {
            _ = try await ArXivAPIClient.fetchWithRetry(url: url, session: session)
            XCTFail("Expected .rateLimited")
        } catch let error as ArXivError {
            guard case .rateLimited(let seconds) = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 120, "Retry-After above the 120s ceiling should be clamped to 120")
        }
    }

    /// Unit-level assertions on the clamp helper. Explicit so a future edit
    /// that widens either bound is called out by the test suite.
    func testEffectiveRetryAfterSeconds_clampsAndRejectsNonPositive() {
        XCTAssertEqual(ArXivAPIClient.effectiveRetryAfterSeconds(1), 15)
        XCTAssertEqual(ArXivAPIClient.effectiveRetryAfterSeconds(15), 15)
        XCTAssertEqual(ArXivAPIClient.effectiveRetryAfterSeconds(45), 45)
        XCTAssertEqual(ArXivAPIClient.effectiveRetryAfterSeconds(120), 120)
        XCTAssertEqual(ArXivAPIClient.effectiveRetryAfterSeconds(200), 120)
        XCTAssertNil(ArXivAPIClient.effectiveRetryAfterSeconds(nil))
        XCTAssertNil(ArXivAPIClient.effectiveRetryAfterSeconds(0))
        XCTAssertNil(ArXivAPIClient.effectiveRetryAfterSeconds(-5))
    }

    /// The `parseRetryAfter` helper should accept both integer-seconds and
    /// RFC 1123 date forms, and return nil for missing/garbage headers.
    func testParseRetryAfter_acceptsSecondsAndHTTPDate() {
        func makeResponse(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com/")!,
                            statusCode: 429,
                            httpVersion: "HTTP/1.1",
                            headerFields: headers)!
        }
        XCTAssertEqual(ArXivAPIClient.parseRetryAfter(from: makeResponse(["Retry-After": "45"])), 45)
        XCTAssertNil(ArXivAPIClient.parseRetryAfter(from: makeResponse([:])))
        XCTAssertNil(ArXivAPIClient.parseRetryAfter(from: makeResponse(["Retry-After": "nonsense"])))
        // HTTP-date ~30s in the future should parse to a small positive int.
        let future = Date().addingTimeInterval(30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let seconds = ArXivAPIClient.parseRetryAfter(from: makeResponse(["Retry-After": f.string(from: future)]))
        XCTAssertNotNil(seconds)
        if let seconds { XCTAssertGreaterThanOrEqual(seconds, 0) }
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

    /// A 429 landing in memory must survive a relaunch. If `rateLimitedSearchIDs`
    /// and `rateLimitedUntil` were ephemeral, `lastCycleFailedSearchIDs` would be
    /// restored but the rate-limit classification would be lost, and the UI would
    /// show a red "failed · Retry" line instead of the softer "waiting" treatment.
    func testRateLimitedStatePersistsAcrossReload() throws {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchA = SavedSearch(name: "A", clauses: [SearchClause(field: .keyword, value: "a", scope: .title)])
        let searchB = SavedSearch(name: "B", clauses: [SearchClause(field: .keyword, value: "b", scope: .title)])
        state.savedSearches = [searchA, searchB]

        // Simulate a cycle where A was rate-limited with a known Retry-After
        // and B failed for an unrelated reason (e.g. transport error).
        let retryAt = Date().addingTimeInterval(45)
        state.lastCycleFailedSearchIDs = [searchA.id, searchB.id]
        state.rateLimitedSearchIDs = [searchA.id]
        state.rateLimitedUntil = [searchA.id: retryAt]

        // Write it out via the same encoder the app uses on save.
        let encoded = try state.encodedPersistedData()
        let dataFile = tempDir.appendingPathComponent("data.json")
        try encoded.write(to: dataFile, options: .atomic)

        // Reload from disk — mimics app relaunch.
        let reloaded = AppState(dataDirectoryURL: tempDir)
        XCTAssertEqual(Set(reloaded.lastCycleFailedSearchIDs), [searchA.id, searchB.id],
                       "Failed IDs should survive reload")
        XCTAssertEqual(reloaded.rateLimitedSearchIDs, [searchA.id],
                       "Rate-limited subset must survive reload — otherwise 429'd searches render as generic failures")
        XCTAssertEqual(reloaded.rateLimitedUntil[searchA.id]?.timeIntervalSince1970 ?? 0,
                       retryAt.timeIntervalSince1970,
                       accuracy: 1.0,
                       "rateLimitedUntil should round-trip so the popover keeps showing the same retry time")
        // The "other failed" classification is derived, not persisted — check
        // it behaves correctly on the reloaded state.
        XCTAssertEqual(reloaded.rateLimitedSearchNames, ["A"])
        XCTAssertEqual(reloaded.otherFailedSearchNames, ["B"])
    }

    /// Once the cooldown has expired, a previously rate-limited search should
    /// fall out of `rateLimitedSearchNames` and into `otherFailedSearchNames`
    /// so the user gets the red "failed · Retry" prompt back. Prevents the
    /// stuck-forever "waiting…" state the reviewer flagged.
    func testRateLimitedCooldownAgesOutOfRateLimitedList() {
        let state = AppState(dataDirectoryURL: tempDir)
        let search = SavedSearch(name: "Stale", clauses: [SearchClause(field: .keyword, value: "x", scope: .title)])
        state.savedSearches = [search]
        state.lastCycleFailedSearchIDs = [search.id]
        state.rateLimitedSearchIDs = [search.id]
        // Cooldown expired a minute ago.
        state.rateLimitedUntil = [search.id: Date().addingTimeInterval(-60)]

        XCTAssertEqual(state.rateLimitedSearchNames, [],
                       "Expired cooldown must not pin the search in 'waiting…' state")
        XCTAssertEqual(state.otherFailedSearchNames, ["Stale"],
                       "Expired rate-limit should surface a Retry prompt like any other failure")
    }

    /// `otherFailedSearchIDs` and `otherFailedSearchNames` must agree — the
    /// popover's Retry button uses the IDs to scope a fetch cycle that only
    /// re-hits searches NOT in cooldown. If these drifted apart, a retry
    /// could either miss a failed search or inadvertently re-hit a 429'd one
    /// (extending the cooldown).
    func testOtherFailedSearchIDsExcludesActiveRateLimited() {
        let state = AppState(dataDirectoryURL: tempDir)
        let active = SavedSearch(name: "Active",   clauses: [SearchClause(field: .keyword, value: "a", scope: .title)])
        let expired = SavedSearch(name: "Expired", clauses: [SearchClause(field: .keyword, value: "e", scope: .title)])
        let generic = SavedSearch(name: "Generic", clauses: [SearchClause(field: .keyword, value: "g", scope: .title)])
        state.savedSearches = [active, expired, generic]
        state.lastCycleFailedSearchIDs = [active.id, expired.id, generic.id]
        state.rateLimitedSearchIDs = [active.id, expired.id]
        state.rateLimitedUntil = [
            active.id: Date().addingTimeInterval(60),   // cooldown still active
            expired.id: Date().addingTimeInterval(-60), // cooldown elapsed
        ]

        XCTAssertEqual(state.rateLimitedSearchNames, ["Active"])
        XCTAssertEqual(state.otherFailedSearchNames, ["Expired", "Generic"],
                       "Expired rate-limit should fall through; generic stays")
        XCTAssertEqual(state.otherFailedSearchIDs, [expired.id, generic.id],
                       "IDs must agree with names for scoped retry to target the right searches")
        XCTAssertFalse(state.otherFailedSearchIDs.contains(active.id),
                       "Retrying an active 429 would just extend the cooldown")
    }

    /// A rate-limited entry with no `rateLimitedUntil` timestamp (e.g. a
    /// hypothetical decode from an older persisted format) must not be treated
    /// as permanently rate-limited.
    func testRateLimitedWithoutUntilFallsBackToOtherFailed() {
        let state = AppState(dataDirectoryURL: tempDir)
        let search = SavedSearch(name: "Orphan", clauses: [SearchClause(field: .keyword, value: "x", scope: .title)])
        state.savedSearches = [search]
        state.lastCycleFailedSearchIDs = [search.id]
        state.rateLimitedSearchIDs = [search.id]
        state.rateLimitedUntil = [:]

        XCTAssertEqual(state.rateLimitedSearchNames, [])
        XCTAssertEqual(state.otherFailedSearchNames, ["Orphan"])
    }

    /// Deleting a search must scrub its failure/rate-limit metadata so the
    /// popover's "retry at …" computation (which scans rateLimitedSearchIDs)
    /// doesn't surface a time tied to a search that no longer exists.
    func testDeleteSearchScrubsFetchStatus() {
        let state = AppState(dataDirectoryURL: tempDir)
        let keep = SavedSearch(name: "Keep", clauses: [SearchClause(field: .keyword, value: "k", scope: .title)])
        let drop = SavedSearch(name: "Drop", clauses: [SearchClause(field: .keyword, value: "d", scope: .title)])
        state.savedSearches = [keep, drop]
        state.lastCycleFailedSearchIDs = [keep.id, drop.id]
        state.rateLimitedSearchIDs = [drop.id]
        state.rateLimitedUntil = [drop.id: Date().addingTimeInterval(120)]

        state.deleteSearch(drop.id)

        XCTAssertEqual(state.lastCycleFailedSearchIDs, [keep.id])
        XCTAssertFalse(state.rateLimitedSearchIDs.contains(drop.id))
        XCTAssertNil(state.rateLimitedUntil[drop.id])
    }

    /// Editing a search's clauses invalidates its previous failure
    /// classification — the new query may succeed where the old one failed,
    /// or vice versa. Cosmetic edits (name only) preserve status.
    func testUpdateSearchClauseChangeScrubsFetchStatusButNameChangeDoesNot() {
        let state = AppState(dataDirectoryURL: tempDir)
        let original = SavedSearch(name: "Orig", clauses: [SearchClause(field: .keyword, value: "a", scope: .title)])
        state.savedSearches = [original]
        state.lastCycleFailedSearchIDs = [original.id]
        state.rateLimitedSearchIDs = [original.id]
        state.rateLimitedUntil = [original.id: Date().addingTimeInterval(120)]

        // Cosmetic rename — status should survive.
        var renamed = original
        renamed.name = "Renamed"
        state.updateSearch(renamed)
        XCTAssertEqual(state.lastCycleFailedSearchIDs, [original.id],
                       "Cosmetic edit should not clear failure metadata")
        XCTAssertTrue(state.rateLimitedSearchIDs.contains(original.id))

        // Clause change — status must be scrubbed.
        var rewritten = renamed
        rewritten.clauses = [SearchClause(field: .keyword, value: "totally different", scope: .title)]
        state.updateSearch(rewritten)
        XCTAssertEqual(state.lastCycleFailedSearchIDs, [],
                       "Clause change should clear stale failure metadata")
        XCTAssertFalse(state.rateLimitedSearchIDs.contains(original.id))
        XCTAssertNil(state.rateLimitedUntil[original.id])
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

// MARK: - Scoped refresh tests

@MainActor
final class AppStateScopedRefreshTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArXivMonitorScopedRefreshTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Wait for `isFetching` to return to false. Scoped fetches on empty-clause
    /// searches throw invalidQuery immediately (no network), so this resolves
    /// quickly without the 3-second inter-search sleep.
    private func waitForFetchToFinish(_ state: AppState, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while state.isFetching && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// A scoped refresh (by search ID) must NOT clear cycle-level failure state
    /// for other, untouched searches — if search B previously failed and the
    /// user refreshes only A, B must remain in `lastCycleFailedSearchIDs`.
    func testScopedRefresh_preservesUnrelatedFailedSearchIDs() async {
        let state = AppState(dataDirectoryURL: tempDir)

        // Two searches; both have empty clauses so any fetch attempt will
        // deterministically throw ArXivError.invalidQuery (no network needed).
        let searchA = SavedSearch(name: "A", clauses: [])
        let searchB = SavedSearch(name: "B", clauses: [])
        state.savedSearches = [searchA, searchB]

        // Seed: B previously failed in a prior cycle.
        state.lastCycleFailedSearchIDs = [searchB.id]
        let priorLastCycleAt = "2024-01-01T00:00:00Z"
        state.lastCycleAt = priorLastCycleAt

        // Scoped refresh of A only.
        state.runFetchCycle(onlySearchIDs: [searchA.id])
        await waitForFetchToFinish(state)

        // A tried and failed (invalidQuery); B was NOT retried and must remain failed.
        XCTAssertTrue(state.lastCycleFailedSearchIDs.contains(searchA.id),
                      "Scoped search A failed this attempt — should be in failed list")
        XCTAssertTrue(state.lastCycleFailedSearchIDs.contains(searchB.id),
                      "Untouched search B must retain its prior failed status")
        // Scoped refresh must not overwrite lastCycleAt (not a full cycle).
        XCTAssertEqual(state.lastCycleAt, priorLastCycleAt,
                       "Scoped refresh must not update lastCycleAt")
    }

    /// A scoped refresh of a search that previously failed should REMOVE it
    /// from `lastCycleFailedSearchIDs` when the retry succeeds (or, in this
    /// test, when no invalidQuery is thrown). Here we use the no-op case:
    /// a search with no clauses will throw invalidQuery and stay in the list,
    /// but the complementary case is that *other* searches' failure status
    /// never changes — which is the coverage we want alongside the first test.
    /// Additionally verify that full (unscoped) refresh still resets the list
    /// and updates lastCycleAt.
    func testFullRefresh_resetsFailedListAndUpdatesLastCycleAt() async {
        let state = AppState(dataDirectoryURL: tempDir)
        let searchA = SavedSearch(name: "A", clauses: [])
        state.savedSearches = [searchA]

        let ancientLastCycle = "2024-01-01T00:00:00Z"
        state.lastCycleAt = ancientLastCycle
        // Stale failed ID that doesn't exist on any current search — a full
        // refresh should drop it because the full path replaces the list wholesale.
        state.lastCycleFailedSearchIDs = [UUID()]

        state.runFetchCycle()
        await waitForFetchToFinish(state)

        XCTAssertNotEqual(state.lastCycleAt, ancientLastCycle,
                          "Full refresh must update lastCycleAt")
        // After a full cycle, only currently-failing searches should be in the list.
        XCTAssertEqual(Set(state.lastCycleFailedSearchIDs), [searchA.id],
                       "Full refresh should replace the failed list, not merge")
    }

    /// A scoped refresh with an empty set should be a no-op: isFetching flips
    /// briefly but nothing is touched. Guards against accidental "fetch all"
    /// regression when UI passes an empty scope.
    func testScopedRefresh_emptyScopeIsNoOp() async {
        let state = AppState(dataDirectoryURL: tempDir)
        let search = SavedSearch(name: "A", clauses: [])
        state.savedSearches = [search]
        let priorLastCycleAt = "2024-01-01T00:00:00Z"
        state.lastCycleAt = priorLastCycleAt
        state.lastCycleFailedSearchIDs = []

        state.runFetchCycle(onlySearchIDs: [])
        await waitForFetchToFinish(state)

        XCTAssertEqual(state.lastCycleAt, priorLastCycleAt,
                       "Empty-scope refresh must not touch lastCycleAt")
        XCTAssertTrue(state.lastCycleFailedSearchIDs.isEmpty,
                      "Empty-scope refresh must not touch failed list")
    }

    /// Scoped refresh should also run for paused searches the user explicitly
    /// targets — the paused filter only applies to the automatic cycle.
    func testScopedRefresh_includesPausedSearchWhenExplicitlyTargeted() async {
        let state = AppState(dataDirectoryURL: tempDir)
        let paused = SavedSearch(name: "Paused", clauses: [], isPaused: true)
        state.savedSearches = [paused]

        state.runFetchCycle(onlySearchIDs: [paused.id])
        await waitForFetchToFinish(state)

        // The paused search was attempted — it will have failed (invalidQuery),
        // confirming the scoped path bypassed the pause guard.
        XCTAssertTrue(state.lastCycleFailedSearchIDs.contains(paused.id),
                      "Paused search should be fetched when user explicitly targets it")
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
