import AppIntents
import Foundation

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
//
// Every input to the answer goes to the diagnostic log: this runs from automations, often at night
// with the phone locked, where nobody sees the dialog.

struct GetSleepStateIntent: AppIntent {

    static var title: LocalizedStringResource = "Am I asleep"
    static var description = IntentDescription(
        "Syncs with the Mi Band 10 and tells you whether you are asleep, based on the last known sleep data."
    )

    // Runs in the background without bringing the app to the foreground.
    static var openAppWhenRun = false

    private static let connectWait: Duration = .seconds(10)

    private static let log = AppLogger(category: "SleepIntent")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        AppServices.shared.bootstrap(container: My_BandApp.sharedModelContainer)
        Self.log.info("Sleep intent run — \(DiagnosticLog.appContext())")

        // Best-effort refresh so the answer isn't working off hours-old data. A failure here (band
        // out of range, already mid-sync, etc.) isn't fatal — fall through to the last local sync,
        // but it IS reported: an answer built on a sync that never happened is exactly the silent
        // staleness this intent exists to avoid.
        var syncFailed = false
        do {
            let outcome = try await BackgroundSyncManager.shared.syncNow(trigger: .sleepIntent,
                                                                         connectTimeout: Self.connectWait)
            Self.log.info("Sleep intent sync ok — \(outcome.sleepSessions) sleep report(s) in this sync")
        } catch {
            syncFailed = true
            Self.log.error("Sleep intent sync failed: \(DiagnosticLog.describe(error))")
        }

        guard let session = AppServices.shared.bandSyncer.mostRecentSleepSession() else {
            Self.log.info("Sleep intent → awake: no stored sleep session")
            return .result(
                value: false,
                dialog: syncFailed
                    ? "Couldn't sync with the band and there is no local sleep data."
                    : "No sleep data synced yet."
            )
        }

        let now = Date()
        let verdict = SleepStateRule.evaluate(session, now: now)
        let sleeping = verdict.asleep
        Self.log.info("Sleep intent → \(sleeping ? "asleep" : "awake") (\(verdict.reason)): latest session \(session.startDate.logStamp) → \(session.endDate.logStamp), fetched \(session.fetchedAt?.logStamp ?? "—"), awakeFlag \(session.awakeFlag.map { "\($0)" } ?? "n/a"), \(session.phases.count) phase(s)")

        let freshness = RelativeDateTimeFormatter()
        freshness.locale = Locale(identifier: "en_US")
        freshness.unitsStyle = .abbreviated
        let asOf = freshness.localizedString(for: session.endDate, relativeTo: now)

        let caveat = syncFailed ? ", not synced just now" : ""
        let dialog = sleeping
            ? "Yes, asleep (data from \(asOf)\(caveat))."
            : "No, awake (data from \(asOf)\(caveat))."
        return .result(value: sleeping, dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - SleepStateRule
//
// "Asleep" from the latest stored report. While the band has a night open (awakeFlag 0) the report's
// end keeps pace with the sync — 07:34 at a 07:34 sync, 12:37 at 12:38 — and it freezes once the
// user wakes, the flag only turning 1 an hour or more later (hardware, 2026-10-01: frozen at 12:37,
// still 0 at 13:31, 1 by 15:17). So the gap between end and fetch answers sooner than the flag. The
// old rule ("ended under an hour ago, last phase not awake") said asleep at 13:31, 54 min after
// waking; it remains the fallback for reports stored before the flag and fetch time were kept.

enum SleepStateRule {

    /// End this far behind the fetch means the night stopped growing. The band reports whole
    /// minutes and a sync's own latency adds a little.
    static let stoppedGrowingAfter: TimeInterval = 5 * 60
    /// A report older than this says nothing about now — the sync that would refresh it failed.
    static let staleAfter: TimeInterval = 60 * 60

    static func evaluate(_ session: SleepSession, now: Date) -> (asleep: Bool, reason: String) {
        let lastPhase = session.phases.max { $0.startDate < $1.startDate }?.type
        if lastPhase == .awake { return (false, "last phase awake") }

        guard let flag = session.awakeFlag, let fetched = session.fetchedAt else {
            let age = now.timeIntervalSince(session.endDate)
            return age < staleAfter
                ? (true, "legacy rule: ended \(Int(age / 60)) min ago")
                : (false, "legacy rule: ended \(Int(age / 60)) min ago")
        }
        if flag != 0 { return (false, "band closed the night") }
        let lag = fetched.timeIntervalSince(session.endDate)
        if lag > stoppedGrowingAfter { return (false, "night stopped growing \(Int(lag / 60)) min before the fetch") }
        let age = now.timeIntervalSince(fetched)
        if age >= staleAfter { return (false, "open night, but fetched \(Int(age / 60)) min ago") }
        return (true, "open night, growing at the fetch")
    }
}
