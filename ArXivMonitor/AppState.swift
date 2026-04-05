import Foundation
import SwiftUI
import ServiceManagement

/// Persisted data structure for data.json.
struct PersistedData: Codable {
    var savedSearches: [SavedSearch]
    var matchedPapers: [String: MatchedPaper]
    var lastCycleAt: String?
    var lastCycleFailedSearchIDs: [UUID]

    static let empty = PersistedData(
        savedSearches: [],
        matchedPapers: [:],
        lastCycleAt: nil,
        lastCycleFailedSearchIDs: []
    )
}

/// Observable app state. Owns all persisted data and fetch logic.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State
    @Published var savedSearches: [SavedSearch] = []
    @Published var matchedPapers: [String: MatchedPaper] = [:]
    @Published var lastCycleAt: String?
    @Published var lastCycleFailedSearchIDs: [UUID] = []
    @Published var isFetching = false
    @Published var fetchProgress: String?

    /// Retained reference for the notification delegate (set by ArXivMonitorApp).
    var notificationDelegate: AnyObject?

    // MARK: - Settings (UserDefaults)
    @AppStorage("soundName") var soundName: String = "default"
    @AppStorage("badgeStyle") var badgeStyle: String = "count"
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet {
            updateLaunchAtLogin()
        }
    }

    // MARK: - Derived
    var unreadCount: Int {
        matchedPapers.values.filter(\.isNew).count
    }

    var newPapers: [MatchedPaper] {
        matchedPapers.values
            .filter(\.isNew)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var allPapersSorted: [MatchedPaper] {
        matchedPapers.values
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func papers(for searchID: UUID) -> [MatchedPaper] {
        matchedPapers.values
            .filter { $0.matchedSearchIDs.contains(searchID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Names of searches that failed in the most recent cycle.
    var failedSearchNames: [String] {
        lastCycleFailedSearchIDs.compactMap { id in
            savedSearches.first(where: { $0.id == id })?.name
        }
    }

    // MARK: - Persistence

    private let dataDirectoryURL: URL

    private var dataFileURL: URL {
        dataDirectoryURL.appendingPathComponent("data.json")
    }

    init(dataDirectoryURL: URL? = nil) {
        if let dir = dataDirectoryURL {
            self.dataDirectoryURL = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.dataDirectoryURL = appSupport.appendingPathComponent("ArXivMonitor", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: self.dataDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[ArXivMonitor] Failed to create app directory: \(error)")
        }
        load()
        NotificationService.shared.registerActions()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: dataFileURL)
            let persisted = try JSONDecoder().decode(PersistedData.self, from: data)
            savedSearches = persisted.savedSearches
            matchedPapers = persisted.matchedPapers
            lastCycleAt = persisted.lastCycleAt
            lastCycleFailedSearchIDs = persisted.lastCycleFailedSearchIDs
        } catch {
            print("[ArXivMonitor] Failed to load data.json, starting fresh: \(error)")
        }
    }

    private func save() {
        let persisted = PersistedData(
            savedSearches: savedSearches,
            matchedPapers: matchedPapers,
            lastCycleAt: lastCycleAt,
            lastCycleFailedSearchIDs: lastCycleFailedSearchIDs
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: dataFileURL, options: .atomic)
        } catch {
            print("[ArXivMonitor] Failed to save data.json: \(error)")
        }
    }

    // MARK: - Search Management

    func addSearch(_ search: SavedSearch) {
        savedSearches.append(search)
        save()

        // Request notification permission on first search creation
        if savedSearches.count == 1 {
            NotificationService.shared.requestPermission()
        }
    }

    func updateSearch(_ updated: SavedSearch) {
        guard let index = savedSearches.firstIndex(where: { $0.id == updated.id }) else { return }
        let old = savedSearches[index]

        // Check if clauses changed (not just name)
        let clausesChanged = !old.clausesEqual(to: updated)

        savedSearches[index] = updated

        if clausesChanged {
            // Reset lastQueriedAt so next fetch re-populates with baseline behavior
            savedSearches[index].lastQueriedAt = nil

            // Scrub this search's ID from all papers
            scrubSearchID(updated.id)
        }

        save()
    }

    func deleteSearch(_ searchID: UUID) {
        savedSearches.removeAll { $0.id == searchID }
        scrubSearchID(searchID)
        save()
    }

    /// Remove a search ID from all papers; remove papers with empty matchedSearchIDs.
    private func scrubSearchID(_ searchID: UUID) {
        var toRemove: [String] = []
        for (paperID, var paper) in matchedPapers {
            paper.matchedSearchIDs.removeAll { $0 == searchID }
            if paper.matchedSearchIDs.isEmpty {
                toRemove.append(paperID)
            } else {
                matchedPapers[paperID] = paper
            }
        }
        for id in toRemove {
            matchedPapers.removeValue(forKey: id)
        }
    }

    // MARK: - Paper Actions

    func openPaper(_ paper: MatchedPaper) {
        if let url = URL(string: paper.link),
           let scheme = url.scheme,
           ["https", "http"].contains(scheme.lowercased()) {
            NSWorkspace.shared.open(url)
        }
        markRead(paperID: paper.id)
    }

    func dismissPaper(_ paperID: String) {
        markRead(paperID: paperID)
    }

    func dismissAll() {
        for (id, var paper) in matchedPapers where paper.isNew {
            paper.isNew = false
            matchedPapers[id] = paper
        }
        save()
    }

    func markAllRead(for searchID: UUID) {
        for (id, var paper) in matchedPapers where paper.isNew && paper.matchedSearchIDs.contains(searchID) {
            paper.isNew = false
            matchedPapers[id] = paper
        }
        save()
    }

    private func markRead(paperID: String) {
        guard var paper = matchedPapers[paperID], paper.isNew else { return }
        paper.isNew = false
        matchedPapers[paperID] = paper
        save()
    }

    // MARK: - Fetch Cycle

    func runFetchCycle() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            await performFetchCycle()
        }
    }

    /// Run fetch for only stale searches (used by wake/launch catch-up).
    func runFetchCycleForStaleSearches() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            await performFetchCycle(staleOnly: true)
        }
    }

    private func performFetchCycle(staleOnly: Bool = false) async {
        fetchProgress = "Checking arXiv..."

        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let cycleStartedAt = now

        // Determine which searches to fetch
        let threshold = PollScheduler.mostRecentScheduledRun()
        let searchesToFetch: [SavedSearch]
        if staleOnly {
            searchesToFetch = savedSearches.filter { search in
                guard let lastQueried = search.lastQueriedAt,
                      let date = formatter.date(from: lastQueried) else {
                    return true
                }
                return date < threshold
            }
        } else {
            searchesToFetch = savedSearches
        }

        guard !searchesToFetch.isEmpty else {
            isFetching = false
            fetchProgress = nil
            return
        }

        print("[ArXivMonitor] Fetch cycle started: \(searchesToFetch.count) searches to check")

        // Identify baseline searches (first run or recently edited)
        let baselineSearchIDs = Set(savedSearches.filter { $0.lastQueriedAt == nil }.map(\.id))

        // Accumulators
        var pendingNew: [String: MatchedPaper] = [:]
        var pendingRevisions: [String: MatchedPaper] = [:]
        var pendingSearchIDs: [String: Set<UUID>] = [:]
        var failedSearchIDs: Set<UUID> = []
        var successfulTimestamps: [UUID: String] = [:]

        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date())!

        for (idx, search) in searchesToFetch.enumerated() {
            if idx > 0 {
                // 3-second delay between API calls
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            fetchProgress = "Checking \(search.name)... (\(idx + 1)/\(searchesToFetch.count))"

            do {
                let papers = try await ArXivAPIClient.fetch(search: search)
                let fetchTime = formatter.string(from: Date())

                for paper in papers {
                    let paperID = paper.id

                    if let existing = matchedPapers[paperID] {
                        // Already in history — check for revision using parsed dates
                        if let apiUpdated = formatter.date(from: paper.updatedAt),
                           let storedUpdated = formatter.date(from: existing.updatedAt),
                           apiUpdated > storedUpdated {
                            // Newer version — revision
                            if var pending = pendingRevisions[paperID] {
                                if !pending.matchedSearchIDs.contains(search.id) {
                                    pending.matchedSearchIDs.append(search.id)
                                }
                                pendingRevisions[paperID] = pending
                            } else {
                                var searchIDs = existing.matchedSearchIDs
                                if !searchIDs.contains(search.id) {
                                    searchIDs.append(search.id)
                                }
                                pendingRevisions[paperID] = MatchedPaper(
                                    id: paper.id,
                                    title: paper.title,
                                    authors: paper.authors,
                                    primaryCategory: paper.primaryCategory,
                                    categories: paper.categories,
                                    publishedAt: paper.publishedAt,
                                    updatedAt: paper.updatedAt,
                                    link: paper.link,
                                    matchedSearchIDs: searchIDs,
                                    foundAt: existing.foundAt,
                                    isNew: true
                                )
                            }
                        } else {
                            // No change — just record search ID
                            var ids = pendingSearchIDs[paperID] ?? []
                            ids.insert(search.id)
                            pendingSearchIDs[paperID] = ids
                        }
                    } else if var pending = pendingNew[paperID] {
                        // Already in pendingNew from another search
                        if !pending.matchedSearchIDs.contains(search.id) {
                            pending.matchedSearchIDs.append(search.id)
                        }
                        pending.isNew = true
                        pendingNew[paperID] = pending
                    } else {
                        // New paper not in history
                        // Skip stale papers (>90 days, not revised) using parsed dates
                        if let pubDate = formatter.date(from: paper.publishedAt),
                           pubDate < ninetyDaysAgo,
                           paper.updatedAt == paper.publishedAt {
                            continue
                        }

                        pendingNew[paperID] = MatchedPaper(
                            id: paper.id,
                            title: paper.title,
                            authors: paper.authors,
                            primaryCategory: paper.primaryCategory,
                            categories: paper.categories,
                            publishedAt: paper.publishedAt,
                            updatedAt: paper.updatedAt,
                            link: paper.link,
                            matchedSearchIDs: [search.id],
                            foundAt: fetchTime,
                            isNew: true
                        )
                    }
                }

                successfulTimestamps[search.id] = fetchTime
            } catch {
                print("[ArXivMonitor] Fetch failed for '\(search.name)': \(error)")
                failedSearchIDs.insert(search.id)
            }
        }

        // Commit atomically
        // Insert new papers
        for (id, paper) in pendingNew {
            matchedPapers[id] = paper
        }
        // Apply revisions
        for (id, paper) in pendingRevisions {
            matchedPapers[id] = paper
        }
        // Merge search IDs
        for (paperID, searchIDs) in pendingSearchIDs {
            if var paper = matchedPapers[paperID] {
                for sid in searchIDs {
                    if !paper.matchedSearchIDs.contains(sid) {
                        paper.matchedSearchIDs.append(sid)
                    }
                }
                matchedPapers[paperID] = paper
            }
        }
        // Update timestamps — skip if search was edited mid-cycle (clauses changed)
        for (searchID, timestamp) in successfulTimestamps {
            if let idx = savedSearches.firstIndex(where: { $0.id == searchID }) {
                // If lastQueriedAt is nil and this search was NOT in the original baseline,
                // it was reset mid-cycle by an edit — don't overwrite
                let wasBaseline = baselineSearchIDs.contains(searchID)
                let currentlyNil = savedSearches[idx].lastQueriedAt == nil
                if currentlyNil && !wasBaseline {
                    continue // skip — search was edited mid-cycle
                }
                savedSearches[idx].lastQueriedAt = timestamp
            }
        }
        // Update cycle state
        lastCycleAt = cycleStartedAt
        lastCycleFailedSearchIDs = Array(failedSearchIDs)

        // Prune old papers (>90 days based on foundAt)
        pruneOldPapers(before: ninetyDaysAgo)

        // Persist
        save()

        // Notify about new papers from this cycle (skip papers that only matched baseline searches)
        let newThisCycle = (Array(pendingNew.values) + Array(pendingRevisions.values)).filter { paper in
            paper.isNew && paper.matchedSearchIDs.contains(where: { !baselineSearchIDs.contains($0) })
        }
        if !newThisCycle.isEmpty {
            NotificationService.shared.notifyNewPapers(newThisCycle, soundName: soundName)
        }

        print("[ArXivMonitor] Fetch cycle complete: \(pendingNew.count) new, \(pendingRevisions.count) revised, \(failedSearchIDs.count) failed")

        isFetching = false
        fetchProgress = nil
    }

    private func pruneOldPapers(before cutoff: Date) {
        let formatter = ISO8601DateFormatter()
        var toRemove: [String] = []
        for (id, paper) in matchedPapers {
            if let foundDate = formatter.date(from: paper.foundAt), foundDate < cutoff {
                toRemove.append(id)
            }
        }
        for id in toRemove {
            matchedPapers.removeValue(forKey: id)
        }
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[ArXivMonitor] Failed to update launch at login: \(error)")
        }
    }

    // MARK: - Sample Data (debug)

    func loadSampleData() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())

        let search1 = SavedSearch(
            name: "Mirror Symmetry",
            clauses: [SearchClause(field: .keyword, value: "Mirror Symmetry", scope: .titleAndAbstract)],
            lastQueriedAt: now
        )
        let search2 = SavedSearch(
            name: "Gromov-Witten",
            clauses: [SearchClause(field: .keyword, value: "Gromov-Witten", scope: .titleAndAbstract)],
            lastQueriedAt: now
        )

        savedSearches = [search1, search2]
        matchedPapers = [
            "2602.04232": MatchedPaper(
                id: "2602.04232",
                title: "Mirror symmetry for lattice-polarized abelian surfaces",
                authors: "Fan, Y.-W., Lai, K.-W.",
                primaryCategory: "math.AG",
                categories: ["math.AG", "hep-th"],
                publishedAt: "2026-02-04T05:51:29Z",
                updatedAt: "2026-02-07T15:17:22Z",
                link: "https://arxiv.org/abs/2602.04232",
                matchedSearchIDs: [search1.id],
                foundAt: now,
                isNew: true
            ),
            "2602.08153": MatchedPaper(
                id: "2602.08153",
                title: "Mock modularity of log Gromov-Witten invariants",
                authors: "Arguz, H.",
                primaryCategory: "math.AG",
                categories: ["math.AG", "math.SG"],
                publishedAt: "2026-02-08T23:00:43Z",
                updatedAt: "2026-02-08T23:00:43Z",
                link: "https://arxiv.org/abs/2602.08153",
                matchedSearchIDs: [search2.id, search1.id],
                foundAt: now,
                isNew: true
            ),
            "2602.04866": MatchedPaper(
                id: "2602.04866",
                title: "Homological mirror symmetry for orbifold log Calabi-Yau surfaces",
                authors: "Simeonov, B.",
                primaryCategory: "math.AG",
                categories: ["math.AG"],
                publishedAt: "2026-02-04T18:52:46Z",
                updatedAt: "2026-02-04T18:52:46Z",
                link: "https://arxiv.org/abs/2602.04866",
                matchedSearchIDs: [search1.id],
                foundAt: now,
                isNew: false
            )
        ]
        lastCycleAt = now
        lastCycleFailedSearchIDs = []
        save()
    }
}
