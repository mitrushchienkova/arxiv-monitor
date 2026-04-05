import Foundation
import AppKit

/// Schedules daily fetch cycles at 04:00 UTC and handles wake/launch catch-up.
@MainActor
final class PollScheduler {
    private var timer: Timer?
    private weak var appState: AppState?
    private var wakeObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Start the scheduler: check on launch, set up daily timer, subscribe to wake.
    func start() {
        // Check on launch
        checkAndFetchIfStale()

        // Schedule daily timer
        scheduleNextFetch()

        // Subscribe to wake notifications
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndFetchIfStale()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Compute the most recent scheduled run time (04:00 UTC).
    nonisolated static func mostRecentScheduledRun() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let now = Date()
        // Today at 04:00 UTC
        var components = utcCalendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 4
        components.minute = 0
        components.second = 0

        guard let todayAt4 = utcCalendar.date(from: components) else { return now }

        if now >= todayAt4 {
            return todayAt4
        } else {
            // Yesterday at 04:00 UTC
            return utcCalendar.date(byAdding: .day, value: -1, to: todayAt4) ?? todayAt4
        }
    }

    /// Compute the next scheduled run time (04:00 UTC).
    private func nextScheduledRun() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let now = Date()
        var components = utcCalendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 4
        components.minute = 0
        components.second = 0

        guard let todayAt4 = utcCalendar.date(from: components) else { return now }

        if now < todayAt4 {
            return todayAt4
        } else {
            return utcCalendar.date(byAdding: .day, value: 1, to: todayAt4) ?? todayAt4
        }
    }

    /// The date of the next scheduled fetch, for display in the UI.
    var nextFetchDate: Date {
        nextScheduledRun()
    }

    private func scheduleNextFetch() {
        timer?.invalidate()
        let fireDate = nextScheduledRun()
        let interval = max(fireDate.timeIntervalSinceNow, 1)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.appState?.runFetchCycle()
                self?.scheduleNextFetch()
            }
        }
    }

    /// Check if any search is stale and run fetch cycle if needed.
    private func checkAndFetchIfStale() {
        guard let appState = appState else { return }

        // If --fetch-now flag, always fetch all
        if CommandLine.arguments.contains("--fetch-now") {
            appState.runFetchCycle()
            return
        }

        let threshold = PollScheduler.mostRecentScheduledRun()
        let formatter = ISO8601DateFormatter()

        let hasStale = appState.savedSearches.contains { search in
            guard let lastQueried = search.lastQueriedAt,
                  let date = formatter.date(from: lastQueried) else {
                return true // nil lastQueriedAt means stale
            }
            return date < threshold
        }

        if hasStale && !appState.savedSearches.isEmpty {
            appState.runFetchCycleForStaleSearches()
        }
    }
}
