# arXiv Monitor

A native macOS menu bar app that monitors [arXiv.org](https://arxiv.org) for new papers matching user-configurable saved searches. Sends native macOS notifications when new papers arrive.

Built with SwiftUI. Zero external dependencies -- Apple frameworks only. Requires macOS 13+.

## Features

### Saved Searches

Create independent saved searches to monitor arXiv for specific topics. Each search consists of one or more clauses combined with AND/OR logic:

- **Keyword** -- match against title, abstract, or both
- **Category** -- filter by arXiv category (e.g. `math.AG`, `cs.LG`, `hep-th`)
- **Author** -- search by author name

Examples:
- "Gromov-Witten" (keyword in title + abstract)
- cs.LG papers by Hinton (category AND author)
- "flow matching" in title (keyword, title only)

### Configurable Date Filtering

- Each search has a configurable "Fetch from" date -- defaults to 90 days ago
- "All time" option available for fetching complete history
- Pagination support: automatically fetches all matching results beyond the 100-result API limit
- Progress indicator shows pagination status during multi-page fetches

### Menu Bar Integration

- Lives in the macOS menu bar with a paper icon
- Badge shows unread paper count (configurable: count, dot, or hidden)
- Click to open a popover showing new papers at a glance
- Quick actions: refresh, open settings, dismiss all, open full window

### Full Window

- **Sidebar** with "All Papers" and individual saved searches
- **Paper list** showing matched papers sorted by update date
- Unread count badges (purple) and total count for each search
- Color-coded search filters with a colored stripe in the sidebar
- Colored square badges on each paper showing which searches matched it
- "Mark All as Read" button (works per-search or globally)
- Manual refresh button

### Paper Details

Each paper row displays:
- Title (bold if unread, with a purple dot indicator)
- Primary arXiv category
- Author list
- "Revised" tag (orange) for papers updated after initial publication
- Published and updated dates
- Colored badges for matching searches
- Dismiss button to remove papers from the list
- Click title to open on arXiv

### Search Management

- **Edit** searches via context menu -- change name, clauses, color, or combine operator
- **Warning dialog** when editing clauses: "Changing search criteria will remove existing results for this search. Continue?"
- **Pause/Resume** searches via context menu -- paused searches are skipped during fetch cycles but retain existing papers (shown dimmed with a pause icon)
- **Delete** searches via context menu (removes associated papers)
- **Color assignment** -- each search gets an auto-assigned color from a built-in palette, editable via the color picker in the search editor

### Notifications

- Native macOS notifications for new and revised papers
- Configurable notification sound (custom paper-flip sound, system default, or none)
- First-run searches show papers as new in the UI but suppress notification flooding

### Background Monitoring

- Automatic fetch scheduling via `PollScheduler`
- Catches up on missed checks after wake from sleep
- 3-second delay between API calls to respect arXiv rate limits
- Launch at login option

### Data Persistence

- Saved searches and paper history stored in a JSON file (`data.json`) in the app's sandboxed Application Support directory
- Atomic file writes prevent data corruption
- Papers are kept forever once fetched (no automatic pruning)
- Settings (sound, badge style, launch at login) stored in UserDefaults

### Testing

- E2E UI tests covering settings, search management, data display, and sidebar functionality
- Launch with `--sample-data` flag to populate with test data

## Architecture

```
ArXivMonitor (Xcode project, single macOS target)
├── Models/
│   ├── SavedSearch.swift        -- Search model (clauses, color, pause state)
│   └── MatchedPaper.swift       -- Paper metadata
│
├── ArXivMonitorApp.swift        -- App entry point, MenuBarExtra
├── AppState.swift               -- Observable app state, persistence, fetch cycle
├── Services/
│   ├── ArXivAPIClient.swift     -- Fetch + parse arXiv Export API (Atom XML)
│   ├── XMLAtomParser.swift      -- Parse Atom 1.0 XML into MatchedPaper structs
│   ├── PollScheduler.swift      -- Periodic fetch scheduling
│   └── NotificationService.swift -- macOS notification delivery
├── Views/
│   ├── MenuBarPopover.swift     -- Main popover (paper list, badge)
│   ├── PaperRowView.swift       -- Single paper row
│   ├── MainWindowView.swift     -- Full window: sidebar + paper list
│   ├── SearchListView.swift     -- Saved search list (sidebar)
│   ├── PaperListView.swift      -- Paper list for selected search
│   ├── AddSearchSheet.swift     -- Add/edit saved search modal
│   └── SettingsView.swift       -- App preferences
└── Resources/
    └── paper-flip.aiff          -- Custom notification sound
```

## Building

Open `ArXivMonitor.xcodeproj` in Xcode 15+ and build the `ArXivMonitor` scheme, or from the command line:

```bash
xcodebuild -project ArXivMonitor.xcodeproj -scheme ArXivMonitor -configuration Release build
```

## Data Storage

| What | Where |
|------|-------|
| Paper history + saved searches | `~/Library/Containers/com.arxivmonitor.app/Data/Library/Application Support/ArXivMonitor/data.json` |
| Settings (sound, badge, launch) | UserDefaults (`com.arxivmonitor.app`) |

To reset the app to a clean state:

```bash
rm ~/Library/Containers/com.arxivmonitor.app/Data/Library/Application\ Support/ArXivMonitor/data.json
defaults delete com.arxivmonitor.app
```
