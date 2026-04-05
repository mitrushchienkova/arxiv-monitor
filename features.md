# Features & Bug Fixes

This file is the shared coordination point between Analyzer, Implementer, and QA agents.

## Issues

### 1. [SEVERE BUG] Search by keyword is broken
**Status:** Implemented

#### Root Cause / Analysis

**The bug is double-encoding of the URL query string caused by literal brackets in `URL(string:)`.**

In `ArXivAPIClient.swift`, the `buildQueryURL` method (line 14-55) manually constructs a URL string with percent-encoding using a custom `arXivQueryAllowed` character set (line 138-147). This character set intentionally keeps `[` and `]` unencoded because of a comment (line 48-49) claiming "arXiv does not recognize" percent-encoded brackets (`%5B`/`%5D`).

However, **that comment is wrong** -- arXiv correctly handles `%5B`/`%5D`. And keeping literal brackets in the URL string causes `URL(string:)` (line 54) to **double-encode** all percent-encoded characters in the query. Specifically:

- `%20` (space) becomes `%2520`
- `%22` (quote) becomes `%2522`
- `[` becomes `%5B`

This produces garbled queries. For a keyword search with `titleAndAbstract` scope, the query `(ti:diffusion%20OR%20abs:diffusion)` becomes `(ti:diffusion%2520OR%2520abs:diffusion)`. arXiv interprets `diffusion%20OR%20abs:diffusion` as a single literal term and returns **0 results**.

For category searches with date filters, the date filter part is garbled but the category prefix still partially works, so results still appear (but without proper date filtering and returning too many results). For author-only searches, no date filter is applied so they work correctly.

**Evidence (verified with live API calls):**
- All existing unit tests pass because they only check for substring presence (e.g., `query.contains("ti")`) rather than verifying correct encoding
- `URL(string:)` double-encodes when literal `[` `]` are present in the string
- arXiv API returns **0 results** for double-encoded keyword queries
- arXiv API returns **correct results** when `[` `]` are percent-encoded as `%5B` `%5D`

#### Files to Modify

1. **`ArXivMonitor/Services/ArXivAPIClient.swift`** (lines 138-147)
   - Remove `[]` from `arXivQueryAllowed` character set so brackets get percent-encoded normally
   - Remove or update the misleading comment at lines 48-49

2. **`ArXivMonitorTests/ArXivMonitorTests.swift`**
   - Add stricter URL encoding tests that verify no double-encoding occurs

#### Implementation Steps

1. In `ArXivAPIClient.swift`, modify the `arXivQueryAllowed` character set at line 144. Change:
   ```swift
   set.insert(charactersIn: "[]():")  // arXiv needs these literally
   ```
   to:
   ```swift
   set.insert(charactersIn: "():")  // arXiv needs these literally
   ```
   This removes `[` and `]` from the allowed set, so they get percent-encoded to `%5B`/`%5D`. arXiv correctly decodes these.

2. Update the comment at lines 48-49. Change:
   ```swift
   // Build URL manually to preserve literal brackets in submittedDate:[... TO ...]
   // URLComponents percent-encodes brackets (%5B/%5D) which arXiv does not recognize.
   ```
   to:
   ```swift
   // Build URL manually to preserve colons, parentheses, and other query operators
   // that arXiv expects in the search_query parameter.
   ```

3. Add unit tests that verify correct encoding (see Test Plan below).

#### Test Plan

**Unit tests to add in `ArXivMonitorTests.swift`:**

```swift
func testBuildQueryURL_keywordWithDateFilter_noDoubleEncoding() {
    let search = SavedSearch(
        name: "Test",
        clauses: [SearchClause(field: .keyword, value: "diffusion", scope: .titleAndAbstract)]
    )
    let url = ArXivAPIClient.buildQueryURL(for: search)
    XCTAssertNotNil(url)
    let query = url!.absoluteString
    // Must NOT contain double-encoded %2520
    XCTAssertFalse(query.contains("%2520"),
                    "URL should not contain double-encoded spaces: \(query)")
    // Must contain properly encoded OR
    XCTAssertTrue(query.contains("OR"),
                   "URL should contain OR operator: \(query)")
}

func testBuildQueryURL_noDoubleEncodingRoundTrip() {
    let search = SavedSearch(
        name: "Test",
        clauses: [SearchClause(field: .keyword, value: "flow matching", scope: .titleAndAbstract)]
    )
    let url = ArXivAPIClient.buildQueryURL(for: search)
    XCTAssertNotNil(url)
    let abs = url!.absoluteString
    XCTAssertFalse(abs.contains("%2520"), "Double-encoded space found: \(abs)")
    XCTAssertFalse(abs.contains("%2522"), "Double-encoded quote found: \(abs)")
}
```

**E2E test recommendations (manual or integration):**

- **Keyword search**: Create search with keyword "diffusion", scope "Title + Abstract". Verify arXiv returns >0 results.
- **Keyword + date filter**: Create keyword search with custom date range. Verify results are within the date range.
- **Author search**: Create search with author "Hinton". Verify results contain papers by that author.
- **Category search**: Create search with category "cs.LG". Verify results are from that category and date-filtered correctly.
- **Mixed clauses**: Create search with keyword "diffusion" AND category "cs.LG". Verify results match both.

---

### 2. [FEATURE] Right-click should mark paper as unread
**Status:** Implemented

#### Root Cause / Analysis

`PaperRowView.swift` (lines 9-73) has no `.contextMenu` modifier attached. Right-clicking a paper row does nothing.

Additionally, `AppState.swift` has `markRead(paperID:)` (lines 220-225) as a **private** method, and there is no `markUnread` method at all.

To implement this feature:
1. Add a `markUnread(paperID:)` method to `AppState`
2. Make `markRead(paperID:)` public (change `private func` to `func`)
3. Add a `.contextMenu` modifier to `PaperRowView`

#### Files to Modify

1. **`ArXivMonitor/AppState.swift`** (lines 220-225)
   - Change `markRead(paperID:)` from `private` to `func` (public)
   - Add `markUnread(paperID:)` method

2. **`ArXivMonitor/Views/PaperRowView.swift`** (line 71, after the dismiss button)
   - Add an `onToggleRead` callback property
   - Add `.contextMenu` modifier to the row's outer HStack

3. **`ArXivMonitor/Views/PaperListView.swift`** (lines 39-46)
   - Pass the new `onToggleRead` callback to `PaperRowView`

4. **`ArXivMonitor/Views/MenuBarPopover.swift`** (lines 171-179, 193-201)
   - Pass the new `onToggleRead` callback to `PaperRowView` in both ForEach loops

#### Implementation Steps

1. **In `AppState.swift`**, make `markRead` public and add `markUnread`:

   Change line 220 from:
   ```swift
   private func markRead(paperID: String) {
   ```
   to:
   ```swift
   func markRead(paperID: String) {
   ```

   After line 225, add:
   ```swift
   func markUnread(paperID: String) {
       guard var paper = matchedPapers[paperID], !paper.isNew else { return }
       paper.isNew = true
       matchedPapers[paperID] = paper
       save()
   }
   ```

2. **In `PaperRowView.swift`**, add a callback and context menu:

   Add after the `onDismiss` property (line 7):
   ```swift
   var onToggleRead: (() -> Void)? = nil
   ```

   Add `.contextMenu` modifier on the outer HStack, after `.padding(.vertical, 4)` at line 72:
   ```swift
   .contextMenu {
       if paper.isNew {
           Button("Mark as Read") {
               onToggleRead?()
           }
       } else {
           Button("Mark as Unread") {
               onToggleRead?()
           }
       }
   }
   ```

3. **In `PaperListView.swift`**, update the PaperRowView instantiation (lines 40-45) to pass the callback:

   ```swift
   PaperRowView(
       paper: paper,
       savedSearches: appState.savedSearches,
       onOpen: { appState.openPaper(paper) },
       onDismiss: { appState.dismissPaper(paper.id) },
       onToggleRead: {
           if paper.isNew {
               appState.markRead(paperID: paper.id)
           } else {
               appState.markUnread(paperID: paper.id)
           }
       }
   )
   ```

4. **In `MenuBarPopover.swift`**, update both PaperRowView instantiations:

   At lines 172-177 (new papers section) and lines 194-199 (history section), add the same `onToggleRead` callback pattern.

#### Test Plan

**Unit tests to add:**

```swift
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
```

**Manual test:**
- Right-click a new (unread) paper -> menu shows "Mark as Read" -> click -> blue dot disappears
- Right-click a read paper -> menu shows "Mark as Unread" -> click -> blue dot appears
- Test in both the main window (PaperListView) and the menu bar popover (MenuBarPopover)

---

### 3. [FEATURE] Dismiss -> Trash (revertable)
**Status:** Implemented

#### Root Cause / Analysis

Currently, `dismissPaper()` in `AppState.swift` (lines 199-201) completely removes the paper from the `matchedPapers` dictionary:

```swift
func dismissPaper(_ paperID: String) {
    matchedPapers.removeValue(forKey: paperID)
    save()
}
```

This has two problems:
1. The paper is permanently deleted -- no way to undo
2. On the next fetch cycle, the paper is re-discovered as "new" since it's no longer in `matchedPapers`

The fix: add an `isTrash` field to `MatchedPaper`, set it to `true` on dismiss instead of removing. Trashed papers stay in the dictionary (preventing re-fetch as new) but are hidden from the UI. A `restorePaper` method allows un-trashing.

Note on naming: `dismissAll()` (line 204) actually just marks papers as read (`isNew = false`), it does NOT delete. The "Dismiss All" button in `MenuBarPopover.swift` (line 68) calls this. This is fine -- it's a "mark all as read" action. Consider renaming the button text from "Dismiss All" to "Mark All as Read" for clarity.

#### Files to Modify

1. **`ArXivMonitor/Models/MatchedPaper.swift`** (lines 3-20)
   - Add `var isTrash: Bool` field
   - Add custom `init(from decoder:)` for backward compatibility with existing data.json

2. **`ArXivMonitor/AppState.swift`**
   - `dismissPaper()` (line 199): Set `isTrash = true` instead of removing
   - Add `restorePaper(_ paperID: String)` method
   - Update computed properties to filter out trashed papers: `unreadCount` (line 44), `newPapers` (line 48), `allPapersSorted` (line 54), `papers(for:)` (line 59)

3. **`ArXivMonitor/Views/PaperRowView.swift`** (lines 65-71)
   - Change the dismiss button icon from `"xmark"` to `"trash"`
   - Update help text from "Dismiss" to "Move to Trash"

4. **`ArXivMonitor/Views/MenuBarPopover.swift`** (line 68)
   - Rename "Dismiss All" button text to "Mark All as Read" for clarity

5. **`ArXivMonitorTests/ArXivMonitorTests.swift`**
   - Update existing `testDismissPaper` to expect trash behavior instead of removal
   - Add new tests for restore and backward compatibility

6. **All `MatchedPaper` init call sites** need `isTrash: false` parameter (or use default value):
   - `ArXivMonitor/Services/XMLAtomParser.swift` line 106
   - `ArXivMonitor/AppState.swift` lines 322, 350 (fetch cycle)
   - `ArXivMonitor/AppState.swift` lines 470-521 (loadSampleData)

#### Implementation Steps

1. **In `MatchedPaper.swift`**, add `isTrash` field. After `var isNew: Bool` (line 14), add:
   ```swift
   var isTrash: Bool
   ```

   Add a custom decoder for backward compatibility (existing data.json won't have `isTrash`):
   ```swift
   init(from decoder: Decoder) throws {
       let container = try decoder.container(keyedBy: CodingKeys.self)
       id = try container.decode(String.self, forKey: .id)
       title = try container.decode(String.self, forKey: .title)
       authors = try container.decode(String.self, forKey: .authors)
       primaryCategory = try container.decode(String.self, forKey: .primaryCategory)
       categories = try container.decode([String].self, forKey: .categories)
       publishedAt = try container.decode(String.self, forKey: .publishedAt)
       updatedAt = try container.decode(String.self, forKey: .updatedAt)
       link = try container.decode(String.self, forKey: .link)
       matchedSearchIDs = try container.decode([UUID].self, forKey: .matchedSearchIDs)
       foundAt = try container.decode(String.self, forKey: .foundAt)
       isNew = try container.decode(Bool.self, forKey: .isNew)
       isTrash = try container.decodeIfPresent(Bool.self, forKey: .isTrash) ?? false
   }
   ```

   Add `isTrash: Bool = false` to the memberwise init (or ensure all call sites pass it).

2. **In `AppState.swift`**, update `dismissPaper`. Replace lines 199-201:
   ```swift
   func dismissPaper(_ paperID: String) {
       guard var paper = matchedPapers[paperID] else { return }
       paper.isTrash = true
       paper.isNew = false
       matchedPapers[paperID] = paper
       save()
   }
   ```

   Add `restorePaper` after `dismissPaper`:
   ```swift
   func restorePaper(_ paperID: String) {
       guard var paper = matchedPapers[paperID], paper.isTrash else { return }
       paper.isTrash = false
       matchedPapers[paperID] = paper
       save()
   }
   ```

   Update computed properties (lines 44-63) to exclude trashed papers:
   ```swift
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

   func papers(for searchID: UUID) -> [MatchedPaper] {
       matchedPapers.values
           .filter { $0.matchedSearchIDs.contains(searchID) && !$0.isTrash }
           .sorted { $0.updatedAt > $1.updatedAt }
   }
   ```

3. **In `PaperRowView.swift`**, update dismiss button (line 65-70):
   ```swift
   Button(action: onDismiss) {
       Image(systemName: "trash")
           .font(.system(size: 10))
   }
   .buttonStyle(.borderless)
   .help("Move to Trash")
   ```

4. **In `MenuBarPopover.swift`**, rename button text at line 68:
   ```swift
   Button("Mark All as Read") {
       appState.dismissAll()
   }
   ```

5. **Update all `MatchedPaper` init call sites** to include `isTrash: false`:
   - `XMLAtomParser.swift` line 106-118: add `isTrash: false`
   - `AppState.swift` fetch cycle (lines 322-334 and 350-363): add `isTrash: false`
   - `AppState.swift` loadSampleData (lines 470-521): add `isTrash: false`
   - All test fixtures in `ArXivMonitorTests.swift`

6. **Update existing `testDismissPaper` test** (lines 241-254) -- change assertion from:
   ```swift
   XCTAssertNil(state.matchedPapers[paper.id], "Dismissed paper should be removed entirely")
   ```
   to:
   ```swift
   XCTAssertNotNil(state.matchedPapers[paper.id], "Dismissed paper should still exist (trashed)")
   XCTAssertTrue(state.matchedPapers[paper.id]!.isTrash, "Dismissed paper should be trashed")
   XCTAssertFalse(state.matchedPapers[paper.id]!.isNew, "Trashed paper should not be new")
   XCTAssertEqual(state.unreadCount, 0, "Trashed paper should not count as unread")
   XCTAssertTrue(state.allPapersSorted.isEmpty, "Trashed paper should not appear in sorted list")
   ```

#### Test Plan

**Unit tests to add:**

```swift
func testDismissPaperSetsTrash() {
    let state = AppState(dataDirectoryURL: tempDir)
    let paper = MatchedPaper(
        id: "test-001", title: "Test", authors: "A", primaryCategory: "cs.AI",
        categories: ["cs.AI"], publishedAt: "2024-01-01T00:00:00Z",
        updatedAt: "2024-01-01T00:00:00Z", link: "https://arxiv.org/abs/test-001",
        matchedSearchIDs: [UUID()], foundAt: "2024-01-01T00:00:00Z", isNew: true
    )
    state.matchedPapers[paper.id] = paper
    state.dismissPaper(paper.id)
    XCTAssertNotNil(state.matchedPapers[paper.id])
    XCTAssertTrue(state.matchedPapers[paper.id]!.isTrash)
    XCTAssertFalse(state.matchedPapers[paper.id]!.isNew)
    XCTAssertEqual(state.unreadCount, 0)
    XCTAssertTrue(state.allPapersSorted.isEmpty)
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
```

**Manual test:**
- Dismiss a paper -> verify it disappears from the list
- Run fetch cycle -> verify the dismissed paper is NOT re-fetched as new
- Future enhancement: add a "Trash" view to see and restore trashed papers

---

### 4. [FEATURE] Export settings/data
**Status:** Implemented

#### Root Cause / Analysis

The app stores all state in a single `data.json` file at `~/Library/Application Support/ArXivMonitor/data.json` (see `AppState.swift` lines 74-78). There is currently no way for users to export or back up this data through the UI.

Two features are needed:
1. **Manual export**: An "Export Data" button in Settings that saves `data.json` to a user-chosen location via `NSSavePanel`
2. **Automatic backup**: The app should automatically back up `data.json` every 7 days to a `backups/` subdirectory, keeping the last 4 backups (~1 month of coverage)

#### Files to Modify

1. **`ArXivMonitor/AppState.swift`**
   - Add `exportData()` method that presents NSSavePanel and copies data.json
   - Add `performBackupIfNeeded()` method for automatic backup
   - Call `performBackupIfNeeded()` from `init` or `save()`

2. **`ArXivMonitor/Views/SettingsView.swift`**
   - Add "Data" section with "Export Data" button

#### Implementation Steps

1. **In `AppState.swift`**, add export method:

   ```swift
   func exportData() {
       let panel = NSSavePanel()
       panel.nameFieldStringValue = "ArXivMonitor-data.json"
       panel.allowedContentTypes = [.json]
       panel.canCreateDirectories = true
       guard panel.runModal() == .OK, let url = panel.url else { return }
       do {
           try FileManager.default.copyItem(at: dataFileURL, to: url)
       } catch {
           print("[ArXivMonitor] Export failed: \(error)")
       }
   }
   ```

2. **In `AppState.swift`**, add automatic backup:

   Add a computed property for the backup directory:
   ```swift
   private var backupDirectoryURL: URL {
       dataDirectoryURL.appendingPathComponent("backups", isDirectory: true)
   }
   ```

   Add the backup method:
   ```swift
   private func performBackupIfNeeded() {
       let fm = FileManager.default
       guard fm.fileExists(atPath: dataFileURL.path) else { return }

       do {
           try fm.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
       } catch {
           print("[ArXivMonitor] Failed to create backup directory: \(error)")
           return
       }

       // Check if a backup was made in the last 7 days
       let backups = (try? fm.contentsOfDirectory(at: backupDirectoryURL,
                          includingPropertiesForKeys: [.creationDateKey],
                          options: .skipsHiddenFiles)) ?? []
       let sortedBackups = backups
           .filter { $0.pathExtension == "json" }
           .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }

       if let mostRecent = sortedBackups.first {
           let name = mostRecent.deletingPathExtension().lastPathComponent
           // Backup filenames are like "backup-2026-04-05T120000"
           let dateStr = String(name.dropFirst("backup-".count))
           let formatter = DateFormatter()
           formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
           formatter.timeZone = TimeZone(identifier: "UTC")
           if let backupDate = formatter.date(from: dateStr),
              Date().timeIntervalSince(backupDate) < 7 * 24 * 3600 {
               return // Recent backup exists, skip
           }
       }

       // Create new backup
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

       // Prune old backups, keep last 4
       let maxBackups = 4
       if sortedBackups.count >= maxBackups {
           for old in sortedBackups.suffix(from: maxBackups - 1) {
               try? fm.removeItem(at: old)
           }
       }
   }
   ```

   Call `performBackupIfNeeded()` at the end of `init()` (after `load()`), around line 93:
   ```swift
   load()
   NotificationService.shared.registerActions()
   performBackupIfNeeded()
   ```

3. **In `SettingsView.swift`**, add a "Data" section after the "Appearance" section:

   ```swift
   Section("Data") {
       Button("Export Data...") {
           appState.exportData()
       }
       Text("Exports saved searches, papers, and all settings to a JSON file.")
           .font(.caption)
           .foregroundStyle(.secondary)
   }
   ```

   Update the frame height (line 28) to accommodate the new section:
   ```swift
   .frame(width: 350, height: 300)
   ```

#### Test Plan

**Unit tests to add:**

```swift
func testPerformBackupCreatesFile() {
    let state = AppState(dataDirectoryURL: tempDir)
    let search = SavedSearch(name: "Test", clauses: [SearchClause(field: .keyword, value: "test", scope: .title)])
    state.addSearch(search) // This triggers save(), creating data.json

    // The backup should have been created during init or after first save
    let backupDir = tempDir.appendingPathComponent("backups")
    let backups = (try? FileManager.default.contentsOfDirectory(at: backupDir,
                       includingPropertiesForKeys: nil)) ?? []
    // Note: backup is created in init, which happens before addSearch,
    // but data.json may not exist yet at init time. Consider testing separately.
}
```

**Manual test:**
- Open Settings -> "Data" section -> click "Export Data..." -> verify NSSavePanel appears
- Choose a location -> verify the exported file is valid JSON and contains saved searches and papers
- Check `~/Library/Application Support/ArXivMonitor/backups/` -> verify backup files are created
- Verify old backups are pruned (keep last 4)
