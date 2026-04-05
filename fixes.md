# arXiv Monitor -- Fixes

## Fix 1: Date-dependent fetch window by search type

**Files:**
- `ArXivMonitor/Models/SavedSearch.swift` (lines 33-83)
- `ArXivMonitor/Services/ArXivAPIClient.swift` (lines 14-46)
- `ArXivMonitor/AppState.swift` (lines 276, 338-343)

**Problem:** Currently, `ArXivAPIClient.buildQueryURL(for:)` builds the same query regardless of whether the search contains only author clauses or keyword/category clauses. All searches fetch the 100 most recently updated results with no date restriction in the API query. Then in `AppState.performFetchCycle()`, line 276 defines `ninetyDaysAgo` and lines 338-343 skip new papers older than 90 days (unless revised). This means:

1. Author-only searches miss papers older than 90 days that haven't been revised, even though the user wants ALL papers by that author.
2. Keyword searches have no API-level date restriction, relying only on the client-side 90-day skip which is fragile (it only skips unrevised papers, and the 100-result cap could push out recent results for broad searches).

The client wants:
- **Author-only searches**: No date restriction at all -- fetch all time.
- **Keyword searches** (or mixed searches with any keyword/category clause): Restrict to past 90 days via the arXiv API's `submittedDate` query field.

**Solution:**

### Step 1: Add `isAuthorOnly` computed property to `SavedSearch`

In `ArXivMonitor/Models/SavedSearch.swift`, add a computed property to `SavedSearch`:

```swift
/// True when every clause is an author clause (no keywords or categories).
var isAuthorOnly: Bool {
    !clauses.isEmpty && clauses.allSatisfy { $0.field == .author }
}
```

Add this after the `init(from decoder:)` method (after line 56), before the `==` operator.

### Step 2: Add date restriction to API query for non-author-only searches

In `ArXivMonitor/Services/ArXivAPIClient.swift`, modify `buildQueryURL(for:)` to append a `submittedDate` range when the search is NOT author-only.

The arXiv API supports date filtering via:
```
submittedDate:[YYYYMMDDHHII TO YYYYMMDDHHII]
```
where the format is `YYYYMMDDHHmm` (year, month, day, hour, minute).

Change the `buildQueryURL` method (lines 14-46) to:

```swift
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

    var components = URLComponents(string: baseURL)
    components?.queryItems = [
        URLQueryItem(name: "search_query", value: searchQuery),
        URLQueryItem(name: "sortBy", value: "lastUpdatedDate"),
        URLQueryItem(name: "sortOrder", value: "descending"),
        URLQueryItem(name: "max_results", value: "\(maxResults)")
    ]
    return components?.url
}
```

Key details:
- The `submittedDate` filter uses the submission date, not the last-updated date. This is the only date field the arXiv API supports for filtering.
- We wrap the existing query in parentheses before ANDing the date restriction, to preserve operator precedence.
- For author-only searches, no date restriction is added -- the API returns the 100 most recently updated papers by that author, spanning all time.

### Step 3: Remove the client-side 90-day skip for author-only searches

In `ArXivMonitor/AppState.swift`, the client-side skip at lines 338-343 currently drops all new papers older than 90 days (unless revised). This is redundant for keyword searches (the API already restricts to 90 days after Fix 1 Step 2) and wrong for author searches (we want all papers).

Remove the entire skip block (lines 338-343):

```swift
// DELETE these lines:
// Skip stale papers (>90 days, not revised) using parsed dates
if let pubDate = formatter.date(from: paper.publishedAt),
   pubDate < ninetyDaysAgo,
   paper.updatedAt == paper.publishedAt {
    continue
}
```

Since keyword searches are already date-restricted at the API level, this client-side filter is no longer needed. For author searches, we explicitly want ALL papers regardless of age.

Also remove the now-unused `ninetyDaysAgo` variable at line 276:
```swift
// DELETE this line (it's only used by the removed skip block and pruneOldPapers, which is also being removed in Fix 2):
let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
```

**Edge cases considered:**
- A search with one author clause AND one keyword clause is "mixed" and treated as keyword (90-day window). This is correct per the requirements.
- A search with multiple author clauses and no keywords is author-only (no date restriction). Correct.
- The `combineOperator` (AND/OR) does not affect this logic -- only the clause field types matter.

---

## Fix 2: Remove article pruning

**Files:**
- `ArXivMonitor/AppState.swift` (lines 405-406 and 425-436)

**Problem:** After each fetch cycle, `performFetchCycle()` calls `pruneOldPapers(before: ninetyDaysAgo)` at line 406. This method (lines 425-436) deletes all papers from `matchedPapers` whose `foundAt` timestamp is older than 90 days. The client wants to keep ALL papers forever once they have been fetched.

**Solution:**

### Step 1: Remove the pruneOldPapers call

In `AppState.swift`, delete line 405-406:
```swift
// DELETE these lines:
// Prune old papers (>90 days based on foundAt)
pruneOldPapers(before: ninetyDaysAgo)
```

### Step 2: Remove the pruneOldPapers method entirely

Delete the entire method at lines 425-436:
```swift
// DELETE this entire method:
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
```

**Note:** With both Fix 1 and Fix 2 applied, the `ninetyDaysAgo` variable at line 276 has no remaining uses and should be deleted (as mentioned in Fix 1 Step 3).

**Edge cases considered:**
- Data file growth: Over time `data.json` will grow unboundedly. For the user's niche searches (algebraic geometry / mirror symmetry), this is a few hundred papers per year at most -- negligible. No mitigation needed for v1.
- The `scrubSearchID` method (lines 164-177) still handles cleanup when a search is deleted, removing orphaned papers. This is correct and should be kept.

---

## Fix 3: Show total article counts in sidebar

**Files:**
- `ArXivMonitor/Views/SearchListView.swift` (lines 14-24 and 29-42)
- `ArXivMonitor/AppState.swift` (lines 59-63 -- `papers(for:)` method, already exists)

**Problem:** The sidebar currently shows only the **unread** count (purple badge) for "All Papers" and each saved search. The client wants to also show the **total** number of articles. Currently:

- "All Papers" row (lines 14-24): Shows `appState.unreadCount` (only unread papers).
- Each saved search row (lines 29-42): Shows `appState.papers(for: search.id).filter(\.isNew).count` (only unread papers for that search).

Neither shows the total paper count.

**Solution:**

### Step 1: Add total count badge to "All Papers" row

In `SearchListView.swift`, modify the "All Papers" section (lines 12-26) to show the total count in addition to the unread badge. The total count should always appear (as a subtle gray label), while the unread badge appears only when > 0.

Replace lines 12-26:
```swift
Section {
    HStack {
        Label("All Papers", systemImage: "doc.text")
        Spacer()
        let total = appState.matchedPapers.count
        let unread = appState.unreadCount
        if unread > 0 {
            Text("\(unread)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.purple, in: Capsule())
        }
        Text("\(total)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
    .tag(SidebarSelection.allPapers)
}
```

### Step 2: Add total count badge to each saved search row

Modify the ForEach block for saved searches (lines 29-42) to show total count alongside the unread badge.

Replace lines 30-42:
```swift
ForEach(appState.savedSearches) { search in
    HStack {
        Text(search.name)
        Spacer()
        let searchPapers = appState.papers(for: search.id)
        let total = searchPapers.count
        let unread = searchPapers.filter(\.isNew).count
        if unread > 0 {
            Text("\(unread)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.purple, in: Capsule())
        }
        Text("\(total)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
    .tag(SidebarSelection.search(search.id))
    .contextMenu {
        Button("Edit...") {
            editingSearch = search
        }
        Button("Delete", role: .destructive) {
            appState.deleteSearch(search.id)
        }
    }
}
```

**Design rationale:**
- The total count (gray, secondary text) always appears, giving the user a sense of how many papers exist for each search.
- The unread badge (purple capsule) appears only when there are unread papers, keeping the UI clean.
- The total count is placed to the right of the unread badge, so the visual hierarchy is: name ... [unread badge] [total].
- No new computed properties are needed -- `matchedPapers.count` gives the global total, and `papers(for:)` already returns filtered arrays whose `.count` gives per-search totals.

**Edge cases considered:**
- When unread == 0, only the total count is shown. Clean.
- When total == 0 (search has no matching papers yet), "0" is shown in gray. This is informative.
- Performance: `papers(for:)` iterates all papers for each search row. With hundreds of papers and a handful of searches, this is negligible. No caching needed for v1.

---

## Implementation order

These three fixes are independent and can be implemented in any order. However, the recommended order is:

1. **Fix 2** (remove pruning) -- simplest change, just deleting code
2. **Fix 1** (date-dependent fetch window) -- requires changes to both the API client and AppState
3. **Fix 3** (sidebar counts) -- purely UI, can be visually verified immediately

Note: Fix 1 Step 3 and Fix 2 both delete uses of `ninetyDaysAgo`. After both fixes are applied, the variable declaration at line 276 has zero remaining uses and must be deleted. If implementing sequentially, the implementer should be aware that `ninetyDaysAgo` should only be fully removed once both Fix 1 and Fix 2 are complete.

---

## Fix 4: Search filter colors

**Files:**
- `ArXivMonitor/Models/SavedSearch.swift` (lines 33-88)
- `ArXivMonitor/Views/SearchListView.swift` (lines 33-61)
- `ArXivMonitor/Views/PaperRowView.swift` (lines 1-78)
- `ArXivMonitor/Views/AddSearchSheet.swift` (lines 1-146)
- `ArXivMonitor/AppState.swift` (line 127 — `addSearch()`)

**Problem:** There is no visual way to distinguish which search(es) a paper belongs to. In the sidebar, all search rows look identical (plain text). In the paper list, there is no indication of which searches matched a given paper. The user wants each saved search to have a persistent color, visible as a stripe in the sidebar and as colored badges on paper rows.

**Solution:**

### Step 1: Define a default color palette and add `colorHex` to `SavedSearch`

In `ArXivMonitor/Models/SavedSearch.swift`, add a static palette and a `colorHex` property to `SavedSearch`.

Add a palette constant at the top of the file (after the `ClauseCombineOperator` enum, before `struct SavedSearch`):

```swift
/// Default palette for auto-assigning colors to new searches.
let searchColorPalette: [String] = [
    "#5E5CE6", // indigo
    "#30B0C7", // teal
    "#AC4FC6", // purple
    "#FF6482", // pink
    "#FF9F0A", // orange
    "#FFD60A", // yellow
    "#32D74B", // green
    "#0A84FF", // blue
]
```

Add `colorHex` as a stored property to `SavedSearch` (after `lastQueriedAt` on line 38):

```swift
var colorHex: String
```

Update the memberwise `init` (lines 40-47) to accept an optional `colorHex` with a default:

```swift
init(id: UUID = UUID(), name: String, clauses: [SearchClause],
     combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil,
     colorHex: String = searchColorPalette[0]) {
    self.id = id
    self.name = name
    self.clauses = clauses
    self.combineOperator = combineOperator
    self.lastQueriedAt = lastQueriedAt
    self.colorHex = colorHex
}
```

Update `init(from decoder:)` (lines 49-56) to decode `colorHex` with a fallback for existing data:

```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    clauses = try container.decode([SearchClause].self, forKey: .clauses)
    combineOperator = try container.decodeIfPresent(ClauseCombineOperator.self, forKey: .combineOperator) ?? .and
    lastQueriedAt = try container.decodeIfPresent(String.self, forKey: .lastQueriedAt)
    colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? searchColorPalette[0]
}
```

Add a computed `Color` helper (after `isAuthorOnly`, around line 61):

```swift
/// SwiftUI Color from the persisted hex string.
var color: Color {
    Color(hex: colorHex)
}
```

### Step 2: Add a `Color(hex:)` extension

Create a small helper extension. Add this at the bottom of `SavedSearch.swift` (or in a new `Extensions/Color+Hex.swift` file — but prefer the same file to avoid bloat):

```swift
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
```

### Step 3: Auto-assign color from palette when creating a new search

In `ArXivMonitor/AppState.swift`, modify `addSearch()` (line 127) to auto-assign the next palette color based on how many searches already exist:

```swift
func addSearch(_ search: SavedSearch) {
    var newSearch = search
    // Auto-assign palette color based on current search count
    let paletteIndex = savedSearches.count % searchColorPalette.count
    newSearch.colorHex = searchColorPalette[paletteIndex]
    savedSearches.append(newSearch)
    save()

    // Request notification permission on first search creation
    if savedSearches.count == 1 {
        NotificationService.shared.requestPermission()
    }
}
```

This cycles through the 8-color palette. Users who create more than 8 searches will see colors repeat, which is fine.

### Step 4: Show color stripe in sidebar search rows

In `ArXivMonitor/Views/SearchListView.swift`, modify the `ForEach` block (lines 33-61) to add a narrow vertical color stripe on the left side of each search row:

```swift
ForEach(appState.savedSearches) { search in
    HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2)
            .fill(search.color)
            .frame(width: 4, height: 20)
        Text(search.name)
        Spacer()
        let searchPapers = appState.papers(for: search.id)
        let total = searchPapers.count
        let unread = searchPapers.filter(\.isNew).count
        if unread > 0 {
            Text("\(unread)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.purple, in: Capsule())
        }
        Text("\(total)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
    .tag(SidebarSelection.search(search.id))
    .contextMenu {
        Button("Edit...") {
            editingSearch = search
        }
        Button("Delete", role: .destructive) {
            appState.deleteSearch(search.id)
        }
    }
}
```

Key change: Added `HStack(spacing: 6)` with a `RoundedRectangle` color stripe (4pt wide, 20pt tall) before `Text(search.name)`.

### Step 5: Show colored square badges on paper rows

In `ArXivMonitor/Views/PaperRowView.swift`, add colored badges showing which searches matched each paper. This requires passing the list of saved searches so we can look up colors.

First, add a property to `PaperRowView` (after line 4):

```swift
var savedSearches: [SavedSearch] = []
```

Then, below the category/author/revision `HStack` (after line 39, before the closing `}` of the inner VStack), add a row of colored badges:

```swift
if !savedSearches.isEmpty {
    HStack(spacing: 4) {
        ForEach(paper.matchedSearchIDs, id: \.self) { searchID in
            if let search = savedSearches.first(where: { $0.id == searchID }) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(search.color)
                    .frame(width: 8, height: 8)
                    .help(search.name)
            }
        }
    }
}
```

Each badge is an 8x8 rounded square in the search's color, with a tooltip showing the search name on hover.

Update the call site in `ArXivMonitor/Views/PaperListView.swift` (lines 39-44) to pass `savedSearches`:

```swift
PaperRowView(
    paper: paper,
    savedSearches: appState.savedSearches,
    onOpen: { appState.openPaper(paper) },
    onDismiss: { appState.dismissPaper(paper.id) }
)
```

### Step 6: Add color picker to AddSearchSheet

In `ArXivMonitor/Views/AddSearchSheet.swift`, add a state variable and color picker so the user can change the search color.

Add a state variable (after `combineOperator` on line 14):

```swift
@State private var colorHex: String = searchColorPalette[0]
```

Add a `ColorPicker` row in the form, after the name `TextField` (after line 29):

```swift
HStack {
    Text("Color")
    Spacer()
    ColorPicker("", selection: Binding(
        get: { Color(hex: colorHex) },
        set: { newColor in
            // Convert back to hex — use NSColor for extraction
            if let cgColor = NSColor(newColor).usingColorSpace(.sRGB) {
                let r = Int(cgColor.redComponent * 255)
                let g = Int(cgColor.greenComponent * 255)
                let b = Int(cgColor.blueComponent * 255)
                colorHex = String(format: "#%02X%02X%02X", r, g, b)
            }
        }
    ))
    .labelsHidden()
}
```

Update `onAppear` (lines 67-73) to load the existing color when editing:

```swift
.onAppear {
    if let search = editingSearch {
        name = search.name
        clauses = search.clauses
        combineOperator = search.combineOperator
        colorHex = search.colorHex
    }
}
```

Update `saveSearch()` (lines 131-145) to pass `colorHex`:

```swift
private func saveSearch() {
    let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !trimmedClauses.isEmpty else { return }

    if var existing = editingSearch {
        existing.name = name
        existing.clauses = trimmedClauses
        existing.combineOperator = combineOperator
        existing.colorHex = colorHex
        appState.updateSearch(existing)
    } else {
        let search = SavedSearch(name: name, clauses: trimmedClauses,
                                 combineOperator: combineOperator, colorHex: colorHex)
        appState.addSearch(search)
    }
    dismiss()
}
```

Note: When creating a new search via `addSearch()`, the `colorHex` passed here will be overridden by the palette auto-assignment in Step 3. This is intentional — the sheet's color picker starts at the default palette[0], but `addSearch()` picks the next unused palette slot. If the user explicitly changes the color picker before saving, `addSearch()` will still override it. To preserve user choice, add a check in `addSearch()`:

```swift
func addSearch(_ search: SavedSearch) {
    var newSearch = search
    // Auto-assign palette color only if the default was not changed by the user
    if newSearch.colorHex == searchColorPalette[0] {
        let paletteIndex = savedSearches.count % searchColorPalette.count
        newSearch.colorHex = searchColorPalette[paletteIndex]
    }
    savedSearches.append(newSearch)
    save()
    ...
}
```

Alternatively, a simpler approach: always set the initial `colorHex` state in `AddSearchSheet` to the next palette color, so the color picker starts at the right color and `addSearch()` doesn't need to override. Replace Step 3's `addSearch()` change with just updating the `@State` default:

```swift
// In AddSearchSheet, compute the initial color in onAppear when NOT editing:
.onAppear {
    if let search = editingSearch {
        name = search.name
        clauses = search.clauses
        combineOperator = search.combineOperator
        colorHex = search.colorHex
    } else {
        let paletteIndex = appState.savedSearches.count % searchColorPalette.count
        colorHex = searchColorPalette[paletteIndex]
    }
}
```

And keep `addSearch()` simple (don't override `colorHex`). This is the cleaner approach — **use this one**.

### Step 7: Update `loadSampleData()` for consistency

In `ArXivMonitor/AppState.swift`, update the sample data (lines 433-444) to include `colorHex`:

```swift
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
```

**Edge cases considered:**
- **Backward compatibility:** The `decodeIfPresent` fallback in `init(from decoder:)` means existing data.json files without `colorHex` will decode successfully, defaulting to the first palette color.
- **Deleted searches:** When a search is deleted, its color is no longer referenced. Paper badges use `matchedSearchIDs` to look up the search; if the search is gone, the `first(where:)` returns nil and the badge is skipped. Correct.
- **NSColor conversion:** Using `NSColor` for hex extraction is macOS-only, which is fine since this is a macOS-only app.
- **Many searches:** The palette has 8 colors and wraps around. This is standard behavior (e.g., chart libraries). No issue.

---

## Fix 5: Warning when editing search clauses

**Files:**
- `ArXivMonitor/Views/AddSearchSheet.swift` (lines 131-145 — `saveSearch()`)
- `ArXivMonitor/Models/SavedSearch.swift` (lines 73-87 — `clausesEqual(to:)`)

**Problem:** When a user edits a saved search and changes the clauses (not just the name), `updateSearch()` in `AppState` scrubs all existing papers for that search (line 146-152). This is destructive — all previously matched papers lose their association with this search. Currently this happens silently with no warning. The user wants a confirmation dialog before this destructive action.

**Solution:**

### Step 1: Add confirmation state to AddSearchSheet

In `ArXivMonitor/Views/AddSearchSheet.swift`, add a state variable for showing the confirmation alert (after the existing `@State` variables, around line 14):

```swift
@State private var showClauseChangeWarning = false
```

### Step 2: Modify `saveSearch()` to check for clause changes before saving

Replace the current `saveSearch()` method (lines 131-145) with logic that detects clause changes and shows a warning:

```swift
private func saveSearch() {
    let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !trimmedClauses.isEmpty else { return }

    if let existing = editingSearch {
        // Build the updated search to compare clauses
        var updated = existing
        updated.name = name
        updated.clauses = trimmedClauses
        updated.combineOperator = combineOperator
        updated.colorHex = colorHex  // from Fix 4

        if !existing.clausesEqual(to: updated) {
            // Clauses changed — show confirmation before proceeding
            showClauseChangeWarning = true
        } else {
            // Only name/color changed — safe to save immediately
            appState.updateSearch(updated)
            dismiss()
        }
    } else {
        let search = SavedSearch(name: name, clauses: trimmedClauses,
                                 combineOperator: combineOperator, colorHex: colorHex)
        appState.addSearch(search)
        dismiss()
    }
}
```

Note: The `clausesEqual(to:)` method (SavedSearch.swift line 73) compares both `combineOperator` and the set of clauses (ignoring order). So changing the combine operator from AND to OR will also trigger the warning, which is correct since it changes the effective search criteria.

### Step 3: Add the confirmation alert

Add an `.alert` modifier to the outermost VStack in `AddSearchSheet`'s body. Place it after the existing `.sheet(item:)` modifier, or directly on the VStack (after `.onAppear`, around line 73):

```swift
.alert("Change Search Criteria?", isPresented: $showClauseChangeWarning) {
    Button("Continue", role: .destructive) {
        confirmSave()
    }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("Changing search criteria will remove existing results for this search. Continue?")
}
```

### Step 4: Add `confirmSave()` helper for the confirmed path

Add a private method that performs the actual save after confirmation:

```swift
private func confirmSave() {
    let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    guard var existing = editingSearch else { return }
    existing.name = name
    existing.clauses = trimmedClauses
    existing.combineOperator = combineOperator
    existing.colorHex = colorHex  // from Fix 4
    appState.updateSearch(existing)
    dismiss()
}
```

**Note on `colorHex` references:** If Fix 4 is not yet implemented when Fix 5 is applied, remove the `existing.colorHex = colorHex` lines and the `colorHex:` parameter from both `saveSearch()` and `confirmSave()`. The fixes are designed to be independent but the code snippets show the final state with both applied.

**Edge cases considered:**
- **Only name changed:** If only `name` is edited (clauses and combineOperator unchanged), `clausesEqual(to:)` returns true, so no warning is shown. The save proceeds immediately. Correct.
- **Only combineOperator changed:** `clausesEqual(to:)` checks `combineOperator` first (line 74). Changing AND to OR returns false, triggering the warning. This is correct — the same clauses with a different operator produce different API queries.
- **Empty clause removal:** The `trimmedClauses` filter removes empty-value clauses. If the user had 3 clauses and blanked one out, the effective clause list changes, triggering the warning. Correct behavior.
- **New search (not editing):** The `if let existing = editingSearch` guard means new searches never see the warning. Correct.
- **User cancels the alert:** The `Cancel` button does nothing — the sheet stays open and the user can continue editing or close without saving. Correct.

---

## Fix 6: Pause/Resume search filters

**Files:**
- `ArXivMonitor/Models/SavedSearch.swift` (lines 33-88)
- `ArXivMonitor/AppState.swift` (lines 236-411 — `performFetchCycle()`)
- `ArXivMonitor/Views/SearchListView.swift` (lines 33-61)

**Problem:** There is no way to temporarily disable a saved search without deleting it. The user wants to pause individual searches so they are skipped during fetch cycles but retain their existing matched papers.

**Solution:**

### Step 1: Add `isPaused` property to `SavedSearch`

In `ArXivMonitor/Models/SavedSearch.swift`, add `isPaused` as a stored property (after `colorHex` from Fix 4, or after `lastQueriedAt` on line 38 if Fix 4 is not yet applied):

```swift
var isPaused: Bool
```

Update the memberwise `init` (lines 40-47) to include `isPaused` with a default of `false`:

```swift
init(id: UUID = UUID(), name: String, clauses: [SearchClause],
     combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil,
     colorHex: String = searchColorPalette[0], isPaused: Bool = false) {
    self.id = id
    self.name = name
    self.clauses = clauses
    self.combineOperator = combineOperator
    self.lastQueriedAt = lastQueriedAt
    self.colorHex = colorHex
    self.isPaused = isPaused
}
```

Update `init(from decoder:)` (lines 49-56) to decode `isPaused` with a fallback:

```swift
isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
```

Add this line after the `colorHex` decode (or after `lastQueriedAt` if Fix 4 is not applied).

### Step 2: Skip paused searches in `performFetchCycle()`

In `ArXivMonitor/AppState.swift`, modify the search filtering logic in `performFetchCycle()` (lines 246-256) to exclude paused searches.

Currently, `searchesToFetch` is determined by `staleOnly` logic. Add a filter for `isPaused` to both branches:

```swift
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
```

Key change: Added `guard !search.isPaused else { return false }` in the `staleOnly` branch, and `.filter { !$0.isPaused }` in the else branch. Paused searches are simply not fetched.

### Step 3: Add toggle method to AppState

In `ArXivMonitor/AppState.swift`, add a method to toggle the paused state (after `deleteSearch()` around line 161):

```swift
func togglePause(_ searchID: UUID) {
    guard let index = savedSearches.firstIndex(where: { $0.id == searchID }) else { return }
    savedSearches[index].isPaused.toggle()
    save()
}
```

### Step 4: Visual indication in sidebar

In `ArXivMonitor/Views/SearchListView.swift`, modify the search row (lines 33-61) to show paused state with dimmed text and a pause icon overlay:

```swift
ForEach(appState.savedSearches) { search in
    HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2)
            .fill(search.color)
            .frame(width: 4, height: 20)
            .opacity(search.isPaused ? 0.4 : 1.0)
        Text(search.name)
            .foregroundStyle(search.isPaused ? .secondary : .primary)
        if search.isPaused {
            Image(systemName: "pause.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        Spacer()
        let searchPapers = appState.papers(for: search.id)
        let total = searchPapers.count
        let unread = searchPapers.filter(\.isNew).count
        if unread > 0 {
            Text("\(unread)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.purple, in: Capsule())
        }
        Text("\(total)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
    .tag(SidebarSelection.search(search.id))
    .contextMenu {
        Button(search.isPaused ? "Resume" : "Pause") {
            appState.togglePause(search.id)
        }
        Button("Edit...") {
            editingSearch = search
        }
        Button("Delete", role: .destructive) {
            appState.deleteSearch(search.id)
        }
    }
}
```

Key changes:
- Color stripe opacity reduced to 0.4 when paused.
- Search name uses `.secondary` foreground style when paused (dimmed).
- A small `pause.circle` icon appears after the name when paused.
- Context menu has a new "Pause" / "Resume" button (label toggles based on current state), placed first in the menu.

### Step 5: No changes to sidebar without Fix 4

If Fix 4 is not yet applied (no color stripe), the sidebar row is simpler. Just add the dimming and pause icon to the existing `HStack`:

```swift
HStack {
    Text(search.name)
        .foregroundStyle(search.isPaused ? .secondary : .primary)
    if search.isPaused {
        Image(systemName: "pause.circle")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
    Spacer()
    // ... badges unchanged
}
```

The Step 4 snippet above shows the final state with both Fix 4 and Fix 6 applied.

**Edge cases considered:**
- **Existing papers kept:** Pausing only affects `performFetchCycle()` — no papers are removed. The user can still view papers for a paused search by clicking it in the sidebar. Correct.
- **Unpausing and stale data:** When a search is unpaused, its `lastQueriedAt` is still set from the last successful fetch. The next `staleOnly` fetch will include it if enough time has passed since it was last queried. A manual "Refresh now" (`runFetchCycle()`) always includes it (since that uses `staleOnly: false`). No special handling needed.
- **Backward compatibility:** `decodeIfPresent` with `?? false` means existing data.json files load correctly — all existing searches default to unpaused.
- **Paused search edited:** If a user edits a paused search's clauses, the existing behavior (scrub + reset `lastQueriedAt`) applies. The search remains paused. On unpause, it will re-fetch on next cycle. Correct.
- **All searches paused:** If every search is paused, `searchesToFetch` is empty, and `performFetchCycle()` returns early at line 258-262. The "Checking arXiv..." progress message flashes briefly then clears. This is acceptable.
- **Badge counts for paused searches:** Paused searches still show their total and unread counts in the sidebar. This is correct — the data is still there, just not being refreshed.

---

## Implementation order (updated)

The recommended implementation order for all six fixes is:

1. **Fix 2** (remove pruning) — simplest, just deleting code
2. **Fix 1** (date-dependent fetch) — API client + AppState changes
3. **Fix 3** (sidebar counts) — purely UI, already implemented in current code
4. **Fix 4** (search colors) — model + UI, moderate scope
5. **Fix 6** (pause/resume) — model + AppState + UI, builds on Fix 4's sidebar layout
6. **Fix 5** (edit warning) — AddSearchSheet only, integrates with Fix 4's colorHex

Fix 4 should come before Fix 6 because Fix 6's sidebar code (Step 4) builds on the color stripe added by Fix 4. Fix 5 should come last because its code snippets reference `colorHex` from Fix 4.

If implementing Fix 5 or Fix 6 independently of Fix 4, remove the `colorHex` references from the code snippets — the fix descriptions note this explicitly.

---

## Fix 7: Per-search configurable "fetch from" date and pagination

**Files:**
- `ArXivMonitor/Models/SavedSearch.swift` (lines 46-76)
- `ArXivMonitor/Services/ArXivAPIClient.swift` (lines 1-115)
- `ArXivMonitor/Services/XMLAtomParser.swift` (lines 1-145)
- `ArXivMonitor/AppState.swift` (lines 242-418)
- `ArXivMonitor/Views/AddSearchSheet.swift` (lines 1-197)

**Problem:** Two related limitations:

1. **Hardcoded 90-day window:** `ArXivAPIClient.buildQueryURL(for:)` hardcodes a 90-day `submittedDate` window for non-author searches (lines 38-47). Users cannot control how far back to search. An author tracking a specific topic over 6 months, or wanting to narrow to the last 2 weeks, has no option. The date filter should be user-configurable per search and available for ALL search types (keyword, category, and author alike). The only difference is the default when the user doesn't set one: keyword/category searches default to 90 days, author-only searches default to all time.

2. **No pagination — results capped at 100:** `ArXivAPIClient` sets `max_results=100` (line 5) and makes a single request (lines 59-77). If a query matches more than 100 papers, only the 100 most recently updated are returned. The truncation warning at line 73 fires but nothing is done about it. This means:
   - An author with >100 papers will have an incomplete bibliography.
   - A broad keyword search over 90 days could easily exceed 100 results and silently miss papers.
   - An author search with an explicit date restriction could still exceed 100 results.

The arXiv Export API supports pagination via the `start` parameter (`start=0&max_results=100` returns results 0–99, `start=100&max_results=100` returns 100–199, etc.) and returns `<opensearch:totalResults>` in the Atom XML indicating how many results match the query.

**Solution:**

### Step 1: Add `fetchFromDate` property to `SavedSearch`

In `ArXivMonitor/Models/SavedSearch.swift`, add an optional `fetchFromDate` stored property to `SavedSearch`. This stores the user-chosen "fetch articles from" date as a `yyyy-MM-dd` string, or nil to mean "use default behavior" (90 days for keyword searches, all-time for author-only searches).

Add the property after `isPaused` (line 54):

```swift
var fetchFromDate: String?
```

Update the memberwise `init` to accept the new parameter with a default of `nil`:

```swift
init(id: UUID = UUID(), name: String, clauses: [SearchClause],
     combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil,
     colorHex: String = searchColorPalette[0], isPaused: Bool = false,
     fetchFromDate: String? = nil) {
    self.id = id
    self.name = name
    self.clauses = clauses
    self.combineOperator = combineOperator
    self.lastQueriedAt = lastQueriedAt
    self.colorHex = colorHex
    self.isPaused = isPaused
    self.fetchFromDate = fetchFromDate
}
```

Update `init(from decoder:)` to decode with a nil fallback for backward compatibility. Add this line after the `isPaused` decode:

```swift
fetchFromDate = try container.decodeIfPresent(String.self, forKey: .fetchFromDate)
```

Add a computed property that resolves the effective start date for the API query — this centralizes the default logic. The date filter applies uniformly to ALL search types (keyword, category, author, and mixed). The search type only affects the *default* when no explicit date is set:

```swift
/// The effective "from" date for the API query.
/// Applies to ALL search types — the submittedDate filter is type-agnostic.
/// - If `fetchFromDate` is explicitly set, use that (regardless of search type).
/// - If nil and the search is author-only, return nil (all time — the default for authors).
/// - If nil and the search has keywords/categories, return 90 days ago (the default for keywords).
var effectiveFetchFromDate: Date? {
    if let dateStr = fetchFromDate {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: dateStr)
    }
    if isAuthorOnly {
        return nil  // default for author-only: all time
    }
    // Default for keyword/category/mixed: 90 days ago
    return Calendar.current.date(byAdding: .day, value: -90, to: Date())
}
```

Place this after the `isAuthorOnly` computed property.

**Uniform applicability:** The `fetchFromDate` parameter and the DatePicker UI (Step 6) are available for ALL search types. An author search can have a "fetch from" date set to e.g. 2020-01-01, which will add a `submittedDate` filter to the API query. A keyword search can have its date cleared (set to nil) to fetch all time instead of the default 90 days — though this is less common and may produce many results.

**Backward compatibility:** `decodeIfPresent` with no default means existing data.json files decode `fetchFromDate` as nil. The `effectiveFetchFromDate` computed property then applies the same defaults as the current behavior (90 days for keyword, all-time for author). Zero behavior change for existing users.

### Step 2: Replace hardcoded 90-day window with per-search date in `ArXivAPIClient`

In `ArXivMonitor/Services/ArXivAPIClient.swift`, modify `buildQueryURL(for:)` to use the search's `effectiveFetchFromDate` instead of the hardcoded 90-day calculation. Also add a `start` parameter for pagination support.

Change the method signature to accept a `start` offset:

```swift
/// Build the arXiv API query URL for a saved search, with pagination offset.
static func buildQueryURL(for search: SavedSearch, start: Int = 0) -> URL? {
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

    // Apply date restriction using the search's effective "from" date
    if let fromDate = search.effectiveFetchFromDate {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmm"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let startDate = dateFormatter.string(from: fromDate)
        let endDate = dateFormatter.string(from: Date())
        searchQuery = "(\(searchQuery)) AND submittedDate:[\(startDate) TO \(endDate)]"
    }

    // Build URL manually to preserve literal brackets in submittedDate:[... TO ...]
    guard let encodedQuery = searchQuery.addingPercentEncoding(
        withAllowedCharacters: .arXivQueryAllowed
    ) else { return nil }
    let urlString = "\(baseURL)?search_query=\(encodedQuery)&sortBy=lastUpdatedDate&sortOrder=descending&start=\(start)&max_results=\(maxResults)"
    return URL(string: urlString)
}
```

Key changes:
- Added `start: Int = 0` parameter — callers that don't paginate still work unchanged.
- Replaced the `if !search.isAuthorOnly` block with `if let fromDate = search.effectiveFetchFromDate`. This uses the search's own date logic: explicit user date > default 90 days (keyword) > nil/all-time (author-only).
- Added `&start=\(start)` to the URL string, placed before `&max_results`.

### Step 3: Add `totalResults` parsing to `XMLAtomParser`

In `ArXivMonitor/Services/XMLAtomParser.swift`, the parser currently only extracts `<entry>` elements. It needs to also parse `<opensearch:totalResults>` from the feed-level XML, which tells us the total number of results matching the query.

The arXiv API response contains (outside of any `<entry>`):
```xml
<opensearch:totalResults xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">542</opensearch:totalResults>
```

Since the parser uses `shouldProcessNamespaces = true`, the namespace prefix is stripped and the element name will be just `totalResults`.

**Add a `totalResults` property to the parser class** (after line 8, alongside the other state vars):

```swift
private var totalResults: Int = 0
```

**Change the `parse` return type** to return both the papers and the total count. Define a result struct at the top of the file (before the class):

```swift
/// Result from parsing an arXiv Atom feed, including pagination metadata.
struct ArXivFeedResult {
    let papers: [MatchedPaper]
    let totalResults: Int
}
```

**Update the static `parse` method** to return `ArXivFeedResult`:

```swift
static func parse(data: Data) throws -> ArXivFeedResult {
    let parser = XMLParser(data: data)
    let delegate = XMLAtomParser()
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    let success = parser.parse()
    if !success, let error = delegate.parseError {
        print("[ArXivMonitor] XML parse error: \(error)")
        throw ArXivError.parseError
    }
    return ArXivFeedResult(papers: delegate.papers, totalResults: delegate.totalResults)
}
```

**Parse the `totalResults` element** in `didEndElement`. Add a case in the `didEndElement` method (at the end, before the closing brace), handling it when we are NOT inside an entry (it's a feed-level element):

```swift
} else if elementName == "totalResults" && !insideEntry {
    totalResults = Int(text) ?? 0
}
```

This goes at the end of the `if/else if` chain in `parser(_:didEndElement:...)`, after the `} else if elementName == "updated" && insideEntry {` block (line 132).

### Step 4: Add paginated fetch method to `ArXivAPIClient`

Replace the current `fetch(search:)` method (lines 58-78) with a paginated version. The method fetches pages of 100 results each until all results are retrieved, with a safety cap.

```swift
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
```

Key design decisions:
- **Safety cap of 1000:** Prevents runaway fetches for extremely broad queries. Logged when hit so the user can narrow their search or increase the cap later.
- **3-second delay between pages:** Matches the existing inter-search delay (AppState line 286) and respects arXiv API rate limits.
- **`progressHandler` callback:** Allows the caller (AppState) to update the UI with page-level progress without coupling the API client to UI state.
- **Early exit on short page:** If a page returns fewer than `maxResults` papers, we know there are no more results even if `totalResults` says otherwise (handles edge cases where totalResults is stale or approximate).
- **Backward-compatible signature:** The `progressHandler` parameter defaults to nil, so existing callers don't need updating (though we will update AppState below).

### Step 5: Update `AppState.performFetchCycle()` for paginated fetches

In `ArXivMonitor/AppState.swift`, the fetch loop (lines 283-363) currently calls `ArXivAPIClient.fetch(search:)` for each search and gets back a flat array. With pagination, the same API is used but we now pass a `progressHandler` to update `fetchProgress` with page-level detail.

Replace the fetch call at line 292 and the surrounding progress update:

Change the block inside the `for (idx, search) in searchesToFetch.enumerated()` loop. The current code (lines 283-363) has:

```swift
fetchProgress = "Checking \(search.name)... (\(idx + 1)/\(searchesToFetch.count))"

do {
    let papers = try await ArXivAPIClient.fetch(search: search)
```

Replace with:

```swift
fetchProgress = "Checking \(search.name)... (\(idx + 1)/\(searchesToFetch.count))"

do {
    let papers = try await ArXivAPIClient.fetch(search: search) { page, totalPages in
        if totalPages > 1 {
            fetchProgress = "Checking \(search.name)... page \(page)/\(totalPages) (\(idx + 1)/\(searchesToFetch.count))"
        }
    }
```

This shows pagination progress only when there are multiple pages. For single-page results (the common case), the progress message remains as before: "Checking Mirror Symmetry... (1/3)". For multi-page results, it becomes "Checking Hinton... page 2/4 (2/3)".

**Important:** The 3-second inter-search delay at line 286 (`try? await Task.sleep(nanoseconds: 3_000_000_000)`) should be kept as-is. The paginated `fetch()` method handles its own inter-page delays internally. The inter-search delay at line 286 ensures a 3-second gap between the last page of search N and the first page of search N+1. This is correct — no double-delay issue because the `fetch()` method only delays *between* its own pages (skipping the delay before the first page via the `if start > 0` guard).

**No other changes needed in `performFetchCycle()`** — the method already processes the returned `[MatchedPaper]` array identically regardless of whether it came from one page or many. The deduplication logic (existing vs. pending vs. new) works on the full array.

### Step 6: Add DatePicker to `AddSearchSheet`

In `ArXivMonitor/Views/AddSearchSheet.swift`, add UI for the user to configure the "fetch from" date.

**Add state variables** (after the existing `@State` vars, around line 16):

```swift
@State private var useFetchFromDate: Bool = false
@State private var fetchFromDate: Date = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
```

The `useFetchFromDate` toggle controls whether the date picker is active. When off, `fetchFromDate` is nil (use defaults). When on, the user picks a specific date.

**Add the date picker UI** in the body, after the "Color" `HStack` and before the "CLAUSES" header. Insert this block:

```swift
VStack(alignment: .leading, spacing: 4) {
    Toggle("Fetch articles from specific date", isOn: $useFetchFromDate)
        .font(.system(size: 12))

    if useFetchFromDate {
        DatePicker(
            "From:",
            selection: $fetchFromDate,
            in: ...Date(),
            displayedComponents: .date
        )
        .datePickerStyle(.field)
        .labelsHidden()
        .frame(width: 140)

        Text("Only articles submitted on or after this date will be fetched.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    } else {
        Text(isCurrentSearchAuthorOnly
            ? "Default: all time (author search)"
            : "Default: last 90 days")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
}
```

**Add a computed property** to `AddSearchSheet` to check if the current clauses are author-only (used for the default label above):

```swift
private var isCurrentSearchAuthorOnly: Bool {
    let nonEmpty = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    return !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.field == .author }
}
```

**Update `onAppear`** to load the existing `fetchFromDate` when editing:

```swift
.onAppear {
    if let search = editingSearch {
        name = search.name
        clauses = search.clauses
        combineOperator = search.combineOperator
        colorHex = search.colorHex
        if let dateStr = search.fetchFromDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: dateStr) {
                fetchFromDate = date
                useFetchFromDate = true
            }
        }
    } else {
        let paletteIndex = appState.savedSearches.count % searchColorPalette.count
        colorHex = searchColorPalette[paletteIndex]
    }
}
```

**Update `saveSearch()`** to pass `fetchFromDate`:

In the editing branch, after setting `updated.colorHex`:

```swift
if useFetchFromDate {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    updated.fetchFromDate = formatter.string(from: fetchFromDate)
} else {
    updated.fetchFromDate = nil
}
```

In the new-search branch, construct the SavedSearch with the date:

```swift
let fetchDateStr: String? = useFetchFromDate ? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: fetchFromDate)
}() : nil

let search = SavedSearch(name: name, clauses: trimmedClauses,
                         combineOperator: combineOperator, colorHex: colorHex,
                         fetchFromDate: fetchDateStr)
appState.addSearch(search)
```

**Update `confirmSave()`** similarly — add the same `fetchFromDate` logic after setting `existing.colorHex`:

```swift
if useFetchFromDate {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    existing.fetchFromDate = formatter.string(from: fetchFromDate)
} else {
    existing.fetchFromDate = nil
}
```

**Note on clause-change detection:** Changing `fetchFromDate` alone should NOT trigger the "Change Search Criteria?" warning from Fix 5. The `clausesEqual(to:)` method compares clauses and combineOperator — it does not compare `fetchFromDate`. This is correct because changing the date window doesn't invalidate existing matched papers; it just changes what future fetches will find. The existing papers remain valid matches.

### Step 7: Handle `fetchFromDate` changes in `updateSearch()`

In `ArXivMonitor/AppState.swift`, the `updateSearch()` method (lines 137-155) currently only resets `lastQueriedAt` when clauses change. When `fetchFromDate` changes (without clause changes), we should also reset `lastQueriedAt` to trigger a re-fetch on the next cycle with the new date window, but we should NOT scrub existing papers (they're still valid matches).

Add a check after the `clausesChanged` block:

```swift
func updateSearch(_ updated: SavedSearch) {
    guard let index = savedSearches.firstIndex(where: { $0.id == updated.id }) else { return }
    let old = savedSearches[index]

    let clausesChanged = !old.clausesEqual(to: updated)

    savedSearches[index] = updated

    if clausesChanged {
        savedSearches[index].lastQueriedAt = nil
        scrubSearchID(updated.id)
    } else if old.fetchFromDate != updated.fetchFromDate {
        // Date window changed but clauses are the same — re-fetch but keep existing papers
        savedSearches[index].lastQueriedAt = nil
    }

    save()
}
```

**Edge cases considered:**

- **Backward compatibility:** `fetchFromDate` decodes as nil from existing data.json. The `effectiveFetchFromDate` computed property then produces the same behavior as the current hardcoded logic. Zero regression.
- **Author-only with explicit date:** If a user creates an author search and sets fetchFromDate to "2020-01-01", the `effectiveFetchFromDate` returns that date (the explicit value takes priority over the "author = all time" default). The submittedDate filter will be applied to the API query. This is correct — the user explicitly chose a date.
- **Safety cap logging:** When the 1000-result cap is hit, a console log message is printed. This lets the developer/user know results were truncated. A future enhancement could surface this in the UI.
- **Empty pages:** If the API returns an empty page (0 papers) before reaching totalResults, the `result.papers.count < maxResults` check catches it and breaks the loop. This handles cases where totalResults is an overestimate.
- **API rate limiting:** The arXiv API documentation recommends no more than 1 request per 3 seconds. The paginated fetch respects this with `Task.sleep(nanoseconds: 3_000_000_000)` between pages. Combined with the inter-search delay in AppState, the app never exceeds this limit.
- **Cancellation:** If the user quits the app mid-pagination, `Task.sleep` and `session.data(from:)` will throw `CancellationError`, which propagates up to `performFetchCycle()` and is caught by the existing `catch` block, marking that search as failed. On next launch, it will retry. No partial-state corruption because papers are only committed atomically after ALL searches complete.
- **totalResults = 0:** If the API returns `<opensearch:totalResults>0</opensearch:totalResults>`, the first page will also have 0 papers, the `result.papers.count < maxResults` check fires, and the loop exits immediately. Correct.
- **Date picker range:** The `in: ...Date()` constraint prevents selecting future dates. The `displayedComponents: .date` hides the time component, keeping the UI simple.
- **Changing fetchFromDate without changing clauses:** Does not trigger the Fix 5 warning dialog. Only resets `lastQueriedAt` to force a re-fetch. Existing papers are preserved. Correct.

---

## Implementation order (updated)

The recommended implementation order for all seven fixes is:

1. **Fix 2** (remove pruning) — simplest, just deleting code
2. **Fix 1** (date-dependent fetch) — API client + AppState changes
3. **Fix 3** (sidebar counts) — purely UI
4. **Fix 4** (search colors) — model + UI, moderate scope
5. **Fix 6** (pause/resume) — model + AppState + UI, builds on Fix 4
6. **Fix 5** (edit warning) — AddSearchSheet only
7. **Fix 7** (per-search date + pagination) — builds on Fix 1's date logic, touches API client, parser, model, AppState, and UI

Fix 7 should come last because:
- It replaces the date logic introduced in Fix 1 with a more flexible per-search version. Implementing Fix 1 first establishes the `isAuthorOnly` / `submittedDate` pattern; Fix 7 then generalizes it.
- It modifies `XMLAtomParser.parse()` return type from `[MatchedPaper]` to `ArXivFeedResult`, which is a breaking change to the parser's interface. All callers must be updated simultaneously.
- The `AddSearchSheet` changes in Fix 7 assume Fix 4 (colorHex) and Fix 5 (clause change warning) are already in place. If implementing Fix 7 without those, omit the `colorHex` references and the `confirmSave()` date logic.
