import Foundation
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sync errors

enum SyncError: LocalizedError {
    case notConnected
    case noDeviceRecord
    case timeout
    case emptyPayload
    case unexpectedResponse
    case crcMismatch
    case fileIdMismatch
    case sessionRestarted

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Band not connected."
        case .noDeviceRecord:     return "Device not registered. Authenticate first."
        case .timeout:            return "Timed out during sync."
        case .emptyPayload:       return "No data received from the band."
        case .unexpectedResponse: return "Unexpected response from the band."
        case .crcMismatch:        return "Invalid CRC-32 in the activity file."
        case .fileIdMismatch:     return "The received file does not match the requested one."
        case .sessionRestarted:   return "The band restarted the session in the middle of the sync."
        }
    }
}

// MARK: - Activity file receiver
//
// Reassembles chunked activity data sent by the band on characteristic 0053.
// Each chunk: [totalChunks: UInt16 LE][currentChunk: UInt16 LE][data...]
// The complete file has a CRC-32 in its last 4 bytes.

private final class ActivityFileReceiver {

    private var buffer = Data()
    private(set) var expectedTotal: Int = 0
    private(set) var receivedCount: Int = 0
    private var complete = false
    private var started = false
    /// Last time the band sent anything for this fetch — drives the idle timeout.
    private(set) var lastActivity = ContinuousClock.now

    /// Completion is signalled by the LAST chunk (num == total), matching GadgetBridge
    /// XiaomiActivityFileFetcher.addChunk — more robust than counting received chunks.
    var isComplete: Bool { complete }

    func addChunk(_ payload: Data) {
        lastActivity = ContinuousClock.now
        // payload (decrypted): [total: UInt16 LE][num: UInt16 LE][data...]
        guard payload.count >= 4 else { return }
        let base    = payload.startIndex
        let total   = Int(payload[base]) | (Int(payload[base + 1]) << 8)
        let current = Int(payload[base + 2]) | (Int(payload[base + 3]) << 8)

        if current == 1 {
            buffer = Data()
            expectedTotal = total
            receivedCount = 0
            complete = false
            started = true
        }

        // Ignore tail chunks of a previous file's transfer that arrive before this file's first
        // chunk — appending them mid-stream would corrupt the buffer and shift every record.
        guard started else { return }

        buffer.append(payload.dropFirst(4))
        receivedCount += 1
        if current == total { complete = true }
    }

    func assembled() -> Data { buffer }
    var chunkProgress: String { "\(receivedCount)/\(expectedTotal)" }

    func reset() {
        buffer = Data()
        expectedTotal = 0
        receivedCount = 0
        complete = false
        started = false
    }

    // CRC-32 validation (last 4 bytes of assembled file). Shares the canonical implementation in
    // Checksums (same poly/init/xorout) — no separate copy here.
    func validateCRC() -> Bool {
        let data = buffer
        guard data.count >= 4 else { return false }
        let body      = data.dropLast(4)
        let storedCRC = UInt32(data[data.count - 4]) |
                       (UInt32(data[data.count - 3]) << 8) |
                       (UInt32(data[data.count - 2]) << 16) |
                       (UInt32(data[data.count - 1]) << 24)
        return Checksums.crc32(Data(body)) == storedCRC
    }
}

// MARK: - BandSyncer
//
// Health data synchronisation with Mi Band 10.
//
// Fetch flow (from GadgetBridge XiaomiHealthService):
//   1. Send health cmd type=8 subtype=1 (CMD_ACTIVITY_FETCH_TODAY)
//   2. Band responds: Command { health { activityRequestFileIds: <7-byte IDs concatenated> } }
//   3. For each 7-byte file ID, send health cmd type=8 subtype=3 (CMD_ACTIVITY_FETCH_REQUEST)
//   4. Band streams chunks to activity characteristic (0053)
//   5. Reassemble, CRC-32 validate, parse sleep/HR/steps
//   6. Send ACK: health cmd type=8 subtype=5 (CMD_ACTIVITY_FETCH_ACK) with file ID

@Observable
@MainActor
final class BandSyncer {

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastHealthSync: Date?
    private(set) var lastError: Error?
    private(set) var currentDevice: BandDevice?

    private weak var bandManager: BandManager?
    private var modelContext: ModelContext?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Sync")
    private let workoutGps   = WorkoutGpsService()
    private let findPhone    = FindPhoneService()
    private let calendarSync = CalendarSyncService()
    private let weatherSync  = WeatherSyncService()

    /// Live only while a command/response exchange is pending; BandManager.onSessionRestart yields
    /// into it so the exchange fails fast instead of waiting out its timeout.
    private var sessionRestartSignal: AsyncStream<Void>.Continuation?
    /// Re-sends allowed per exchange. The band restarts once after the post-auth init; the manager
    /// itself gives up and drops the link past its own limit of 3.
    private static let maxRestartRetries = 3
    /// A file fetch fails after this long without a chunk — not after a fixed total, which a large
    /// file (a night of sleep, with its HR/SpO₂ sections) can legitimately need.
    private static let fileIdleTimeout: Duration = .seconds(10)

    // MARK: - Setup

    func setup(manager: BandManager, context: ModelContext) {
        bandManager = manager
        modelContext = context

        manager.onAuthenticated = { [weak self] name, peripheralID in
            Task { @MainActor in
                guard let self else { return }
                self.persistDevice(name: name, peripheralIdentifier: peripheralID)
                // A background (state-restoration) wake authenticates but has nothing driving a
                // sync; kick one if data is stale. No-op in the foreground.
                BackgroundSyncManager.shared.syncOnBackgroundWakeIfStale()
            }
        }

        manager.onSessionRestart = { [weak self] in self?.sessionRestartSignal?.yield() }

        workoutGps.setup(manager: manager)
        findPhone.setup(manager: manager)
        calendarSync.setup(manager: manager)
        weatherSync.setup(manager: manager)

        workoutGps.onWorkoutFinished = { [weak self] fileIds in
            Task { @MainActor in await self?.handleWorkoutFinished(fileIds) }
        }
    }

    // MARK: - Post-workout sync
    //
    // The band needs a moment to flush the activity file before its id shows up, so wait first; skip
    // if a sync is already running. Fired from a background BLE callback, iOS would suspend the app
    // within seconds, so the wait + sync run inside a background task assertion (≈30 s).

    private func handleWorkoutFinished(_ fileIds: Data) async {
        guard !isSyncing else { return }
        let bg = beginBackgroundAssertion(name: "post-workout-sync")
        defer { endBackgroundAssertion(bg) }
        try? await Task.sleep(for: .seconds(8))
        guard bandManager?.connectionState.isConnected == true else { return }
        do {
            // The band hands us the just-recorded file ids in workoutStatusWatch, so fetch exactly
            // those — skipping the FETCH_TODAY/PAST listing. Older firmware that omits the ids falls
            // back to a full sync. (Daily totals, which a workout also bumps, are left for the next
            // regular/background sync.)
            let ids = Self.splitFileIds(fileIds)
            if ids.isEmpty {
                log.info("Workout finished (no file ids) — running full Apple Health sync")
                try await syncToHealth()
            } else {
                log.info("Workout finished — fetching \(ids.count) named workout file(s)")
                try await syncWorkoutFiles(ids)
            }
        } catch {
            log.error("Post-workout sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Background task assertion

    #if canImport(UIKit)
    private func beginBackgroundAssertion(name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }
    private func endBackgroundAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
    #else
    private func beginBackgroundAssertion(name: String) -> Int { 0 }
    private func endBackgroundAssertion(_ id: Int) {}
    #endif

    // MARK: - Device persistence

    func persistDevice(name: String, peripheralIdentifier: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BandDevice>(
            predicate: #Predicate { $0.peripheralIdentifier == peripheralIdentifier }
        )
        if let existing = try? context.fetch(descriptor), let device = existing.first {
            device.name = name
            currentDevice = device
        } else {
            let device = BandDevice(name: name, peripheralIdentifier: peripheralIdentifier)
            context.insert(device)
            currentDevice = device
        }
        try? context.save()
        log.info("Device persisted: \(name)")
    }

    func loadStoredDevice() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BandDevice>(
            sortBy: [SortDescriptor(\.addedDate, order: .reverse)]
        )
        currentDevice = (try? context.fetch(descriptor))?.first
        lastHealthSync = currentDevice?.lastHealthSyncDate
        lastSyncDate = currentDevice?.lastSyncDate
    }

    // MARK: - Apple Health sync
    //
    // Fetches today's activity files and routes each by its file-id metadata:
    //   sleep         → SleepDetailsParser   → HealthKit sleepAnalysis (+ SwiftData)
    //   daily summary → DailySummaryParser   → HealthKit HR/SpO₂ extremes (+ ActivityDay)
    //   daily details → DailyDetailsParser   → HealthKit per-minute HR/SpO₂ (raw) +
    //                                           steps/distance/energy (reconciled vs iPhone)
    // Each file is ACKed so the band marks it synced.

    struct HealthSyncOutcome {
        var sleepSessions = 0
        var dailySummaries = 0
        var minuteSamples = 0
        var manualSamples = 0
        var workouts = 0
        var healthSamplesWritten = 0
    }

    @discardableResult
    func syncToHealth() async throws -> HealthSyncOutcome {
        // Re-entrancy guard. The guard + flag set run synchronously before the first await, so the
        // @MainActor serialises overlapping triggers (manual button, BGTask, background-wake) into
        // a single run — the rest see the flag and bail.
        guard !isSyncing else { return HealthSyncOutcome() }
        // Mid-handshake counts: the band re-deriving keys under a live link is routine, and every
        // exchange waits for it to settle (surviveSessionRestart).
        guard let manager = bandManager,
              manager.connectionState.isConnected || manager.connectionState.isAuthInProgress else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch {
            lastError = error
            throw error
        }

        await repairSleepHistoryOnce(context: context)

        log.info("Health sync started (fetching today's activity files)")
        let fileIds = try await fetchFileIds(manager: manager)
        log.info("Received \(fileIds.count) file ID(s)")

        let outcome = try await processActivityFiles(fileIds, manager: manager, context: context)
        markSynced(context)

        log.info("Health sync done — \(outcome.healthSamplesWritten) samples written")

        // Push phone-side config (language, calendar, reminders) as part of the same sync, while
        // the link is up. Best-effort: a failure here must not fail the health sync.
        if manager.connectionState.isConnected {
            await calendarSync.pushAll()
        }
        if manager.connectionState.isConnected {
            await weatherSync.pushWeather()
        }

        return outcome
    }

    // MARK: - Targeted post-workout sync
    //
    // Pulls exactly the activity files the band named in workoutStatusWatch (the summary + GPS
    // track of the session just finished) into Apple Health, skipping the FETCH_TODAY/FETCH_PAST
    // listing. Daily totals — which a workout also bumps — are left for the next regular sync.

    @discardableResult
    func syncWorkoutFiles(_ fileIds: [Data]) async throws -> HealthSyncOutcome {
        guard !isSyncing else { return HealthSyncOutcome() }
        // Mid-handshake counts: the band re-deriving keys under a live link is routine, and every
        // exchange waits for it to settle (surviveSessionRestart).
        guard let manager = bandManager,
              manager.connectionState.isConnected || manager.connectionState.isAuthInProgress else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }
        guard !fileIds.isEmpty else { return HealthSyncOutcome() }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch {
            lastError = error
            throw error
        }

        log.info("Targeted workout sync — \(fileIds.count) file(s)")
        let outcome = try await processActivityFiles(fileIds, manager: manager, context: context)
        markSynced(context)
        log.info("Targeted workout sync done — \(outcome.healthSamplesWritten) samples written")
        return outcome
    }

    /// Splits a concatenated activity-file-id blob (each id is 7 bytes) into individual ids,
    /// dropping the placeholder ids the band can list with no timestamp and no version —
    /// GadgetBridge skips them too; fetching one only burns a timeout.
    static func splitFileIds(_ raw: Data) -> [Data] {
        guard !raw.isEmpty, raw.count % 7 == 0 else { return [] }
        return stride(from: raw.startIndex, to: raw.endIndex, by: 7)
            .map { Data(raw[$0 ..< $0 + 7]) }
            .filter { id in
                guard let meta = XiaomiActivityFileMeta(id) else { return false }
                return !(meta.timestamp.timeIntervalSince1970 == 0 && meta.version == 0)
            }
    }

    private func markSynced(_ context: ModelContext) {
        try? context.save()
        let now = Date()
        currentDevice?.lastHealthSyncDate = now
        currentDevice?.lastSyncDate = now
        lastHealthSync = now
        lastSyncDate = now
        try? context.save()
    }

    // MARK: - Activity file processing
    //
    // Fetches, parses, writes-to-Health, and ACKs each of `fileIds`. Shared by the full sync (ids
    // discovered via FETCH_TODAY/PAST) and the targeted post-workout sync (ids handed over by
    // workoutStatusWatch). Inserts SwiftData records; the caller persists via markSynced.
    //
    // ACK is sent only after the corresponding HealthKit write is confirmed, and for EVERY file that
    // was fetched — not only the ones that produced writable samples — so a file that parses to
    // nothing (or whose sibling already synced) doesn't get re-offered forever. The daily summary is
    // written and ACK'd inline; sleep, manual, workout, and daily-detail files are batched, so their
    // ACKs go out after the batch write (daily details are batched so the reconciliation can exclude
    // workout-covered minutes). If a write throws or the app is killed before ACKs are sent, the band
    // re-offers those files on the next connection — no data is lost.

    #if DEBUG
    /// Prints one copy-pasteable fixture block per activity file to the console.
    /// Uses `print` (not `Logger`) so the full hex is emitted untruncated and unredacted.
    private func dumpActivityFileFixture(fileId: Data, meta: XiaomiActivityFileMeta, data: Data) {
        let kind: String
        switch true {
        case meta.isWorkoutSummary: kind = "workout-summary"
        case meta.isWorkoutGps:     kind = "workout-gps"
        case meta.isSleep:          kind = "sleep"
        case meta.isManualSamples:  kind = "manual"
        case meta.isDailySummary:   kind = "daily-summary"
        case meta.isDailyDetails:   kind = "daily-details"
        default:                    kind = "unknown"
        }
        let iso = ISO8601DateFormatter().string(from: meta.timestamp)
        print("""
        ===== FIXTURE BEGIN =====
        kind=\(kind) subtype=\(meta.subtype) detail=\(meta.detail) version=\(meta.version) ts=\(iso) bytes=\(data.count)
        id=\(fileId.hexString)
        data=\(data.hexString)
        ===== FIXTURE END =====
        """)
    }
    #endif

    private func processActivityFiles(_ fileIds: [Data],
                                      manager: BandManager,
                                      context: ModelContext) async throws -> HealthSyncOutcome {
        var outcome = HealthSyncOutcome()
        var sleepToWrite: [SleepSession] = []
        var sleepVitals: [ActivityMinuteSample] = []
        var manualToWrite: [ManualSample] = []
        var workoutsToWrite: [WorkoutSummary] = []
        var workoutRoutes: [Int: [WorkoutTrackPoint]] = [:]
        var workoutHeartRates: [Int: [WorkoutHRSample]] = [:]

        var detailMinutes: [ActivityMinuteSample] = []

        var sleepIds:   [Data] = []
        var manualIds:  [Data] = []
        var workoutIds: [Data] = []
        var detailIds:  [Data] = []

        // Routes one fetched, CRC-valid file into its batch (or writes and ACKs it inline).
        func route(_ fileId: Data, _ fileData: Data) async {
            guard let meta = XiaomiActivityFileMeta(fileId) else { return }

            do {
                #if DEBUG
                // Fixture capture: the full reassembled activity file, before any parser
                // touches it. Sync against real hardware, then copy these blocks from the
                // Xcode console into the test target's fixtures. Remove once captured.
                dumpActivityFileFixture(fileId: fileId, meta: meta, data: fileData)
                #endif

                if meta.isManualSamples {
                    let manual = ManualSamplesParser.parse(fileData, meta: meta)
                    manualToWrite += manual
                    outcome.manualSamples += manual.count
                    manualIds.append(fileId)
                } else if meta.isWorkoutSummary {
                    if let workout = WorkoutSummaryParser.parse(fileData, meta: meta) {
                        workoutsToWrite.append(workout)
                    }
                    workoutIds.append(fileId)
                } else if meta.isWorkoutGps {
                    let track = WorkoutGpsParser.parse(fileData, meta: meta)
                    if !track.isEmpty {
                        workoutRoutes[Int(meta.timestamp.timeIntervalSince1970)] = track
                    }
                    workoutIds.append(fileId)
                } else if meta.isWorkoutDetails {
                    // Per-second HR series recorded during the workout. Attached to the matching
                    // HKWorkout below (keyed by the session-start timestamp, like the GPS route).
                    let hr = WorkoutDetailsParser.parse(fileData, meta: meta)
                    if !hr.isEmpty {
                        workoutHeartRates[Int(meta.timestamp.timeIntervalSince1970)] = hr
                        log.info("Workout HR detail: \(hr.count) sample(s) for session at \(meta.timestamp.description)")
                    }
                    workoutIds.append(fileId)
                } else if meta.isSleep {
                    let parsed = meta.isSleepStages
                        ? SleepStagesParser.parse(fileData, meta: meta)
                        : SleepDetailsParser.parse(fileData, meta: meta)
                    let phaseCount = parsed.sessions.reduce(0) { $0 + $1.phases.count }
                    log.info("Sleep file \(fileId.hexString) (subtype=\(meta.subtype) v\(meta.version)): \(parsed.sessions.count) session(s), \(phaseCount) phase(s), \(parsed.heartRates.count) HR, \(parsed.spo2.count) SpO₂")
                    for session in parsed.sessions {
                        // Always (re)write to HealthKit — its sync-identifier dedup makes this
                        // idempotent, so data deleted from Apple Health is restored on re-sync.
                        // SwiftData insertion is still gated to avoid duplicate local records.
                        _ = persistIfNew(session, context)
                        sleepToWrite.append(session)
                    }
                    // HR/SpO₂ recorded during sleep — written within the sleep window so
                    // Apple Health's sleep "Comparisons" tab can correlate them.
                    sleepVitals += parsed.heartRates.map { ActivityMinuteSample(date: $0.date, heartRate: $0.bpm) }
                    sleepVitals += parsed.spo2.map { ActivityMinuteSample(date: $0.date, spo2: $0.pct) }
                    sleepIds.append(fileId)
                } else if meta.isDailySummary {
                    if let summary = DailySummaryParser.parse(fileData, meta: meta) {
                        outcome.dailySummaries += 1
                        persistActivityDay(summary, context)
                        outcome.healthSamplesWritten += try await HealthKitManager.shared.writeDailySummary(summary)
                    }
                    sendAck(fileId: fileId, manager: manager)
                } else if meta.isDailyDetails {
                    // Batched (not written inline) so the reconciliation can exclude minutes covered
                    // by a workout — those file ids are only fully known after the loop.
                    let minutes = DailyDetailsParser.parse(fileData, meta: meta)
                    outcome.minuteSamples += minutes.count
                    detailMinutes += minutes
                    detailIds.append(fileId)
                } else {
                    // No parser matches this file. We still ACK it so the band stops re-offering it on
                    // every connection (one such file was 12 KB, re-downloaded each sync forever). This
                    // mirrors GadgetBridge, whose fetcher ACKs every fetched file BEFORE creating a parser
                    // and discards whatever has none. Inline ACK is safe: we only reach here after
                    // fetchActivityFile returned without throwing, so the "ACK only after a successful
                    // fetch" invariant holds. (Workout per-second detail — sports/details — is handled
                    // above by isWorkoutDetails; an unknown future subtype/version lands here.)
                    log.info("No parser for file \(fileId.hexString) (type=\(String(describing: meta.type)) subtype=\(meta.subtype) detail=\(String(describing: meta.detail))) — ACKing to stop re-offering")
                    sendAck(fileId: fileId, manager: manager)
                }
            } catch {
                log.error("Failed file \(fileId.hexString): \(error.localizedDescription)")
            }
        }

        // A fetch can come back with a different file than the one requested: the band is still
        // pushing one it hasn't had ACKed. That file is complete and CRC-valid, so it is routed like
        // any other, then ACKed at once to unstick the band. It used to be ACKed unread, silently
        // discarding whatever it held — a night's sleep file, the largest, is the likeliest one to be
        // caught mid-stream. The early ACK's only exposure is a batch write failing later in this sync.
        var handled = Set<Data>()
        for fileId in fileIds where !handled.contains(fileId) {
            for _ in 0 ..< 3 {
                let delivered: (id: Data, data: Data)
                do {
                    let (id, data) = try await surviveSessionRestart("Fetch \(fileId.hexString)", manager: manager) {
                        try await self.fetchActivityFile(fileId: fileId, manager: manager)
                    }
                    delivered = (id, data)
                } catch {
                    log.error("Failed file \(fileId.hexString): \(error.localizedDescription)")
                    break
                }
                if handled.insert(delivered.id).inserted {
                    await route(delivered.id, delivered.data)
                }
                if delivered.id == fileId { break }
                log.warning("Asked for \(fileId.hexString), band sent \(delivered.id.hexString) — routed it, ACKing to unstick, retrying")
                sendAck(fileId: delivered.id, manager: manager)
            }
        }

        // Isolated from the rest of the batch: a throwing sleep write used to propagate out of here,
        // skipping the manual/workout/daily-detail writes and every ACK after it — so a sleep write
        // that kept failing stalled the whole sync, every sync. Now only the sleep files stay
        // un-ACKed (the band re-offers them) and everything else goes through.
        do {
            if !sleepToWrite.isEmpty {
                outcome.healthSamplesWritten += try await HealthKitManager.shared.writeSleep(sleepToWrite)
                outcome.sleepSessions = sleepToWrite.count
            }
            if !sleepVitals.isEmpty {
                outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(sleepVitals)
                outcome.minuteSamples += sleepVitals.count
            }
            // Sleep files ACK'd after both sessions and vitals are written.
            sleepIds.forEach { sendAck(fileId: $0, manager: manager) }
        } catch {
            log.error("Sleep write failed — \(sleepIds.count) sleep file(s) left un-ACKed for the next sync: \(error.localizedDescription)")
        }

        // ACK every file we successfully fetched — NOT gated on the write batch being non-empty.
        // A fetched file that parsed to nothing (or whose sibling already synced) still has to be
        // ACKed, otherwise the band re-offers it forever and shows it as "not synced". The ACK runs
        // after the write so a thrown write skips it (the band then re-offers — no data loss). Only
        // files that fetched without throwing reach the *Ids arrays.
        if !manualToWrite.isEmpty {
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeManualSamples(manualToWrite)
        }
        manualIds.forEach { sendAck(fileId: $0, manager: manager) }

        if !workoutsToWrite.isEmpty {
            outcome.workouts = workoutsToWrite.count
            let result = try await HealthKitManager.shared.writeWorkouts(workoutsToWrite, routes: workoutRoutes, heartRates: workoutHeartRates)
            outcome.healthSamplesWritten += result.written
        }
        // Workout summary + GPS files: a GPS file can be pending without a parseable summary (its
        // summary was ACKed in an earlier sync), which used to leave it dangling forever.
        workoutIds.forEach { sendAck(fileId: $0, manager: manager) }

        // Daily details last: HR/SpO₂ raw (band-exclusive), and steps/distance/energy reconciled
        // against the iPhone — excluding minutes inside a workout, whose distance/energy the workout
        // samples above already contribute.
        if !detailMinutes.isEmpty {
            let workoutWindows = workoutsToWrite.map { (start: $0.startDate, end: $0.endDate) }
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(detailMinutes)
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeReconciledActivity(detailMinutes, excludingWorkouts: workoutWindows)
            // Cardio Recovery: pairs recent workouts already in Health with the post-workout
            // per-minute HR this batch carries. Best-effort — must not block the ACKs below.
            do {
                outcome.healthSamplesWritten += try await HealthKitManager.shared.writeHeartRateRecoveries(minutes: detailMinutes)
            } catch {
                log.error("Cardio recovery write failed: \(error.localizedDescription)")
            }
        }
        detailIds.forEach { sendAck(fileId: $0, manager: manager) }

        return outcome
    }

    // MARK: - One-time sleep history repair
    //
    // `HealthKitManager.writeSleep` used to key each phase's sync identifier on its exact
    // (start, end) pair. A resync of a still-in-progress night reports the same real segment with
    // a later end, so the identifier changed and the old, shorter write was never superseded —
    // years of nights ended up with overlapping, double-counted stage/in-bed records in Apple
    // Health. The write path is now stable/self-healing, but it can only clean up a night the next
    // time that night's data happens to be resynced. This repairs everything already on disk in
    // one pass: local SwiftData still holds every synced `SleepSession` (unlike Apple Health, its
    // `rawDataHash` dedup doesn't collapse multiple files for the same overlapping night), so
    // feeding the *entire* history back through the fixed `writeSleep` groups and re-sanitizes it
    // and clears the stale duplicates. Runs once, gated by a flag, and only advances that flag on
    // success — a failure just retries on the next sync.
    private static let sleepRepairKey = "sleepHistoryRepairedV1"

    private func repairSleepHistoryOnce(context: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: Self.sleepRepairKey) else { return }
        let all = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        guard !all.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
            return
        }
        do {
            let written = try await HealthKitManager.shared.writeSleep(all)
            log.info("One-time sleep history repair: rewrote \(written) samples from \(all.count) local session(s)")
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
        } catch {
            log.error("Sleep history repair failed, will retry next sync: \(error.localizedDescription)")
        }
    }

    /// Most recent locally-synced sleep session, for `GetSleepStateIntent` — a pull-based read of
    /// whatever the last sync happened to capture (the band has no "fell asleep"/"woke up" push).
    func mostRecentSleepSession() -> SleepSession? {
        guard let context = modelContext else { return nil }
        var descriptor = FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func persistIfNew(_ session: SleepSession, _ context: ModelContext) -> Bool {
        let hash = session.rawDataHash
        let dup = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
        guard (try? context.fetch(dup))?.isEmpty ?? true else { return false }
        session.device = currentDevice
        context.insert(session)
        return true
    }

    private func persistActivityDay(_ summary: DailySummary, _ context: ModelContext) {
        let day = Calendar.current.startOfDay(for: summary.date)
        let descriptor = FetchDescriptor<ActivityDay>(predicate: #Predicate { $0.date == day })
        let existing = (try? context.fetch(descriptor))?.first
        let record = existing ?? ActivityDay(date: summary.date)
        record.steps = summary.steps
        record.calories = Double(summary.caloriesKcal)
        record.device = currentDevice
        if existing == nil { context.insert(record) }
    }

    // MARK: - Band session restarts
    //
    // Right after the post-auth init the band reopens its session and re-derives keys (see
    // BandManager.handleSessionConfigResponse). A command sent across that boundary is transport-
    // ACKed and silently dropped, so its reply never comes. A sync that opened the link itself sends
    // FETCH_TODAY straight into that window — ensureConnected resolves on the first auth — and a lost
    // listing used to time out and take the whole sync down with it. Each exchange now fails fast on
    // the restart signal and is re-sent once the new session is up.

    private func surviveSessionRestart<T>(_ label: String, manager: BandManager,
                                          _ exchange: () async throws -> T) async throws -> T {
        var restarts = 0
        while true {
            try await manager.awaitSession()
            do {
                return try await exchange()
            } catch SyncError.sessionRestarted where restarts < Self.maxRestartRetries {
                restarts += 1
                log.warning("\(label) cut short by a band session restart — re-sending after re-auth (\(restarts)/\(Self.maxRestartRetries))")
            }
        }
    }

    /// Yields once if the band restarts its session while the calling exchange is pending.
    private func watchSessionRestart() -> AsyncStream<Void> {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        sessionRestartSignal?.finish()
        sessionRestartSignal = cont
        return stream
    }

    private func endSessionRestartWatch() {
        sessionRestartSignal?.finish()
        sessionRestartSignal = nil
    }

    // MARK: - Private: request file IDs
    //
    // Full sync mirrors GadgetBridge: first FETCH_TODAY (today's pending records), then
    // FETCH_PAST (the backlog of older days not yet synced). Both lists are merged so the
    // app reprocesses every record the band still holds — not just the current day.

    private func fetchFileIds(manager: BandManager) async throws -> [Data] {
        var all: [Data] = []
        var seen = Set<Data>()
        func merge(_ ids: [Data]) {
            for id in ids where !seen.contains(id) { seen.insert(id); all.append(id) }
        }

        let today = try await surviveSessionRestart("FETCH_TODAY", manager: manager) {
            try await self.requestFileIds(subtype: XiaomiHealthCmd.fetchToday,
                                          proto: XiaomiProto.fetchTodayCommand(),
                                          manager: manager)
        }
        log.info("FETCH_TODAY → \(today.count) file ID(s)")
        merge(today)

        // The backlog is best-effort: an empty response or timeout shouldn't abort the sync.
        do {
            let past = try await surviveSessionRestart("FETCH_PAST", manager: manager) {
                try await self.requestFileIds(subtype: XiaomiHealthCmd.fetchPast,
                                              proto: XiaomiProto.fetchPastCommand(),
                                              manager: manager)
            }
            log.info("FETCH_PAST → \(past.count) file ID(s)")
            merge(past)
        } catch {
            log.warning("FETCH_PAST failed (\(error.localizedDescription)) — using today's files only")
        }

        return all
    }

    /// Sends one fetch command and waits for the matching Command response (same type+subtype),
    /// returning its file IDs. An empty list is a valid response and completes the wait.
    private func requestFileIds(subtype: UInt32, proto: Data, manager: BandManager) async throws -> [Data] {
        try await withThrowingTaskGroup(of: [Data].self) { group in
            let (stream, cont) = AsyncStream<Data>.makeStream()

            // File IDs come back as a proto Command on 0051, not as activity chunks on 0053.
            manager.onProtoCommandReceived = { data in cont.yield(data) }
            let restarts = watchSessionRestart()
            defer {
                manager.onProtoCommandReceived = nil
                cont.finish()
                endSessionRestartWatch()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask { @MainActor in
                for await _ in restarts { throw SyncError.sessionRestarted }
                throw CancellationError()
            }

            // Pinned to the main actor: the proto callback delivers on .main and the parsers are
            // main-actor-isolated (module default), so processing here keeps it all on one actor.
            group.addTask { @MainActor in
                for await chunk in stream {
                    if let ids = self.extractFileIds(from: chunk, subtype: subtype) { return ids }
                }
                return []
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw SyncError.timeout
            }

            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private func extractFileIds(from protoBytes: Data, subtype: UInt32) -> [Data]? {
        // Expect Command { type=8, subtype=<requested>, health { activityRequestFileIds } }.
        // An empty list still matches (no pending records) and completes the wait.
        guard let cmd = XiaomiProto.parseCommand(protoBytes),
              cmd.type == XiaomiHealthCmd.cmdType,
              cmd.subtype == subtype else { return nil }
        let raw = cmd.health.activityRequestFileIds
        guard raw.count % 7 == 0 else { return nil }
        return Self.splitFileIds(raw)
    }

    // MARK: - Private: fetch individual activity file

    private func fetchActivityFile(fileId: Data, manager: BandManager) async throws -> (Data, Data) {
        let proto = XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.fetchRequest, fileIds: fileId)

        return try await withThrowingTaskGroup(of: (Data, Data).self) { group in
            let receiver = ActivityFileReceiver()
            let (stream, cont) = AsyncStream<Data>.makeStream()

            manager.onActivityChunkReceived = { data in cont.yield(data) }
            let restarts = watchSessionRestart()
            defer {
                manager.onActivityChunkReceived = nil
                cont.finish()
                endSessionRestartWatch()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask { @MainActor in
                for await _ in restarts { throw SyncError.sessionRestarted }
                throw CancellationError()
            }

            let log = self.log
            // Pinned to the main actor: chunks arrive on .main and ActivityFileReceiver is
            // main-actor-isolated (module default). Reassembly/CRC are light, so staying on main is fine.
            group.addTask { @MainActor in
                for await chunk in stream {
                    receiver.addChunk(chunk)
                    log.debug("Activity chunk \(receiver.chunkProgress) (\(chunk.count)B)")
                    if receiver.isComplete {
                        guard receiver.validateCRC() else { throw SyncError.crcMismatch }
                        let file = receiver.assembled()
                        guard file.count >= 7 else { throw SyncError.fileIdMismatch }
                        let actualId = Data(file.prefix(7))
                        return (actualId, file)
                    }
                }
                throw SyncError.emptyPayload
            }
            group.addTask { @MainActor in
                while true {
                    try await Task.sleep(for: .seconds(1))
                    if ContinuousClock.now - receiver.lastActivity > Self.fileIdleTimeout {
                        throw SyncError.timeout
                    }
                }
            }

            guard let result = try await group.next() else { throw SyncError.emptyPayload }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: ACK file

    private func sendAck(fileId: Data, manager: BandManager) {
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.ackCommand(fileId: fileId))
        log.debug("ACK sent for file \(fileId.hexString)")
    }
}
