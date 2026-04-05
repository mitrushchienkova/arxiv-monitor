# UI Issues Investigation — Root Cause Analysis

## Issue 1: Popover Not Showing Papers

### Root Cause
The `ScrollView` in `MenuBarPopover.paperList` (line 166-210) is likely **collapsing to zero height** when placed inside `MenuBarExtra(.window)`. This is a known SwiftUI limitation where `ScrollView` doesn't properly communicate its content size to parent containers in menu bar contexts.

**Evidence:**
- Conditional logic (lines 45-53) correctly routes to `paperList` when papers exist
- `paperList` renders a `VStack` inside a `ScrollView` with `.frame(maxHeight: 400)`
- The `.frame(maxHeight: 400)` should provide vertical space, but `ScrollView` isn't expanding to fill available height in MenuBarExtra
- Similar issues reported in SwiftUI forums for MenuBarExtra + ScrollView combinations

### Files Affected
- `/Users/anna/Documents/repos/arxiv-monitor/ArXivMonitor/Views/MenuBarPopover.swift` (lines 165-211)

### Proposed Fix
Replace `ScrollView` with `List` — it handles sizing correctly in MenuBarExtra and provides better native integration. `List` will automatically handle scrolling when content exceeds available space.

**Why List is better:**
- `List` is specifically designed for scrollable content in macOS menus
- Automatically manages height and scrolling
- Better performance for large lists
- Native look and feel in menu contexts

---

## Issue 2: Date Display

### Root Cause
The date formatting in `PaperRowView.formattedDate()` is **correct**. It properly:
1. Parses ISO8601 format using `ISO8601DateFormatter()`
2. Formats using `DateFormatter` with `.medium` date style (e.g., "Apr 5, 2026")
3. Returns raw string if parsing fails (fallback)

**No issues found** — dates should display correctly as "Published: Month Day, Year" and "Updated: Month Day, Year".

### Files Affected
- `/Users/anna/Documents/repos/arxiv-monitor/ArXivMonitor/Views/PaperRowView.swift` (lines 70-77)

### Status
✓ No fix needed — implementation is correct.

---

## Issue 3: Main Window Paper List (PaperListView)

### Status
✓ **No issues found**. `PaperListView.swift` uses `List` (line 32), which:
- Properly handles content sizing
- Works correctly in standard window contexts
- No reported visual issues

---

## Summary Table

| Issue | Root Cause | Severity | Fix |
|-------|-----------|----------|-----|
| Popover papers not showing | ScrollView collapse in MenuBarExtra | **High** | Replace ScrollView with List |
| Date display | None — code is correct | N/A | ✓ No fix needed |
| Main window list | None — uses List | N/A | ✓ No fix needed |

---

## Implementation Details

### The Fix: Replace ScrollView with List in MenuBarPopover

**Current code (lines 165-211):**
```swift
@ViewBuilder
private var paperList: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            // ... content ...
        }
    }
    .frame(maxHeight: 400)
}
```

**Proposed replacement:**
```swift
@ViewBuilder
private var paperList: some View {
    List {
        let newPapers = appState.newPapers
        if !newPapers.isEmpty {
            Section("NEW PAPERS") {
                ForEach(newPapers) { paper in
                    PaperRowView(
                        paper: paper,
                        onOpen: { appState.openPaper(paper) },
                        onDismiss: { appState.dismissPaper(paper.id) }
                    )
                }
            }
        }

        let historyPapers = appState.allPapersSorted.filter { !$0.isNew }.prefix(5)
        if !historyPapers.isEmpty && newPapers.isEmpty {
            Section("RECENT") {
                ForEach(Array(historyPapers)) { paper in
                    PaperRowView(
                        paper: paper,
                        onOpen: { appState.openPaper(paper) },
                        onDismiss: { appState.dismissPaper(paper.id) }
                    )
                }
            }
        }
    }
    .frame(maxHeight: 400)
}
```

**Why this works:**
- `List` automatically handles ScrollView behavior
- `Section` headers replace manual `Text` + dividers (cleaner code)
- Properly sizes within MenuBarExtra context
- Better accessibility and interaction patterns
