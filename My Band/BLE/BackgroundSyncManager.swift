import Foundation
import OSLog

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - BackgroundSyncManager
//
// Single entry point for driving an Apple Health sync, foreground or background.
//
// Triggers (all funnel through `syncNow`, which coalesces concurrent calls into one run):
//   • App Intent / Shortcuts        → syncNow()                (keeps a live link open)
//   • BGProcessingTask (heavy)      → handle() → syncNow()      (connects, syncs, disconnects)
//   • BGAppRefreshTask (frequent)   → handle() → syncNow()      (idem — runs far more often)
//   • State-restoration BLE wake    → syncOnBackgroundWakeIfStale() (the band reconnecting in the
//                                      background relaunches the app; we sync if data is stale)
//
// Two task types are registered: app-refresh is short and scheduled often by the OS; processing is
// for the heavier/deferrable run and tends to fire when charging. Registering both widens the
// window in which iOS will wake us. BGTaskScheduler.register MUST run before launch finishes, which
// is why register() is called from the AppDelegate — not a SwiftUI .onAppear.

@MainActor
final class BackgroundSyncManager {

    static let shared = BackgroundSyncManager()

    /// Must match the identifiers in Info.plist → BGTaskSchedulerPermittedIdentifiers.
    static let processingTaskID = "com.myband.sync"
    static let refreshTaskID    = "com.myband.refresh"

    /// Floor the OS treats as the earliest next background run (not a guarantee).
    private let minInterval: TimeInterval = 30 * 60
    /// A background-wake sync is skipped if Health was synced more recently than this — avoids
    /// re-syncing on every transient BLE reconnect.
    private let autoSyncStaleness: TimeInterval = 15 * 60

    private weak var manager: BandManager?
    private weak var syncer: BandSyncer?
    private var didRegister = false

    /// The in-flight sync, shared by every concurrent caller so duplicate triggers coalesce.
    private var inFlight: Task<BandSyncer.HealthSyncOutcome, Error>?

    /// The sync each live BGTask is running; an entry leaves the moment its task is completed.
    private var backgroundRuns: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Tasks whose expiry beat `handle` to the main actor, so `handle` knows not to start them.
    private var expiredBeforeStart: Set<ObjectIdentifier> = []

    private let log = AppLogger(category: "BGSync")

    private init() {}

    // MARK: - Setup

    /// Registers the BGTask handlers. Call once, from the launch path, before launch finishes.
    func register() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard !didRegister else { return }
        didRegister = true
        registerTask(Self.processingTaskID)
        registerTask(Self.refreshTaskID)
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func registerTask(_ identifier: String) {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            // The expiration handler goes on right here, on the scheduler's queue — not after the hop
            // to the main actor below. That hop can lag by seconds on a freshly resumed app (6 s on
            // hardware, 2026-09-11), and a task that expires with no handler is completed as failed by
            // iOS, which then schedules the app less often.
            task.expirationHandler = { Task { @MainActor in self?.expire(task) } }
            Task { @MainActor in self?.handle(task) }
        }
        log.info("BGTask register \(ok ? "succeeded" : "failed") for \(identifier)")
    }
    #endif

    /// Wires the live dependencies. Called from the UI setup path once the objects exist.
    func configure(manager: BandManager, syncer: BandSyncer) {
        self.manager = manager
        self.syncer = syncer
    }

    // MARK: - Scheduling

    /// Queues both background tasks. Safe to call repeatedly — the scheduler keeps only the latest
    /// pending request per identifier. No-op if no device is paired yet.
    func scheduleNext() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard syncer?.currentDevice != nil else {
            log.debug("No paired device — skipping BGTask schedule")
            return
        }
        submitProcessing()
        submitRefresh()
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func submitProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = false   // BLE + HealthKit are local
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        submit(request)
    }

    private func submitRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        submit(request)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Scheduled \(request.identifier) (≥\(Int(self.minInterval / 60)) min)")
        } catch {
            log.error("Failed to schedule \(request.identifier): \(error.localizedDescription)")
        }
    }

    // MARK: - Execution

    private func handle(_ task: BGTask) {
        let key = ObjectIdentifier(task)
        // Expired before the main actor got to it — expire(_:) has already completed it.
        if expiredBeforeStart.remove(key) != nil { return }

        log.info("Background task started: \(task.identifier)")
        // Always queue the next run first, so a failure here doesn't break the chain.
        scheduleNext()

        let trigger: SyncTrigger = task.identifier == Self.refreshTaskID ? .bgRefresh : .bgProcessing
        backgroundRuns[key] = Task { @MainActor in
            do {
                _ = try await syncNow(trigger: trigger)
                log.info("Background sync completed")
                finish(task, success: true)
            } catch is CancellationError {
                finish(task, success: false)
            } catch {
                log.error("Background sync failed: \(DiagnosticLog.describe(error))")
                finish(task, success: false)
            }
        }
    }

    private func expire(_ task: BGTask) {
        let key = ObjectIdentifier(task)
        log.warning("Background task expired — tearing down")
        guard let work = backgroundRuns[key] else {
            expiredBeforeStart.insert(key)
            task.setTaskCompleted(success: false)
            return
        }
        work.cancel()
        // Release the link but keep auto-reconnect, so the band can wake us again later.
        manager?.disconnect(userInitiated: false)
        // Completed now, not when the sync finally unwinds: past expiry iOS expects it at once.
        finish(task, success: false)
    }

    /// Completes the task exactly once, whichever of the sync and the expiry gets there first.
    private func finish(_ task: BGTask, success: Bool) {
        guard backgroundRuns.removeValue(forKey: ObjectIdentifier(task)) != nil else { return }
        task.setTaskCompleted(success: success)
    }
    #endif

    // MARK: - Sync (coalesced)

    /// What asked for a sync. Only the diagnostic log uses it: it has to tell a BLE wake at 3 a.m.
    /// apart from a Shortcut or a tap on the button.
    enum SyncTrigger: String {
        case manual, syncIntent, sleepIntent, batteryIntent, bgRefresh, bgProcessing, bleWake, unlock
    }

    /// Foreground-aware sync. Concurrent callers share a single run.
    /// `disconnectWhenDone`: nil = disconnect only if we opened the link (live foreground links stay
    /// up); true/false force the behaviour (background wakes pass true to free the radio).
    /// `connectTimeout`: how long to wait for the band when the link is down. A caller that has a
    /// fallback for an absent band (the battery intent answers with the last known level) passes less
    /// — the band connects in ~1–2 s when it's in range.
    @discardableResult
    func syncNow(disconnectWhenDone: Bool? = nil, trigger: SyncTrigger,
                 connectTimeout: Duration = .seconds(25)) async throws -> BandSyncer.HealthSyncOutcome {
        if let inFlight {
            log.info("Sync requested (\(trigger.rawValue)) — joining the one in flight")
            return try await inFlight.value
        }
        let task = Task { @MainActor in
            try await self.performSync(disconnectWhenDone: disconnectWhenDone, trigger: trigger,
                                       connectTimeout: connectTimeout)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync(disconnectWhenDone: Bool?, trigger: SyncTrigger,
                             connectTimeout: Duration) async throws -> BandSyncer.HealthSyncOutcome {
        let started = ContinuousClock.now
        log.info("Sync start (\(trigger.rawValue)) — \(DiagnosticLog.appContext())")
        do {
            let outcome = try await connectAndSync(disconnectWhenDone: disconnectWhenDone, connectTimeout: connectTimeout)
            if outcome.deferredUntilUnlock {
                log.info("Sync staged (\(trigger.rawValue)) in \(DiagnosticLog.elapsed(since: started)) — phone locked, \(outcome.sleepSessions) sleep report(s) kept locally until the unlock")
                return outcome
            }
            log.info("Sync done (\(trigger.rawValue)) in \(DiagnosticLog.elapsed(since: started)) — \(outcome.sleepSessions) sleep report(s), \(outcome.healthSamplesWritten) sample(s) written")
            return outcome
        } catch {
            log.error("Sync failed (\(trigger.rawValue)) after \(DiagnosticLog.elapsed(since: started)): \(DiagnosticLog.describe(error))")
            throw error
        }
    }

    private func connectAndSync(disconnectWhenDone: Bool?, connectTimeout: Duration) async throws -> BandSyncer.HealthSyncOutcome {
        // On a cold launch triggered by a task, the UI .onAppear may not have wired deps yet.
        try await awaitDependencies()
        guard let manager, let syncer, let id = syncer.currentDevice?.peripheralIdentifier else {
            throw SyncError.noDeviceRecord
        }

        // A link mid-handshake (the band re-deriving keys) was already up — this sync didn't open it,
        // so it mustn't be the one to drop it.
        let wasConnected = manager.connectionState.isConnected || manager.connectionState.isAuthInProgress
        log.info("Link \(String(describing: manager.connectionState)), last Health sync \(syncer.lastHealthSync?.logStamp ?? "never")")
        if !manager.connectionState.isConnected { try await manager.ensureConnected(identifier: id, timeout: connectTimeout) }

        let shouldDisconnect = disconnectWhenDone ?? !wasConnected
        // userInitiated: false — releasing the active link must NOT stop auto-reconnect, or the band
        // could never wake us again. BandManager re-arms a standing connect on the resulting drop.
        do {
            let outcome = try await syncer.syncToHealth()
            if shouldDisconnect { await releaseLink(manager) }
            return outcome
        } catch {
            if shouldDisconnect { manager.disconnect(userInitiated: false) }
            throw error
        }
    }

    /// A sync's last writes (file ACKs, then the calendar/weather pushes, which can return at once)
    /// go out write-without-response and may still be queued in CoreBluetooth when it returns.
    /// Cancelling the connection on the spot can drop them, and a file whose ACK never reached the
    /// band is offered again on the next connection.
    private func releaseLink(_ manager: BandManager) async {
        try? await Task.sleep(for: .seconds(1))
        manager.disconnect(userInitiated: false)
    }

    /// Called when the band authenticates while the app is in the background — e.g. CoreBluetooth
    /// state restoration relaunched us because the band came back in range. Without this, such a
    /// wake-up would connect but never sync. Throttled and best-effort.
    func syncOnBackgroundWakeIfStale() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return }
        #endif
        // A locked-phone sync that only staged sleep counts too: at night the band can drop and
        // reconnect every few minutes, and each wake would download the same sleep file again.
        let lastRun = [syncer?.lastHealthSync, syncer?.lastStagedSync].compactMap { $0 }.max()
        if let lastRun, Date().timeIntervalSince(lastRun) < autoSyncStaleness {
            log.debug("Background wake — synced recently, skipping")
            return
        }
        let assertion = beginAssertion(name: "bg-wake-sync")
        Task { @MainActor in
            defer { endAssertion(assertion) }
            do {
                // Keep the link up (disconnectWhenDone: false): the band just reached us, so holding
                // the connection is what gives constant background communication (push events: find
                // phone, workout, weather). A later drop re-arms a standing connect on its own.
                let outcome = try await syncNow(disconnectWhenDone: false, trigger: .bleWake)
                log.info("Background-wake sync done — \(outcome.healthSamplesWritten) samples")
            } catch {
                log.error("Background-wake sync failed: \(DiagnosticLog.describe(error))")
            }
        }
    }

    /// The phone was just unlocked, so Apple Health is readable again. First the nights the store kept
    /// while it was locked go to Health (no band needed), then the sync a locked run left owed —
    /// manual samples, workouts, daily details and every ACK. Only reachable while the app is alive
    /// (iOS doesn't wake a suspended app for this); otherwise the next sync with the phone unlocked
    /// does the same.
    func protectedDataBecameAvailable() {
        guard let syncer else { return }
        let assertion = beginAssertion(name: "unlock-sync")
        Task { @MainActor in
            defer { endAssertion(assertion) }
            await syncer.flushPendingSleep()
            guard syncer.hasDeferredSync else { return }
            do {
                _ = try await syncNow(trigger: .unlock, connectTimeout: .seconds(10))
            } catch {
                log.error("Unlock sync failed: \(DiagnosticLog.describe(error))")
            }
        }
    }

    /// Ensures dependencies are wired on a cold, task- or AppIntent-triggered launch.
    private func awaitDependencies() async throws {
        if manager == nil || syncer == nil {
            AppServices.shared.bootstrap(container: My_BandApp.sharedModelContainer)
        }
        for _ in 0..<20 {
            if manager != nil, syncer != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SyncError.noDeviceRecord
    }

    // MARK: - Background task assertion

    #if canImport(UIKit)
    private func beginAssertion(name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }
    private func endAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
    #else
    private func beginAssertion(name: String) -> Int { 0 }
    private func endAssertion(_ id: Int) {}
    #endif
}
