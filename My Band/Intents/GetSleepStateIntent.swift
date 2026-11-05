import AppIntents
import Foundation
import OSLog

// MARK: - GetSleepStateIntent
//
// "Am I asleep?" — the Shortcuts-native replacement for the Home Assistant "sleep
// detected" trigger that was cut from the roadmap. Instead of the app owning an automation
// (turn off the bedroom lights, run a script), it just answers this question; the user's own
// Shortcuts Personal Automation decides what to do with the answer.
//
// The band has no "fell asleep"/"woke up" push (see CLAUDE.md's BLE protocol notes) — sleep is
// always pull, discovered whenever the app happens to sync. So "is he sleeping" can only ever be
// "as of the last sync", never truly real-time. This intent narrows that gap by forcing a sync
// first (best-effort — a failed sync isn't fatal, it just falls back to whatever's already known)
// and is honest about it: the dialog always states how old the underlying data is, so a Shortcut
// chaining off this isn't silently acting on a stale answer.

struct GetSleepStateIntent: AppIntent {

    static var title: LocalizedStringResource = "Am I asleep"
    static var description = IntentDescription(
        "Syncs with the Mi Band 10 and tells you whether you are asleep, based on the last known sleep data."
    )

    // Runs in the background without bringing the app to the foreground.
    static var openAppWhenRun = false

    /// Beyond this age, the last known sleep window is treated as over rather than ongoing —
    /// matches the background-sync cadence closely enough that "stale" really does mean "probably
    /// woke up since", not just "hasn't synced in a while".
    private static let staleAfter: TimeInterval = 60 * 60

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "SleepIntent"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        // Best-effort refresh so the answer isn't working off hours-old data. A failure here (band
        // out of range, already mid-sync, etc.) isn't fatal — fall through to the last local sync,
        // but it IS reported: an answer built on a sync that never happened is exactly the silent
        // staleness this intent exists to avoid.
        var syncFailed = false
        do {
            _ = try await BackgroundSyncManager.shared.syncNow()
        } catch {
            syncFailed = true
            Self.log.error("Sleep intent sync failed: \(error.localizedDescription)")
        }

        guard let session = AppServices.shared.bandSyncer.mostRecentSleepSession() else {
            return .result(
                value: false,
                dialog: syncFailed
                    ? "Couldn't sync with the band and there is no local sleep data."
                    : "No sleep data synced yet."
            )
        }

        let age = Date().timeIntervalSince(session.endDate)
        let lastPhaseIsAwake = session.phases.sorted { $0.startDate < $1.startDate }.last?.type == .awake
        let sleeping = age < Self.staleAfter && !lastPhaseIsAwake

        let freshness = RelativeDateTimeFormatter()
        freshness.locale = Locale(identifier: "en_US")
        freshness.unitsStyle = .abbreviated
        let asOf = freshness.localizedString(for: session.endDate, relativeTo: Date())

        let caveat = syncFailed ? ", not synced just now" : ""
        let dialog = sleeping
            ? "Yes, asleep (data from \(asOf)\(caveat))."
            : "No, awake (data from \(asOf)\(caveat))."
        return .result(value: sleeping, dialog: IntentDialog(stringLiteral: dialog))
    }
}
