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
