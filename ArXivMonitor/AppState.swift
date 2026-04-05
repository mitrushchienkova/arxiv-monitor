import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications

/// Current data schema version. Increment when making breaking changes to PersistedData.
let currentDataVersion = 1

/// Persisted data structure for data.json.
struct PersistedData: Codable {
    var dataVersion: Int
    var savedSearches: [SavedSearch]
    var matchedPapers: [String: MatchedPaper]
    var lastCycleAt: String?
    var lastCycleFailedSearchIDs: [UUID]

    static let empty = PersistedData(
        dataVersion: currentDataVersion,
        savedSearches: [],
        matchedPapers: [:],
        lastCycleAt: nil,
        lastCycleFailedSearchIDs: []
    )

    init(dataVersion: Int = currentDataVersion, savedSearches: [SavedSearch], matchedPapers: [String: MatchedPaper],
         lastCycleAt: String?, lastCycleFailedSearchIDs: [UUID]) {
        self.dataVersion = dataVersion
        self.savedSearches = savedSearches
        self.matchedPapers = matchedPapers
        self.lastCycleAt = lastCycleAt
        self.lastCycleFailedSearchIDs = lastCycleFailedSearchIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataVersion = try container.decodeIfPresent(Int.self, forKey: .dataVersion) ?? 1
        savedSearches = try container.decode([SavedSearch].self, forKey: .savedSearches)
        matchedPapers = try container.decode([String: MatchedPaper].self, forKey: .matchedPapers)
        lastCycleAt = try container.decodeIfPresent(String.self, forKey: .lastCycleAt)
        lastCycleFailedSearchIDs = try container.decodeIfPresent([UUID].self, forKey: .lastCycleFailedSearchIDs) ?? []
    }
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
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var exportStatusMessage: String?

    /// Retained reference for the notification delegate (set by ArXivMonitorApp).
    var notificationDelegate: AnyObject?

    /// When set, exportData() writes here instead of showing NSSavePanel. For testing only.
    var testExportURL: URL?

    // MARK: - Settings (UserDefaults)
    @AppStorage("soundName") var soundName: String = "paperFlip"
    @AppStorage("badgeStyle") var badgeStyle: String = "count"
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet {
            updateLaunchAtLogin()
        }
    }

    // MARK: - Derived
    var unreadCount: Int {
        matchedPapers.values.filter { $0.isNew && !$0.isTrash }.count
    }

    var newPapers: [MatchedPaper] {
        matchedPapers.values
            .filter { $0.isNew && !$0.isTrash }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var allPapersSorted: [MatchedPaper] {
        matchedPapers.values
            .filter { !$0.isTrash }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var trashedPapers: [MatchedPaper] {
        matchedPapers.values
            .filter(\.isTrash)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func papers(for searchID: UUID) -> [MatchedPaper] {
        matchedPapers.values
            .filter { $0.matchedSearchIDs.contains(searchID) && !$0.isTrash }
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
        normalizeStoredPreferences()
        load()
        NotificationService.shared.registerActions()
        performBackupIfNeeded()
        let hasSavedSearches = !savedSearches.isEmpty
        Task { [weak self] in
            guard let self else { return }
            await self.refreshNotificationAuthorizationStatus(requestIfNeeded: hasSavedSearches)
        }
    }

    private func normalizeStoredPreferences() {
        if badgeStyle == "dot" {
            badgeStyle = "none"
        }

        let supportedSounds: Set<String> = ["paperFlip", "default", "none"]
        if !supportedSounds.contains(soundName) {
            soundName = "paperFlip"
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: dataFileURL)
            let persisted = try JSONDecoder().decode(PersistedData.self, from: data)

            // Auto-backup before applying any migration
            if persisted.dataVersion < currentDataVersion {
                print("[ArXivMonitor] Migrating data from version \(persisted.dataVersion) to \(currentDataVersion)")
                let fm = FileManager.default
                try? fm.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
                let migrationBackup = backupDirectoryURL.appendingPathComponent("pre-migration-v\(persisted.dataVersion).json")
                try? data.write(to: migrationBackup, options: .atomic)
            }

            savedSearches = persisted.savedSearches
            matchedPapers = persisted.matchedPapers
            lastCycleAt = persisted.lastCycleAt
            lastCycleFailedSearchIDs = persisted.lastCycleFailedSearchIDs

            // Re-save to update version stamp if needed
            if persisted.dataVersion < currentDataVersion {
                save()
            }
        } catch {
            print("[ArXivMonitor] Failed to load data.json, starting fresh: \(error)")
        }
    }

    private func makePersistedData() -> PersistedData {
        PersistedData(
            savedSearches: savedSearches,
            matchedPapers: matchedPapers,
            lastCycleAt: lastCycleAt,
            lastCycleFailedSearchIDs: lastCycleFailedSearchIDs
        )
    }

    func encodedPersistedData() throws -> Data {
        try JSONEncoder().encode(makePersistedData())
    }

    private func save() {
        do {
            let data = try encodedPersistedData()
            try data.write(to: dataFileURL, options: .atomic)
        } catch {
            print("[ArXivMonitor] Failed to save data.json: \(error)")
        }
    }

    // MARK: - Export & Backup

    /// Tracks last backup check to avoid re-checking on every save.
    private var lastBackupCheckDate: Date?

    private var backupDirectoryURL: URL {
        dataDirectoryURL.appendingPathComponent("backups", isDirectory: true)
    }

    func exportData() {
        exportStatusMessage = nil

        // Test mode: bypass NSSavePanel (it can't appear in LSUIElement apps under XCUITest)
        if let testURL = testExportURL {
            finishExport(to: testURL)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ArXivMonitor-data.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        // Find a titled, visible window (the Settings window) for sheet presentation.
        // Avoid the MenuBarExtra popover which is visible but can't host sheets.
        let hostWindow = NSApplication.shared.windows.first {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.styleMask.contains(.closable)
        }

        if let hostWindow {
            panel.beginSheetModal(for: hostWindow) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    self?.finishExport(to: url)
                }
            }
        } else {
            // Fallback for contexts without a visible titled window
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let response = panel.runModal()
            NSApplication.shared.setActivationPolicy(.accessory)
            guard response == .OK, let url = panel.url else { return }
            finishExport(to: url)
        }
    }

    private func finishExport(to url: URL) {
        do {
            try exportData(to: url)
            exportStatusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            exportStatusMessage = "Export failed: \(error.localizedDescription)"
            print("[ArXivMonitor] Export failed: \(error)")
        }
    }

    func exportData(to url: URL) throws {
        let data = try encodedPersistedData()
        try data.write(to: url, options: .atomic)
    }

    func refreshNotificationAuthorizationStatus(requestIfNeeded: Bool = false) async {
        let currentStatus = await NotificationService.shared.authorizationStatus()
        notificationAuthorizationStatus = currentStatus

        guard requestIfNeeded, currentStatus == .notDetermined else { return }

        _ = await NotificationService.shared.requestPermission()
        notificationAuthorizationStatus = await NotificationService.shared.authorizationStatus()
    }

    func enableNotifications() {
        Task {
            await refreshNotificationAuthorizationStatus(requestIfNeeded: true)
        }
    }

    func openNotificationSettings() {
        NotificationService.shared.openSystemNotificationSettings()
    }

    func sendTestNotification() {
        NotificationService.shared.sendTestNotification(soundName: soundName)
    }

    private func performBackupIfNeeded() {
        // In-memory throttle: don't check filesystem more than once per hour
        if let lastCheck = lastBackupCheckDate, Date().timeIntervalSince(lastCheck) < 3600 {
            return
        }
        lastBackupCheckDate = Date()

        let fm = FileManager.default
        guard fm.fileExists(atPath: dataFileURL.path) else { return }

        do {
            try fm.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[ArXivMonitor] Failed to create backup directory: \(error)")
            return
        }

        let backups = (try? fm.contentsOfDirectory(at: backupDirectoryURL,
                           includingPropertiesForKeys: [.creationDateKey],
                           options: .skipsHiddenFiles)) ?? []
        let sortedBackups = backups
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        if let mostRecent = sortedBackups.first {
            let name = mostRecent.deletingPathExtension().lastPathComponent
            let dateStr = String(name.dropFirst("backup-".count))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let backupDate = formatter.date(from: dateStr),
               Date().timeIntervalSince(backupDate) < 7 * 24 * 3600 {
                return
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: Date())
        let backupURL = backupDirectoryURL.appendingPathComponent("backup-\(timestamp).json")

        do {
            try fm.copyItem(at: dataFileURL, to: backupURL)
            print("[ArXivMonitor] Backup created: \(backupURL.lastPathComponent)")
        } catch {
            print("[ArXivMonitor] Backup failed: \(error)")
            return
        }

        // Re-read directory after creating new backup for accurate pruning
        let maxBackups = 4
        let updatedBackups = ((try? fm.contentsOfDirectory(at: backupDirectoryURL,
                                  includingPropertiesForKeys: nil,
                                  options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if updatedBackups.count > maxBackups {
            for old in updatedBackups.suffix(from: maxBackups) {
                try? fm.removeItem(at: old)
            }
        }
    }

    // MARK: - Search Management

    func addSearch(_ search: SavedSearch) {
        savedSearches.append(search)
        save()

        // Request notification permission on first search creation
        if savedSearches.count == 1 {
            Task {
                await refreshNotificationAuthorizationStatus(requestIfNeeded: true)
            }
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
        } else if old.fetchFromDate != updated.fetchFromDate {
            // Date window changed but clauses are the same — re-fetch but keep existing papers
            savedSearches[index].lastQueriedAt = nil
        }

        save()
    }

    func deleteSearch(_ searchID: UUID) {
        savedSearches.removeAll { $0.id == searchID }
        scrubSearchID(searchID)
        save()
    }

    func togglePause(_ searchID: UUID) {
        guard let index = savedSearches.firstIndex(where: { $0.id == searchID }) else { return }
        savedSearches[index].isPaused.toggle()
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
        guard var paper = matchedPapers[paperID] else { return }
        paper.isTrash = true
        paper.isNew = false
        matchedPapers[paperID] = paper
        save()
    }

    func restorePaper(_ paperID: String) {
        guard var paper = matchedPapers[paperID], paper.isTrash else { return }
        paper.isTrash = false
        matchedPapers[paperID] = paper
        save()
    }

    func emptyTrash() {
        let trashedIDs = matchedPapers.values.filter(\.isTrash).map(\.id)
        for id in trashedIDs {
            matchedPapers.removeValue(forKey: id)
        }
        save()
    }

    func markAllRead() {
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

    func markRead(paperID: String) {
        guard var paper = matchedPapers[paperID], paper.isNew else { return }
        paper.isNew = false
        matchedPapers[paperID] = paper
        save()
    }

    func markUnread(paperID: String) {
        guard var paper = matchedPapers[paperID], !paper.isNew else { return }
        paper.isNew = true
        matchedPapers[paperID] = paper
        save()
    }

    func toggleRead(paperID: String) {
        if matchedPapers[paperID]?.isNew == true {
            markRead(paperID: paperID)
        } else {
            markUnread(paperID: paperID)
        }
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
                guard !search.isPaused else { return false }
                guard let lastQueried = search.lastQueriedAt,
                      let date = formatter.date(from: lastQueried) else {
                    return true
                }
                return date < threshold
            }
        } else {
            searchesToFetch = savedSearches.filter { !$0.isPaused }
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

        for (idx, search) in searchesToFetch.enumerated() {
            if idx > 0 {
                // 3-second delay between API calls
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            fetchProgress = "Checking \(search.name)... (\(idx + 1)/\(searchesToFetch.count))"

            do {
                let searchName = search.name
                let searchIdx = idx + 1
                let searchCount = searchesToFetch.count
                let papers = try await ArXivAPIClient.fetch(search: search) { page, totalPages in
                    if totalPages > 1 {
                        Task { @MainActor [weak self] in
                            self?.fetchProgress = "Checking \(searchName)... page \(page)/\(totalPages) (\(searchIdx)/\(searchCount))"
                        }
                    }
                }
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
                                    isNew: !existing.isTrash,
                                    isTrash: existing.isTrash
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

        // Check if a backup is due (handles long-running menu bar apps)
        performBackupIfNeeded()

        isFetching = false
        fetchProgress = nil
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
            lastQueriedAt: now,
            colorHex: searchColorPalette[0]
        )
        let search2 = SavedSearch(
            name: "Gromov-Witten",
            clauses: [SearchClause(field: .keyword, value: "Gromov-Witten", scope: .titleAndAbstract)],
            lastQueriedAt: now,
            colorHex: searchColorPalette[1]
        )
        let search3 = SavedSearch(
            name: "Derived Categories",
            clauses: [SearchClause(field: .keyword, value: "derived categories", scope: .titleAndAbstract)],
            lastQueriedAt: now,
            colorHex: searchColorPalette[2],
            isPaused: true
        )

        savedSearches = [search1, search2, search3]
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
            ),
            "2602.09100": MatchedPaper(
                id: "2602.09100",
                title: "Derived categories of toric varieties and their mirrors",
                authors: "Kontsevich, M., Soibelman, Y.",
                primaryCategory: "math.AG",
                categories: ["math.AG", "math.CT"],
                publishedAt: "2026-02-10T12:00:00Z",
                updatedAt: "2026-02-10T12:00:00Z",
                link: "https://arxiv.org/abs/2602.09100",
                matchedSearchIDs: [search3.id, search1.id],
                foundAt: now,
                isNew: false
            )
        ]
        lastCycleAt = now
        lastCycleFailedSearchIDs = []
        save()
    }
}
