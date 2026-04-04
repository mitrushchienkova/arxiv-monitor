# arXiv Monitor — Implementation Plan

## Overview

A native macOS menu bar app that monitors arXiv.org for new papers matching user-configurable filters (keywords, categories, authors). Sends native macOS notifications with sound when new papers arrive. Zero external dependencies — Apple frameworks only.

## Architecture

```
ArXivMonitor.app (SwiftUI, macOS 13+)
├── ArXivMonitorApp.swift        — App entry point, MenuBarExtra
├── Models/
│   ├── Filter.swift             — Filter data model (keyword/category/author)
│   ├── MatchedPaper.swift       — Lightweight paper metadata for history
│   └── AppState.swift           — Observable app state (papers, filters, timestamps)
├── Services/
│   ├── ArXivAPIClient.swift     — Fetch + parse arXiv Export API (Atom XML)
│   ├── XMLAtomParser.swift      — Parse Atom 1.0 XML into MatchedPaper structs
│   ├── NotificationService.swift — Schedule native macOS notifications
│   └── PollScheduler.swift      — Daily check scheduling (Timer-based)
├── Views/
│   ├── MenuBarPopover.swift     — Main popover (paper list, badge)
│   ├── PaperRowView.swift       — Single paper row in the list
│   ├── FilterListView.swift     — Filter management sidebar
│   ├── AddFilterSheet.swift     — Add/edit filter modal
│   ├── HistoryView.swift        — Full window with history + dismissed papers
│   └── SettingsView.swift       — App preferences
└── Resources/
    └── paper-flip.aiff          — Custom notification sound
```

## Data Model

### Storage: UserDefaults (local) + NSUbiquitousKeyValueStore (iCloud sync)

All data fits comfortably in UserDefaults. No database needed.

### Persisted Data

```swift
// UserDefaults — local app preferences
"checkTime"        : String     // e.g. "23:30" — when to run daily check
"soundEnabled"     : Bool       // play sound on notification
"soundName"        : String     // "paper-flip" | "default" | "none"
"badgeStyle"       : String     // "count" | "dot" | "none"
"launchAtLogin"    : Bool

// NSUbiquitousKeyValueStore — synced via iCloud
"lastFetchedAt"    : String     // ISO8601 timestamp of last API fetch
"lastViewedAt"     : String     // ISO8601 timestamp of last popover open
"dismissedIDs"     : [String]   // arXiv IDs explicitly dismissed by user
"matchedPapers"    : Data       // JSON-encoded [MatchedPaper], last 90 days
"filters"          : Data       // JSON-encoded [Filter]
```

### Models

```swift
struct Filter: Codable, Identifiable {
    let id: UUID
    var type: FilterType        // .keyword | .category | .author
    var value: String           // e.g. "flow matching", "cs.LG", "Hinton"
    var match: MatchScope       // .title | .abstract | .titleAndAbstract (keyword only)
    var enabled: Bool
}

enum FilterType: String, Codable {
    case keyword, category, author
}

enum MatchScope: String, Codable {
    case title, abstract, titleAndAbstract
}

struct MatchedPaper: Codable, Identifiable {
    let id: String              // arXiv ID, e.g. "2404.12345"
    let title: String
    let authors: String         // "Smith, Chen, Wang"
    let category: String        // "cs.LG"
    let date: String            // ISO8601 date
    let abstractSnippet: String // first ~200 chars of abstract
    var link: String            // URL to arXiv page
}
```

### Paper States

| State | Meaning | How determined |
|---|---|---|
| **New** | Arrived after `lastViewedAt` | paper.date > lastViewedAt |
| **Seen** | User opened popover and saw it | paper.date <= lastViewedAt, not in dismissedIDs |
| **Dismissed** | User marked "not interesting" | ID is in dismissedIDs |

### Pruning

On each fetch cycle, remove entries from `matchedPapers` and `dismissedIDs` older than 90 days.

## arXiv API Integration

### Endpoint

```
https://export.arxiv.org/api/query?search_query=...&sortBy=submittedDate&sortOrder=descending&max_results=100
```

### Query Building

Combine user filters into a single boolean query:

```
// Filters: category=cs.LG, keyword="flow matching", author=Hinton
// Query:   cat:cs.LG AND all:"flow matching" AND au:Hinton

// Multiple keywords use OR within type, AND between types:
// keywords: ["flow matching", "diffusion"]
// categories: ["cs.LG", "cs.AI"]
// authors: ["Hinton"]
// Query: (cat:cs.LG OR cat:cs.AI) AND (all:"flow matching" OR all:diffusion) AND au:Hinton
```

Field prefixes:
- `ti:` — title only
- `abs:` — abstract only
- `all:` — all fields (title + abstract)
- `au:` — author
- `cat:` — category

### Rate Limits

- 1 request per 3 seconds
- Max 2000 results per call
- No API key needed

### Important: arXiv Update Schedule

- Papers announced once daily: Sun-Thu at ~8 PM ET
- No announcements on Saturday
- Sunday's feed covers Friday + Saturday submissions
- **The app should run its daily check once, around 11 PM ET or midnight ET**
- Hourly polling is wasteful — only one check per day yields new results

### Detecting New Papers

Two approaches (implement both, prefer A):

**A) Compare against stored IDs:** Fetch latest papers matching filters, compare against `matchedPapers` IDs, new ones are papers we haven't seen.

**B) Date-based:** Use `lastFetchedAt` to only consider papers published after that timestamp. Note: `lastUpdatedDate` in the API also catches revisions, so filter client-side where `updated == published` to skip revisions.

### XML Parsing

arXiv returns Atom 1.0 XML. Use Swift's built-in `XMLParser` (delegate-based) or `XMLDocument` (tree-based, macOS only).

Key Atom elements to extract per entry:
```xml
<entry>
  <id>http://arxiv.org/abs/2404.12345v1</id>
  <title>Paper Title Here</title>
  <summary>Abstract text...</summary>
  <published>2024-04-03T20:00:00Z</published>
  <updated>2024-04-03T20:00:00Z</updated>
  <author><name>Author Name</name></author>
  <arxiv:primary_category term="cs.LG"/>
  <link href="http://arxiv.org/abs/2404.12345v1"/>
</entry>
```

Extract arXiv ID from the `<id>` URL by taking the last path component (strip version suffix).

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
            HistoryView(appState: appState)
        }
    }
}
```

### Menu Bar Popover (primary interaction)

```
┌─────────────────────────────────────┐
│  arXiv Monitor          [⚙] [↺]    │
│  Last checked: 11:05 PM            │
├─────────────────────────────────────┤
│  3 NEW PAPERS                       │
│  ──────────────────────────────     │
│  [blue dot] Flow matching converg…  │
│       cs.LG · Smith et al.         │
│                        [Dismiss ×]  │
│                                     │
│  [blue dot] Diffusion models for…   │
│       cs.AI · Chen, Wang           │
│                        [Dismiss ×]  │
│                                     │
│  [blue dot] Attention mechanisms…   │
│       cs.CL · Jones et al.         │
│                        [Dismiss ×]  │
│                                     │
├─────────────────────────────────────┤
│  [History]  [Filters]  [Dismiss All]│
└─────────────────────────────────────┘
```

- Click paper title → opens arXiv page in default browser
- Blue dot = new (arrived after lastViewedAt)
- Opening the popover updates `lastViewedAt` (clears "new" dots on next open)
- "Dismiss" moves paper ID to `dismissedIDs`
- "Dismiss All" dismisses all currently shown papers
- "History" opens the full window (HistoryView)
- "Filters" opens the full window focused on filter sidebar
- [↺] = manual refresh (fetch now)
- [⚙] = opens Settings

### History View (full window)

```
┌──────────────────────────────────────────────────────┐
│ Sidebar               │ Paper Detail                  │
│ ─────────────────     │ ──────────────────            │
│ [New (3)]             │ Flow matching convergence…    │
│ [All Papers]          │ Smith, Chen · cs.LG           │
│ [Dismissed (45)]      │ Apr 4, 2026                   │
│                       │ ──────────────────            │
│ FILTERS               │ Abstract snippet here…        │
│ + Add Filter          │                               │
│ ─────────────────     │ [Open on arXiv]  [Dismiss]    │
│ ● cs.LG              │                               │
│ ● "flow matching"    │                               │
│ ○ cs.AI (disabled)   │                               │
│ ● Hinton             │                               │
└──────────────────────────────────────────────────────┘
```

### Add Filter Sheet

```
┌────────────────────────────────────┐
│  Add Filter                   [×]  │
│  ──────────────────────────────    │
│  Type:  [Keyword ▼]               │
│                                    │
│  Value: [________________________] │
│                                    │
│  Match: [● Title + Abstract]       │  ← only for keyword type
│         [○ Title only]             │
│         [○ Abstract only]          │
│                                    │
│  [Cancel]              [Add Filter]│
└────────────────────────────────────┘
```

- Category type: value field with autocomplete from known arXiv categories
- Author type: free text
- Each filter in sidebar: right-click → Edit / Delete; toggle to enable/disable

### Settings View

```
General
  Check schedule:    [Daily at 11:00 PM ▼]
  Launch at login:   [Toggle]

Notifications
  Sound:             [Paper flip ▼]  (Paper flip / Default / None)

Appearance
  Badge style:       [Count ▼]      (Count / Dot / None)

Data
  History retention: [90 days ▼]
  [Clear History]    [Clear Dismissed]
```

### Badge on Menu Bar Icon

- Show unread count (papers not yet viewed — arrived after `lastViewedAt` and not in `dismissedIDs`)
- Use SwiftUI overlay on the menu bar label, or update the NSStatusItem title/image dynamically

## Notifications

### When to Fire

After each daily fetch, if new papers are found (not in `matchedPapers` already):

```swift
let content = UNMutableNotificationContent()
content.title = "arXiv Monitor"
content.subtitle = "\(newCount) New Paper\(newCount == 1 ? "" : "s")"
content.body = papers.first?.title ?? ""
content.sound = soundEnabled ? UNNotificationSound(named: "paper-flip") : nil
content.threadIdentifier = "arxiv-monitor"

// Action buttons
content.categoryIdentifier = "NEW_PAPERS"
// Register actions: "Open" and "Dismiss All"
```

### Notification Actions

Register two actions:
- **Open** → brings up the popover or full window
- **Dismiss All** → marks all new papers as dismissed

### Grouping

All notifications share `threadIdentifier = "arxiv-monitor"` so they stack in Notification Center.

## Scheduling

### For v1: Simple Timer (menu bar app stays resident)

Since it's a menu bar app, it stays running. Use a simple `Timer` or `DispatchQueue` that fires once daily:

```swift
// Calculate next check time (e.g., 11 PM local time today or tomorrow)
// Schedule a Timer to fire at that time
// On fire: fetch → diff → notify → update lastFetchedAt
// Reschedule for next day
```

Also check on app launch: if `lastFetchedAt` is more than 24 hours ago, fetch immediately.

### Launch at Login

Use `SMAppService.mainApp` (macOS 13+):
```swift
import ServiceManagement
try SMAppService.mainApp.register()   // enable
try SMAppService.mainApp.unregister() // disable
```

## iCloud Sync (for future iPhone widget)

Use `NSUbiquitousKeyValueStore` for `lastFetchedAt`, `lastViewedAt`, `dismissedIDs`, `matchedPapers`, `filters`.

```swift
let store = NSUbiquitousKeyValueStore.default
store.set(encoded, forKey: "matchedPapers")
store.synchronize()
```

iCloud KV store limit: 1MB total, 1MB per key. Our data is well under this (~100-400KB after a year).

A future iPhone widget reads from this store to display unread papers.

## Implementation Order

### Phase 1: Core (get it working)
1. Create Xcode project (macOS App, SwiftUI lifecycle, menu bar extra)
2. Implement `Filter` and `MatchedPaper` models
3. Implement `AppState` with UserDefaults persistence
4. Implement `ArXivAPIClient` — build query URL from filters, fetch via URLSession
5. Implement `XMLAtomParser` — parse Atom XML response into `[MatchedPaper]`
6. Implement `PollScheduler` — daily timer + on-launch catch-up check
7. Build `MenuBarPopover` — paper list with dismiss buttons
8. Wire up: fetch → parse → dedup → store → update UI

### Phase 2: Notifications + Polish
9. Implement `NotificationService` — request permission, post notifications on new papers
10. Add custom notification sound (paper-flip.aiff)
11. Register notification actions (Open, Dismiss All)
12. Build `AddFilterSheet` — add/edit/remove filters
13. Build `FilterListView` — sidebar with toggle/delete
14. Build `SettingsView` — check time, sound, badge, launch at login
15. Add badge overlay on menu bar icon

### Phase 3: History + Window
16. Build `HistoryView` — full window with sidebar (New / All / Dismissed)
17. Add paper detail view (abstract snippet, open link, dismiss)
18. Implement 90-day auto-pruning

### Phase 4: iCloud + Finishing
19. Migrate storage to `NSUbiquitousKeyValueStore`
20. Test iCloud sync between devices
21. Manual refresh button in popover
22. App icon design
23. First launch onboarding (add your first filter)

## Testing Strategy

### Unit Tests (XCTest)
- `ArXivAPIClient.buildQuery(filters:)` — verify URL construction for various filter combinations
- `XMLAtomParser` — parse bundled sample Atom XML, verify correct MatchedPaper extraction
- `AppState` — add/remove filters, dismiss papers, verify state transitions
- Deduplication — existing papers not re-added, dismissed papers filtered from display
- Pruning — papers older than 90 days removed correctly

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

## Future (v2)

- Zotero integration: "Save to Zotero" button per paper (Zotero Web API)
- iPhone widget: reads from iCloud KV store, shows unread count + titles
- Semantic Scholar enrichment: citation counts, related paper recommendations
- LLM-powered summaries of new papers
- Obsidian integration: create paper notes from template
- Raycast companion extension
