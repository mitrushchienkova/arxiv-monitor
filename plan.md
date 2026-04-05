# arXiv Monitor — Implementation Plan

## Overview

A native macOS menu bar app that monitors arXiv.org for new papers matching user-configurable saved searches. Each saved search is an independent query (e.g. "cs.LG papers by Hinton", "flow matching in title"). Sends native macOS notifications with sound when new papers arrive. Zero external dependencies — Apple frameworks only.

## Architecture

```
ArXivMonitor (Xcode project, single macOS target)
├── Models/
│   ├── SavedSearch.swift        — Saved search data model (clauses, fetch window)
│   └── MatchedPaper.swift       — Paper metadata
│
├── ArXivMonitorApp.swift        — App entry point, MenuBarExtra
├── AppState.swift               — Observable app state (papers, searches, timestamps)
├── Services/
│   ├── ArXivAPIClient.swift     — Fetch + parse arXiv Export API (Atom XML)
│   ├── XMLAtomParser.swift      — Parse Atom 1.0 XML into MatchedPaper structs
│   ├── NotificationService.swift — Schedule native macOS notifications
│   └── PollScheduler.swift      — Daily check scheduling (Timer-based)
├── Views/
│   ├── MenuBarPopover.swift     — Main popover (paper list, badge)
│   ├── PaperRowView.swift       — Single paper row in the list
│   ├── MainWindowView.swift     — Full window: NavigationSplitView with search sidebar + paper list
│   ├── SearchListView.swift     — Saved search list (sidebar content)
│   ├── PaperListView.swift      — Paper list for selected search or all papers (detail content)
│   ├── AddSearchSheet.swift     — Add/edit saved search modal
│   └── SettingsView.swift       — App preferences
└── Resources/
    └── paper-flip.aiff          — Custom notification sound
```

## Data Model

### Storage (device-local)

Scalar settings live in UserDefaults. Paper history and saved searches are stored in a
JSON file (`data.json`) inside the app's sandboxed Application Support directory
(obtained via `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`).
No hardcoded `~/Library` paths — the sandbox container handles this automatically.
No iCloud sync in v1.

`AppState` persists to the JSON file via atomic file replacement (`Data.write(to:options:.atomic)`).
Writes happen at defined commit points — not on every property mutation:
- After a fetch cycle commits (papers + search timestamps written together)
- After user actions that change state (dismiss, delete search, edit search, etc.)

This ensures that a crash mid-fetch cannot leave `lastQueriedAt` advanced without the
corresponding paper data. On app launch, load from the file; if missing or corrupt, start fresh.

### Persisted Data

```swift
// UserDefaults (scalar settings only)
"soundName"        : String     // "paper-flip" | "default" | "none"
"badgeStyle"       : String     // "count" | "dot" | "none"
"launchAtLogin"    : Bool

// data.json (Application Support directory)
{
  "savedSearches": [SavedSearch],         // JSON-encoded
  "matchedPapers": { String: MatchedPaper }, // keyed by arXiv ID for O(1) lookups
  "lastCycleAt": String?,                 // ISO8601 — when the app last started a fetch cycle (schedule, wake, or manual)
  "lastCycleFailedSearchIDs": [UUID]      // searches that failed in the most recent cycle (drives the status line warning)
}
```

### Models

```swift
// Each SavedSearch is an independent query. Its clauses are ANDed together.
// Example: "ML papers by Hinton" = [category:cs.LG] AND [author:Hinton]
// Example: "Flow matching"       = [keyword:"flow matching" in title+abstract]
struct SavedSearch: Codable, Identifiable {
    let id: UUID
    var name: String            // user label, e.g. "ML papers by Hinton"
    var clauses: [SearchClause] // one or more, ANDed together
    var lastQueriedAt: String?  // ISO8601 — last fetch for this search; nil on new/edited search
}

struct SearchClause: Codable, Identifiable {
    let id: UUID
    var field: SearchField      // .keyword | .category | .author
    var value: String           // e.g. "flow matching", "cs.LG", "Hinton"
    var scope: MatchScope?      // keyword only; nil for category/author
}

enum SearchField: String, Codable {
    case keyword, category, author
}

enum MatchScope: String, Codable {
    case title, abstract, titleAndAbstract
}

struct MatchedPaper: Codable, Identifiable {
    let id: String              // arXiv ID, e.g. "2404.12345"
    var title: String
    var authors: String         // "Smith, Chen, Wang"
    var primaryCategory: String // "cs.LG"
    var categories: [String]    // ["cs.LG", "cs.AI", "stat.ML"]
    var publishedAt: String     // ISO8601 original submission date from arXiv
    var updatedAt: String       // ISO8601 last update from arXiv (== publishedAt for v1, newer for revisions)
    var link: String            // URL to arXiv page
    var matchedSearchIDs: [UUID] // which saved searches have matched this paper (historical, append-only during fetches; only scrubbed on search edit/delete)
    let foundAt: String         // ISO8601 when first added to history — immutable, never reset on revisions; drives 90-day pruning
    var isNew: Bool             // true until the user sees or dismisses it; drives badge + notification
}
// Revision status is derived: updatedAt > publishedAt means the paper has been revised.
```

### Paper States

`matchedPapers` is a history log used for dedup and display. The only state a paper carries is `isNew`:

| State | Meaning | How determined |
|---|---|---|
| **New** | Paper not yet seen by the user | `isNew == true` |
| **History** | Paper has been viewed or dismissed | `isNew == false` |

Whether a paper is a revision is derived from the arXiv data: `updatedAt > publishedAt`.
The UI can display this with a generic "Revised" label without any extra flags.

### Pruning

On each fetch cycle, remove entries from `matchedPapers` where `foundAt` is older than 90 days. Re-discovery of pruned papers is prevented by a client-side check: new papers with `publishedAt` older than 90 days are skipped (unless `updatedAt > publishedAt`, meaning a recent revision of an old paper).

## arXiv API Integration

### Endpoint

```
https://export.arxiv.org/api/query?search_query=...&sortBy=lastUpdatedDate&sortOrder=descending&max_results=100

# sortBy=lastUpdatedDate ensures both new submissions and revisions appear at the top.
# No date filter in the query — the arXiv API only supports submittedDate as a query
# field (not lastUpdatedDate), which would miss revisions. Instead, we fetch the 100
# most recently updated results and handle filtering client-side.
# 100 results covers typical daily output for focused filters.
# For broad filters or catch-up after missed days, the API supports paging
# via start= parameter (up to 2000 per page). V1 does not page — this is
# a known limitation. If results are truncated, log a warning.
```

### Query Building

Each SavedSearch produces its own independent API query. Clauses within
a search are ANDed together. No date filter in the query — results are sorted by
`lastUpdatedDate` descending, and date-based filtering happens client-side
(see Fetch Flow).

```
// SavedSearch "ML papers by Hinton":
//   clauses: [category:cs.LG, author:Hinton]
//   Query: cat:cs.LG AND au:Hinton

// SavedSearch "Flow matching papers":
//   clauses: [keyword:"flow matching" (scope: titleAndAbstract)]
//   Query: (ti:"flow matching" OR abs:"flow matching")

// SavedSearch "Diffusion in ML":
//   clauses: [keyword:"diffusion" (scope: title), category:cs.LG]
//   Query: ti:diffusion AND cat:cs.LG
```

Field prefixes:
- `ti:` — title only
- `abs:` — abstract only
- `au:` — author
- `cat:` — category

Note: arXiv's `all:` prefix searches ALL metadata fields (title, abstract,
author, category, comments, etc.), not just title + abstract. For the
"Title + Abstract" match scope, use `(ti:... OR abs:...)` instead.

### Rate Limits

- 1 request per 3 seconds
- Max 2000 results per call
- No API key needed
- Set `URLSessionConfiguration.timeoutIntervalForRequest` to 15 seconds to avoid
  hanging on a slow/unresponsive arXiv server (default 60s is too long per request
  when multiple searches run sequentially)

### Important: arXiv Update Schedule

- Papers announced once daily: Sun-Thu at ~midnight UTC (00:00)
- No announcements on Saturday
- Sunday's feed covers Friday + Saturday submissions
- The API may lag 1-2 hours behind the announcement
- **The app checks once daily, automatically, at 04:00 UTC** (not user-configurable; 4h buffer for API lag)
- Hourly polling is wasteful — only one check per day yields new results

### Fetch Flow

The fetch cycle processes all searches, accumulates changes in a temporary map, then
commits the results. Each search tracks its own `lastQueriedAt` independently — there
is no global `lastFetchedAt`. The wake/launch catch-up check derives staleness from
per-search timestamps (see Scheduling below).

**Concurrency guard:** Only one fetch cycle may run at a time. Guard with an `isFetching`
flag (or use a serial `Task`). If a wake handler, daily timer, or manual refresh fires
while a cycle is already running, skip the new request (the in-flight cycle will cover it).

```
// pendingNew: [String: MatchedPaper]      — papers to add (keyed by arXiv ID)
// pendingRevisions: [String: MatchedPaper] — papers to update (keyed by arXiv ID)
// pendingSearchIDs: [String: Set<UUID>]   — search IDs to add per paper
// failedSearchIDs: Set<UUID>              — searches that failed this cycle
// baselineSearchIDs: Set<UUID>            — searches with lastQueriedAt == nil (first run)
```

Before the cycle begins, record which searches have `lastQueriedAt == nil` into
`baselineSearchIDs`. These are first-run or recently-edited searches.

For each SavedSearch (with 3-second delay between calls):
1. Build query URL from the search's clauses
2. Fetch results via URLSession. On failure, add to `failedSearchIDs`, log warning, continue.
3. For each returned paper:
   - **Not in history and not in pendingNew**:
     Skip if `publishedAt` > 90 days old and `updated == published` (stale, not revised).
     Otherwise add to `pendingNew` with `foundAt = now`,
     `matchedSearchIDs = [thisSearch.id]`, `isNew` = **false** if this search is
     in `baselineSearchIDs`, **true** otherwise.
   - **Already in pendingNew**: add this search's ID to its `matchedSearchIDs`.
     Promote `isNew` to true if this search is not a baseline search (a paper found
     by both a baseline and a regular search should be marked new).
   - **In history, newer version** (API's `updated > stored updatedAt`):
     Add to `pendingRevisions` with updated metadata, `isNew = true`,
     `matchedSearchIDs = storedPaper.matchedSearchIDs + [thisSearch.id]`.
     Keep the original `foundAt` (immutable).
     If already in `pendingRevisions`, add this search's ID to its `matchedSearchIDs`.
   - **In history, no change**: record this search's ID in `pendingSearchIDs[paperID]`.
4. Record `search.id → now` in a temporary `successfulTimestamps: [UUID: String]`
   map (only for searches not in `failedSearchIDs`). Do **not** mutate `lastQueriedAt`
   on the live model yet.

Record `lastCycleAt = now` (ISO8601) at the start of the cycle, before any API calls.

After all searches complete, commit atomically in one pass:
- Insert all `pendingNew` papers into `matchedPapers`
- Apply all `pendingRevisions` (update metadata, set `isNew = true`)
- Merge all `pendingSearchIDs` into existing papers' `matchedSearchIDs`
- Apply `successfulTimestamps` to each search's `lastQueriedAt`
- Set `lastCycleAt` to the value recorded at cycle start
- Set `lastCycleFailedSearchIDs` to `Array(failedSearchIDs)` (empty array if all succeeded)
- Write data.json atomically (single `Data.write(to:options:.atomic)` call)

If the app crashes at any point before this write, nothing is persisted — the next
launch will see stale `lastQueriedAt` values and re-fetch, which is safe because
dedup prevents duplicates.

**Failure handling:** Only successful searches get their `lastQueriedAt` advanced
(via `successfulTimestamps`). Failed searches keep their old `lastQueriedAt`, so the
wake/launch catch-up logic will detect them as stale and retry only those searches
on the next cycle. Successful searches within a partially-failed cycle still commit
their results (no data is thrown away). This avoids the retry storm where one
persistently-failing search forces all searches to re-fetch on every wake.

**First run behavior:** A newly created search has `lastQueriedAt = nil`. Its first
fetch adds all results with `isNew = false` — this establishes a baseline so the user
is not flooded with notifications for 100 pre-existing papers. Only papers discovered
on subsequent fetches will be marked `isNew = true` and trigger notifications.

**On search clause edit:** Only triggers when clauses change (not on name-only edits).
Clause change is detected by comparing the sorted (by `id`) arrays of `SearchClause`
using `Equatable` conformance (field + value + scope). Reordering clauses does not count
as a change since they are ANDed.
Scrub the edited search's UUID from `matchedSearchIDs` on all papers. Papers whose
`matchedSearchIDs` becomes empty are removed. Reset `lastQueriedAt = nil` so the next
fetch re-populates with the new clauses. Same baseline behavior as first run: re-fetched
papers are added with `isNew = false`.

**On search delete:** Scrub the deleted search's UUID from `matchedSearchIDs` on all
papers. Papers whose `matchedSearchIDs` becomes empty are removed.

**Manual refresh:** Runs the same fetch flow for all searches. Papers already in history
are deduped; only genuinely new papers (or revisions) appear as new.

**On open paper (`openPaper`):** Set `isNew = false` on that paper.

**On dismiss (single paper):** Set `isNew = false` on that paper.

**On dismiss all:** Set `isNew = false` on all papers with `isNew == true`.

### XML Parsing

arXiv returns Atom 1.0 XML. Use Swift's built-in `XMLParser` (delegate-based) or `XMLDocument` (tree-based, macOS only).
`XMLParser` requires `shouldProcessNamespaces = true` to correctly resolve the `arxiv:`
namespace prefix on `<arxiv:primary_category>`.

Key Atom elements to extract per entry:
```xml
<entry>
  <id>http://arxiv.org/abs/2404.12345v1</id>
  <title>Paper Title Here</title>
  <published>2024-04-03T20:00:00Z</published>
  <updated>2024-04-03T20:00:00Z</updated>
  <author><name>Author Name</name></author>
  <arxiv:primary_category term="cs.LG"/>
  <category term="cs.LG"/>
  <category term="cs.AI"/>
  <category term="stat.ML"/>
  <link href="http://arxiv.org/abs/2404.12345v1"/>
</entry>
```

Extract arXiv ID from the `<id>` URL by taking the last path component (strip version suffix).
Build the `link` as `https://arxiv.org/abs/{id}` (versionless) so it always resolves to the latest version.
Extract `primaryCategory` from `<arxiv:primary_category>` and all `categories` from `<category>` elements.

## UI Specification

### App Entry Point

```swift
@main
struct ArXivMonitorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(appState: appState)
        } label: {
            Label("arXiv Monitor", systemImage: "doc.text.magnifyingglass")
            // Badge overlay via appState.unreadCount
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }

        Window("arXiv Monitor", id: "main-window") {
            MainWindowView(appState: appState)
        }
    }
}
```

### Menu Bar Popover (primary interaction)

```
┌─────────────────────────────────────┐
│  arXiv Monitor          [⚙] [↺]     │
│  Last checked: 11:05 PM (all OK)    │
├─────────────────────────────────────┤
│  3 NEW PAPERS                       │
│  ──────────────────────────────     │
│  [purple dot] Flow matching converg…│
│       cs.LG · Smith et al.     [× ] │
│                                     │
│  [purple dot] Diffusion models for… │
│       cs.AI · Chen, Wang       [× ] │
│                                     │
│  [purple dot] Attention mechanisms… │
│       cs.CL · Jones et al.    [× ]  │
│                                     │
├─────────────────────────────────────┤
│  [History] [Searches] [Dismiss All] [Quit] │
└─────────────────────────────────────┘
```

- **Opening a paper:** Clicking the paper title calls `openPaper(_:)`: opens the arXiv URL in the default browser and sets `isNew = false` on that paper. No separate button — the title is the only click target.
- Dot = new (`isNew == true`). Papers where `updatedAt > publishedAt` show a "Revised" label
- `isNew` is only cleared by explicit user action: opening a paper or dismissing it. Opening/closing the popover does **not** clear any papers.
- "Dismiss" ([×]) sets `isNew = false` on a single paper without opening it
- "Dismiss All" sets `isNew = false` on all papers with `isNew == true`
- "History" opens the full window (MainWindowView) with "All Papers" selected
- "Searches" opens the full window (MainWindowView) with search sidebar focused
- [↺] = manual refresh (fetch now)
- [⚙] = opens Settings
- "Quit" terminates the app (`NSApplication.shared.terminate(nil)`), removing it from the menu bar
- **Status line:** "Last checked" shows `lastCycleAt` — an app-level timestamp recorded at the start of each fetch cycle (whether triggered by schedule, wake, or manual refresh). This answers "when did the app last try to check?" regardless of per-search success/failure. If any searches failed in the most recent cycle, append a warning with the search names: e.g. "Last checked: 11:05 PM · Mirror Symmetry, Gromov-Witten failed — [Retry]".
- **Empty states:**
  - No saved searches: "Add a search to start monitoring arXiv" with [Add Search] button
  - Searches exist, no papers yet: "No papers found yet. Next check at HH:MM."
  - Searches exist, fetch in progress: "Checking arXiv…" with progress indicator

### Main Window (full window)

`MainWindowView` uses `NavigationSplitView` with a search sidebar and a paper list detail pane.

```
┌────────────────────┬─────────────────────────────────────┐
│  SAVED SEARCHES    │  All Papers                          │
│  ──────────────    │  ─────────────────────────────────   │
│  ● All Papers      │  Flow matching convergence…          │
│  ──────────────    │  Published: Apr 3                    │
│  Mirror Symmetry   │  Updated: Apr 3 · Revised     [×]   │
│  Gromov-Witten     │  ────────────────────────────────    │
│  Dennis Eriksson   │  Diffusion models for…               │
│  Karim Adiprasito  │  Published: Apr 2                    │
│  ──────────────    │  Updated: Apr 2                [×]   │
│  [+ Add Search]    │  ────────────────────────────────    │
│                    │  Attention mechanisms…                │
│                    │  Published: Mar 30                   │
│                    │  Updated: Mar 30               [×]   │
└────────────────────┴─────────────────────────────────────┘
```

- Sidebar lists all saved searches + an "All Papers" pseudo-entry at top
- Selecting a search filters the paper list to papers matching that search
- "All Papers" shows the full history across all searches
- Right-click search → Edit / Delete

### Add Search Sheet

```
┌────────────────────────────────────┐
│  New Saved Search             [×]  │
│  ──────────────────────────────    │
│  Name:  [________________________] │
│                                    │
│  CLAUSES (ANDed together)          │
│  ┌──────────────────────────────┐  │
│  │ [Category ▼] [cs.LG_______] │  │
│  │                     [Remove] │  │
│  ├──────────────────────────────┤  │
│  │ [Keyword ▼]  [flow matching] │  │
│  │ Scope: [● Title + Abstract]  │  │
│  │        [○ Title only]        │  │
│  │        [○ Abstract only]     │  │
│  │                     [Remove] │  │
│  └──────────────────────────────┘  │
│  [+ Add Clause]                    │
│                                    │
│  [Cancel]               [Save]     │
└────────────────────────────────────┘
```

- Category clause: value field with autocomplete from known arXiv categories
- Author clause: free text
- Keyword clause: free text with scope selector (title+abstract default)
- Each search in sidebar: right-click → Edit / Delete

### Settings View

```
General
  Launch at login:   [Toggle]

Notifications
  Sound:             [Paper flip ▼]  (Paper flip / Default / None)

Appearance
  Badge style:       [Count ▼]      (Count / Dot / None)
```

### Badge on Menu Bar Icon

- Show count of papers where `isNew == true`
- Render the badge by compositing the count into an `NSImage` and setting it on the
  `NSStatusItem` button's image. `MenuBarExtra`'s SwiftUI label does not support
  arbitrary overlays. Access the underlying `NSStatusItem` via an `NSViewRepresentable` wrapper.

## Notifications

### Permission

Request notification permission (`UNUserNotificationCenter.requestAuthorization`) on
first saved search creation — not on app launch. This ensures the user understands
what the app does before the system prompt appears.

### When to Fire

After each fetch cycle, notify only about papers that both:
- were discovered or revised in **this cycle**
- have `isNew == true`

This excludes baseline-seeded papers from a new or edited search, since those are added
with `isNew = false`. Build the notification from:
- `pendingNew.values.filter(\.isNew)`
- `pendingRevisions.values.filter(\.isNew)`

This prevents both notification floods on first run and re-alerting on yesterday's unread
papers when nothing new arrived today.

```swift
// newThisCycle: [MatchedPaper] — from pendingNew + pendingRevisions, filtered to isNew == true
guard !newThisCycle.isEmpty else { return } // no notification if nothing new

let content = UNMutableNotificationContent()
content.title = "arXiv Monitor"
content.subtitle = "\(newThisCycle.count) New Paper\(newThisCycle.count == 1 ? "" : "s")"
content.body = newThisCycle.first?.title ?? ""
switch soundName {
case "paper-flip":
    content.sound = UNNotificationSound(named: UNNotificationSoundName("paper-flip.aiff"))
case "default":
    content.sound = .default
case "none":
    content.sound = nil
default:
    content.sound = nil
}
content.threadIdentifier = "arxiv-monitor"

// Action buttons
content.categoryIdentifier = "NEW_PAPERS"
// Register actions: "Open" and "Dismiss All"
```

### Notification Actions

Register two actions:
- **Open** → brings up the popover (papers remain `isNew` until explicitly opened or dismissed)
- **Dismiss All** → sets `isNew = false` on all papers with `isNew == true`

### Grouping

All notifications share `threadIdentifier = "arxiv-monitor"` so they stack in Notification Center.

## Scheduling

### For v1: Simple Timer (menu bar app stays resident)

Since it's a menu bar app, it stays running. Use a simple `Timer` or `DispatchQueue` that fires once daily.
Each cycle iterates over all saved searches with a 3-second delay between API calls:

```swift
// Calculate next fetch time: 04:00 UTC today or tomorrow
// (hardcoded — arXiv announces ~00:00 UTC, 4h buffer for API lag)
// Schedule a Timer to fire at that time
// On fire:
//   run fetch cycle (see Fetch Flow):
//     iterate all searches → accumulate changes → commit
//   notify only for papers discovered this cycle with isNew == true
// Reschedule for next day
```

Also subscribe to `NSWorkspace.didWakeNotification` to handle the common case where the
app is already running but the Mac slept overnight. On wake, check whether any search
is stale: compute the most recent 04:00 UTC (today's if current time is past 04:00,
otherwise yesterday's). A search is stale if `lastQueriedAt < mostRecentScheduledRun`
(or `lastQueriedAt == nil`). If any search is stale, run the fetch cycle — only stale
searches are re-fetched, not all of them.

On app launch, apply the same stale-search check.

### Launch at Login

Use `SMAppService.mainApp` (macOS 13+):
```swift
import ServiceManagement
try SMAppService.mainApp.register()   // enable
try SMAppService.mainApp.unregister() // disable
```

## Implementation Order

### Phase 1: Core (get it working)
1. Create Xcode project (macOS App, SwiftUI lifecycle, menu bar extra)
2. Implement `SavedSearch`, `SearchClause`, and `MatchedPaper` models
3. Implement `ArXivAPIClient` — build query URL per saved search, fetch via URLSession
4. Implement `XMLAtomParser` — parse Atom XML response into `[MatchedPaper]`
5. Implement `PollScheduler` — daily timer + wake handler + on-launch catch-up check
6. Build `MenuBarPopover` — paper list with new/history states
7. Wire up: iterate saved searches → fetch → parse → dedup → store → update UI

### Phase 2: Notifications + Polish
8. Implement `NotificationService` — request permission, post notifications on new papers
9. Add custom notification sound (paper-flip.aiff)
10. Register notification actions (Open, Dismiss All)
11. Build `AddSearchSheet` — create/edit saved searches with clauses
12. Build `SearchListView` — sidebar in MainWindowView
13. Build `SettingsView` — sound, badge, launch at login
14. Add badge overlay on menu bar icon

### Phase 3: Main Window
15. Build `MainWindowView` — NavigationSplitView with search sidebar + paper list detail pane
16. Implement 90-day auto-pruning

### Phase 4: Finishing
17. Manual refresh button in popover
18. App icon design
19. First launch onboarding (add your first saved search)

## Testing Strategy

### Unit Tests (XCTest)
- `ArXivAPIClient.buildQuery(search:)` — verify URL construction for various clause combinations
- `XMLAtomParser` — parse bundled sample Atom XML, verify correct MatchedPaper extraction
- `AppState` — add/remove saved searches, verify state transitions
- First run — new search (`lastQueriedAt == nil`) adds papers with `isNew = false` (baseline, no notification flood)
- Subsequent run — new papers get `isNew = true`, existing papers unchanged
- Notification delta — only papers discovered this cycle with `isNew = true` notify; baseline-seeded and previously unread papers do not re-notify
- Revisions — paper with newer `updatedAt` re-surfaced with `isNew = true`, metadata updated
- Search clause edit — stale UUIDs scrubbed from matchedSearchIDs, `lastQueriedAt` reset to nil; re-fetch adds papers with `isNew = false`; name-only edit does not trigger cleanup
- Search delete — stale UUIDs scrubbed from matchedSearchIDs, orphaned papers removed
- Deduplication — existing papers not re-added
- Pruning — papers with `foundAt` older than 90 days removed correctly
- Seen-state clearing — `openPaper` clears only that paper; dismiss clears only that paper; dismiss all clears all; opening/closing popover clears nothing
- Revision preserves foundAt — revised paper keeps original `foundAt`, only metadata and `isNew` updated
- Partial failure — failed search keeps old `lastQueriedAt`; successful searches advance independently
- Wake catch-up — stale searches (lastQueriedAt before most recent 04:00 UTC) detected and re-fetched; non-stale searches skipped

### Integration Test
- One live API test (disabled in CI): fetch `cat:cs.LG`, verify valid response parsing

### Manual Testing
- Debug flag: `--fetch-now` to trigger immediate fetch instead of waiting for schedule
- Debug flag: `--sample-data` to load bundled mock data for UI testing
- Test notification permissions, sound playback, badge updates

## Build & Run

```bash
# From repo root
xcodebuild -project ArXivMonitor.xcodeproj \
  -scheme ArXivMonitor \
  -configuration Release \
  build

# App bundle at:
# build/Release/ArXiv Monitor.app
```

Or open `ArXivMonitor.xcodeproj` in Xcode and press Cmd+R.

## Entitlements & Sandbox

The app is sandboxed. Required entitlements:
- `com.apple.security.network.client` — outgoing HTTP to arXiv API
- Notification permission requested at runtime via `UNUserNotificationCenter`
- No file entitlements needed — the sandbox container's Application Support directory is accessible by default
- For distribution outside the App Store: notarize with `xcrun notarytool`

## Known Limitations (not fixing in v1)

- **No pagination.** Each search fetches at most 100 results. The intended filters are narrow (specific author + category, keyword in a niche area), so 100 results per daily check is sufficient. Users who create unusually broad searches (e.g. bare `cat:cs.LG`) may miss papers. The app logs a warning if results are truncated. Paging support is a v2 concern.
- **No query escaping rules.** Author/keyword inputs with special characters (quotes, parentheses) need explicit quoting/escaping. This is an implementation detail to handle in `ArXivAPIClient.buildQuery` with corresponding unit tests, not a plan-level design decision.
- **History retention is hardcoded to 90 days.** No configurable retention setting in v1. Can be added later if needed.
- **Fetching requires the Mac to be awake.** macOS suspends all processes (including menu bar apps) when the lid is closed. The 04:00 UTC timer won't fire while sleeping. There is no public API for third-party apps to opt into Power Nap, and preventing sleep via `caffeinate` would drain battery. The on-wake and on-launch catch-up checks (per-search stale detection) handle this: papers arrive as soon as the laptop wakes. Since arXiv updates only once daily, a few hours' delay loses nothing.

## Future (v2)

- iPhone companion app: sync papers via CloudKit, push notifications via CKDatabaseSubscription
- Zotero integration: "Save to Zotero" button per paper (Zotero Web API)
- Semantic Scholar enrichment: citation counts, related paper recommendations
- LLM-powered summaries of new papers
- Obsidian integration: create paper notes from template
- Raycast companion extension
