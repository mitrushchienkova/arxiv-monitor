# arXiv Monitor - Fixes

## Fix 1: Popover not showing papers (ScrollView collapses to zero height)

**Priority:** P0 (broken)

**File:** `ArXivMonitor/Views/MenuBarPopover.swift`, lines 165-211

**Problem:** The `paperList` view uses a `ScrollView` with `.frame(maxHeight: 400)`. Inside a `MenuBarExtra(.window)` popover, `ScrollView` has no intrinsic content size — `maxHeight` caps the height but provides no minimum, so the scroll view collapses to zero height and no papers are visible.

**Fix:** Replace `.frame(maxHeight: 400)` with `.frame(idealHeight: 300, maxHeight: 400)` so the scroll view gets a proposed size within the popover window. Alternatively, use `.frame(minHeight: 100, maxHeight: 400)` to guarantee a minimum height even with few papers.

```swift
// Line 210: Change
.frame(maxHeight: 400)
// To
.frame(idealHeight: 300, maxHeight: 400)
```

---

## Fix 2: Sample data uses fake relative dates instead of real arXiv dates

**Priority:** P0 (broken)

**File:** `ArXivMonitor/AppState.swift`, lines 441-503

**Problem:** `loadSampleData()` computes dates relative to the current time:
```swift
let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))
let twoDaysAgo = formatter.string(from: Date().addingTimeInterval(-172800))
```
These produce timestamps like `2026-04-04T15:23:07Z` — clearly fake dates that don't match the actual arXiv publication dates for the referenced paper IDs (e.g., `2602.04232` was published in February 2026). This makes the sample data misleading and prevents testing the date display with realistic data.

**Fix:** Replace relative date computation with hardcoded real arXiv publication dates for the referenced papers:

```swift
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
            publishedAt: "2025-02-06T18:42:11Z",
            updatedAt: "2025-02-06T18:42:11Z",
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
            publishedAt: "2025-02-11T22:15:00Z",
            updatedAt: "2025-02-13T09:30:00Z",
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
            publishedAt: "2025-02-07T04:12:33Z",
            updatedAt: "2025-02-07T04:12:33Z",
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
```

Note: The exact arXiv timestamps should be verified against the actual papers. The key change is using fixed dates that correspond to the real publication dates of these papers, not relative dates from `Date()`.

---

## Fix 3: Query model only supports AND — user needs OR between clauses

**Priority:** P1 (important)

**Files:**
- `ArXivMonitor/Models/SavedSearch.swift`, lines 29-66
- `ArXivMonitor/Services/ArXivAPIClient.swift`, line 35
- `ArXivMonitor/Views/AddSearchSheet.swift`, line 31

**Problem:** All clauses in a `SavedSearch` are ANDed together (`ArXivAPIClient.swift:35`):
```swift
let searchQuery = queryParts.joined(separator: " AND ")
```
The user's research interests involve tracking multiple authors OR keywords (e.g., "papers by Author1 OR Author2 OR about topic X"). Currently, expressing this requires creating a separate saved search per author/keyword, which fragments the paper list and makes it hard to see a unified view.

**Fix:** Add a `combineOperator` field to `SavedSearch` that controls whether clauses are ANDed or ORed:

**Step 1:** Add the operator to `SavedSearch` (`SavedSearch.swift`):
```swift
enum ClauseCombineOperator: String, Codable, CaseIterable {
    case and, or
}

struct SavedSearch: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var clauses: [SearchClause]
    var combineOperator: ClauseCombineOperator  // new field
    var lastQueriedAt: String?

    init(id: UUID = UUID(), name: String, clauses: [SearchClause],
         combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil) {
        self.id = id
        self.name = name
        self.clauses = clauses
        self.combineOperator = combineOperator
        self.lastQueriedAt = lastQueriedAt
    }
}
```

Note: Use a default value of `.and` and make the property optional during decoding (or provide a `Decodable` init with a default) for backward compatibility with existing `data.json` files.

**Step 2:** Use the operator in query building (`ArXivAPIClient.swift:35`):
```swift
// Change:
let searchQuery = queryParts.joined(separator: " AND ")
// To:
let separator = search.combineOperator == .or ? " OR " : " AND "
let searchQuery = queryParts.joined(separator: separator)
```

**Step 3:** Add a picker in `AddSearchSheet.swift` to let the user choose AND/OR:
```swift
// After the "CLAUSES (ANDed together)" text, add a Picker:
Picker("Combine clauses with", selection: $combineOperator) {
    Text("AND (all must match)").tag(ClauseCombineOperator.and)
    Text("OR (any can match)").tag(ClauseCombineOperator.or)
}
.pickerStyle(.radioGroup)
```

Also update the `clausesEqual` method to include `combineOperator` in the comparison.

---

## Fix 4: "RECENT" section hidden when new papers exist

**Priority:** P2 (nice to have)

**File:** `ArXivMonitor/Views/MenuBarPopover.swift`, line 190

**Problem:** The condition `!historyPapers.isEmpty && newPapers.isEmpty` means the "RECENT" section only appears when there are zero new papers. When the user has both new and old papers, they only see the new ones in the popover — there's no context about recent history.

**Fix:** Remove the `newPapers.isEmpty` condition so both sections appear:

```swift
// Line 190: Change
if !historyPapers.isEmpty && newPapers.isEmpty {
// To
if !historyPapers.isEmpty {
```

This shows up to 5 recent history papers below the new papers section, giving the user context even when new papers exist. The popover's `maxHeight: 400` constraint will keep the total height reasonable.

---

## Fix 5: `clausesEqual` does not account for `combineOperator` (follow-on from Fix 3)

**Priority:** P1 (if Fix 3 is implemented)

**File:** `ArXivMonitor/Models/SavedSearch.swift`, lines 52-65

**Problem:** The `clausesEqual(to:)` method only compares clause contents. If Fix 3 adds `combineOperator`, changing a search from AND to OR would not be detected as a clause change, meaning `lastQueriedAt` would not be reset and the search would not be re-fetched with the new semantics.

**Fix:** Include `combineOperator` in the comparison:

```swift
func clausesEqual(to other: SavedSearch) -> Bool {
    guard combineOperator == other.combineOperator else { return false }
    guard clauses.count == other.clauses.count else { return false }
    // ... rest of existing comparison
}
```

---

## Fix 6: Backward compatibility for `combineOperator` in persisted data (follow-on from Fix 3)

**Priority:** P1 (if Fix 3 is implemented)

**File:** `ArXivMonitor/Models/SavedSearch.swift`

**Problem:** Existing `data.json` files from before Fix 3 won't have the `combineOperator` field. The default `Codable` synthesis will fail to decode them.

**Fix:** Either make the property optional with a computed default, or provide a custom `Decodable` init:

```swift
// Option A: Optional with default
var combineOperator: ClauseCombineOperator? // defaults to nil, treat nil as .and

// Option B: Custom decoder (preferred — cleaner API)
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    clauses = try container.decode([SearchClause].self, forKey: .clauses)
    combineOperator = try container.decodeIfPresent(ClauseCombineOperator.self, forKey: .combineOperator) ?? .and
    lastQueriedAt = try container.decodeIfPresent(String.self, forKey: .lastQueriedAt)
}
```

---

## Fix 7: History/Searches buttons are identical — replace with single button

**Priority:** P1 (important)

**File:** `ArXivMonitor/Views/MenuBarPopover.swift`, lines 58-69

**Problem:** Both "History" and "Searches" buttons call `openWindow(id: "main-window")` with no way to differentiate which view should be focused. The plan specifies History should show "All Papers" selected and Searches should focus the sidebar, but both do the same thing.

**Fix:** Replace both buttons with a single "Search filters & history" button:

```swift
// Lines 58-69: Replace
Button("History") {
    openWindow(id: "main-window")
}
.buttonStyle(.borderless)
.font(.system(size: 11))

Button("Searches") {
    openWindow(id: "main-window")
}
.buttonStyle(.borderless)
.font(.system(size: 11))

// With
Button("Search filters & history") {
    openWindow(id: "main-window")
}
.buttonStyle(.borderless)
.font(.system(size: 11))
```

---

## Fix 8: Notification permission denial not surfaced

**Priority:** P2 (nice to have — accepted for v1)

**File:** `ArXivMonitor/Services/NotificationService.swift`, lines 11-17

**Problem:** If the user denies notification permission, there is no UI indicator and no way to guide them to System Settings to re-enable it. The `requestPermission()` method only logs the result to console.

**Decision:** Accept for v1 — macOS system manages notification permissions via System Settings. No code change needed now.

---

## Fix 9: paper-flip.aiff missing — remove option from settings

**Priority:** P1 (important)

**Files:**
- `ArXivMonitor/Views/SettingsView.swift`, lines 13-17
- `ArXivMonitor/Services/NotificationService.swift`, lines 52-54

**Problem:** The Settings view offers a "Paper flip" sound option (`tag: "paper-flip"`), and `NotificationService` references `paper-flip.aiff`, but no such file exists in the Resources directory. Selecting it silently produces no sound (the `UNNotificationSound(named:)` initializer fails silently).

**Fix:** Remove the "Paper flip" option from the sound picker until the file is added:

```swift
// SettingsView.swift lines 13-17: Change
Picker("Sound", selection: $appState.soundName) {
    Text("Paper flip").tag("paper-flip")
    Text("Default").tag("default")
    Text("None").tag("none")
}

// To
Picker("Sound", selection: $appState.soundName) {
    Text("Default").tag("default")
    Text("None").tag("none")
}
```

Also update the default value in `AppState.swift` line 35 in case any user already has "paper-flip" saved:

```swift
// NotificationService.swift lines 52-54: Change the "paper-flip" case to fall through to default
switch soundName {
case "paper-flip", "default":
    content.sound = .default
case "none":
    content.sound = nil
default:
    content.sound = nil
}
```

---

## Fix 10: Tests share real data.json — inject temp directory for tests

**Priority:** P1 (important)

**File:** `ArXivMonitor/AppState.swift`, lines 74-83 and `ArXivMonitorTests/ArXivMonitorTests.swift`

**Problem:** `AppState.init()` reads from and writes to the real Application Support directory (`~/Library/Application Support/ArXivMonitor/data.json`). Tests that create `AppState()` instances (lines 219, 231, 246, etc.) read and mutate the user's real data file. This can clobber user data when tests run outside the Xcode sandbox, and causes test pollution between runs.

**Fix:** Make the data directory injectable so tests can use a temp directory:

```swift
// AppState.swift: Add a dataDirectoryURL parameter to init
@MainActor
final class AppState: ObservableObject {
    // ...
    private let dataDirectoryURL: URL

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

    private var dataFileURL: URL {
        dataDirectoryURL.appendingPathComponent("data.json")
    }
    // ... use dataFileURL instead of cachedDataFileURL throughout
}
```

```swift
// In tests, create a temp directory per test:
@MainActor
final class AppStateTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArXivMonitorTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAddAndDeleteSearch() {
        let state = AppState(dataDirectoryURL: tempDir)
        // ... rest of test
    }
    // ... same for all other AppState tests
}
```
