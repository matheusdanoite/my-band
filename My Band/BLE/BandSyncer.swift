import Foundation
import SwiftData
import HealthKit
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
    private(set) var todayWalkingHeartRateAvg: Int?

    private weak var bandManager: BandManager?
    private var modelContext: ModelContext?
    private let log = AppLogger(category: "Sync")
    private let workoutGps   = WorkoutGpsService()
    private let findPhone    = FindPhoneService()
    private let calendarSync = CalendarSyncService()
    private let weatherSync  = WeatherSyncService()
    private var savedWorkoutsByStart: [Int: HKWorkout] = [:]
    private var pendingRecoveryHRByStart: [Int: [WorkoutHRSample]] = [:]

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
        workoutGps.onRecoveryHRRecorded = { [weak self] strengthStart, samples in
            Task { @MainActor in await self?.handleRecoveryHRRecorded(strengthStart: strengthStart, samples: samples) }
        }
    }

    private func handleRecoveryHRRecorded(strengthStart: Date?, samples: [WorkoutHRSample]) async {
        guard !samples.isEmpty else { return }
        let startTs = strengthStart.map { Int($0.timeIntervalSince1970) }
        let matchedWorkout: HKWorkout?
        if let startTs {
            matchedWorkout = savedWorkoutsByStart
                .filter { abs($0.key - startTs) <= 120 }
                .min { abs($0.key - startTs) < abs($1.key - startTs) }?
                .value
            if matchedWorkout == nil {
                pendingRecoveryHRByStart[startTs] = samples
            }
        } else {
            matchedWorkout = nil
        }
        do {
            let count = try await HealthKitManager.shared.writeRecoveryHR(samples, toWorkout: matchedWorkout)
            log.info("Post-workout recovery HR written: \(count) sample(s) (attached=\(matchedWorkout != nil))")
            _ = try? await HealthKitManager.shared.writeHeartRateRecoveries(minutes: [])
        } catch {
            log.error("Post-workout recovery HR write failed: \(error.localizedDescription)")
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
        let today = Calendar.current.startOfDay(for: Date())
        let dayDescriptor = FetchDescriptor<ActivityDay>(predicate: #Predicate { $0.date == today })
        todayWalkingHeartRateAvg = (try? context.fetch(dayDescriptor))?.first?.walkingHeartRateAvg
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
        /// The phone was locked: sleep files were kept locally, nothing went to Health or was ACKed.
        var deferredUntilUnlock = false
    }

    /// Apple Health answers no query while the phone is locked, and every write path queries first
    /// (the sleep write clears the night, the reconciliation reads the iPhone's totals). Hardware log
    /// 2026-10-01…11: 26 of the 27 syncs that reached the band with the phone locked failed on it.
    static var healthReadable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// Set by a sync that only staged sleep (phone locked) and cleared by the next full one, so the
    /// unlock knows a sync is owed. Persisted: the app can be relaunched in between.
    static let deferredSyncKey = "healthSyncDeferredUntilUnlock"
    /// Last sync that only staged sleep — throttles background wakes the way `lastHealthSync` does.
    private(set) var lastStagedSync: Date?

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

        await HealthKitManager.shared.cleanupPre2020CorruptedSamplesIfNeeded()
        await repairSleepHistoryOnce(context: context)
        await rebuildSleepHistoryFromHealthOnce()
        await reparseStoredSleepIfParserChanged(context: context)

        log.info("Health sync started (fetching today's activity files)")
        let fileIds = try await fetchFileIds(manager: manager)
        log.info("Received \(fileIds.count) file ID(s)")

        guard Self.healthReadable else {
            return await stageSleepUntilUnlock(fileIds, manager: manager, context: context)
        }
        await writePendingSleep(context)

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

        // Locked: the workout write would fail on its first query. The files stay un-ACKed on the
        // band and the full sync owed to the unlock lists them again.
        guard Self.healthReadable else {
            log.info("Targeted workout sync deferred — phone locked, \(fileIds.count) file(s) wait for the unlock")
            UserDefaults.standard.set(true, forKey: Self.deferredSyncKey)
            var outcome = HealthSyncOutcome()
            outcome.deferredUntilUnlock = true
            return outcome
        }
        log.info("Targeted workout sync — \(fileIds.count) file(s)")
        let outcome = try await processActivityFiles(fileIds, manager: manager, context: context)
        markSynced(context, clearsDeferral: false)
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

    /// `clearsDeferral`: only a full sync settles what a locked-phone sync left owed.
    private func markSynced(_ context: ModelContext, clearsDeferral: Bool = true) {
        if clearsDeferral { UserDefaults.standard.removeObject(forKey: Self.deferredSyncKey) }
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
        let kind = meta.kindLabel
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
        var sleepBeats: [BeatWindow] = []
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
                    let ingested = ingestSleepFile(fileId, fileData, meta: meta, context: context)
                    sleepToWrite += ingested.sessions
                    sleepVitals += ingested.vitals
                    sleepBeats += ingested.beats
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
                log.error("Failed file \(fileId.hexString): \(DiagnosticLog.describe(error))")
            }
        }

        // Sleep is written (and ACKed) the moment the band is stuck on it, so these live outside route.
        var writtenSleepIds = Set<Data>()

        /// Writes the sleep batch, then ACKs its files. A failed write ACKs nothing: the band re-offers
        /// the files, and the reports already in the store reach Health on the next unlock flush.
        func flushSleep() async -> Bool {
            guard !sleepIds.isEmpty || !sleepToWrite.isEmpty else { return true }
            defer { sleepToWrite = []; sleepVitals = []; sleepBeats = []; sleepIds = [] }
            do {
                if !sleepToWrite.isEmpty {
                    let nights = Self.withStoredReports(sleepToWrite, in: context)
                    if nights.count > sleepToWrite.count {
                        log.info("Sleep write: \(sleepToWrite.count) new report(s) + \(nights.count - sleepToWrite.count) stored report(s) of the same night(s)")
                    }
                    outcome.healthSamplesWritten += try await HealthKitManager.shared.writeSleep(nights)
                    nights.forEach { $0.healthKitSynced = true }
                    outcome.sleepSessions += sleepToWrite.count
                }
                if !sleepVitals.isEmpty {
                    outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(sleepVitals)
                    outcome.minuteSamples += sleepVitals.count
                }
                // Best-effort and before the ACK only by order: the stored file (rawData) can rebuild it,
                // so a failing HRV write mustn't hold the night's ACK hostage.
                outcome.healthSamplesWritten += await writeHRV(sleepBeats)
                sleepIds.forEach { sendAck(fileId: $0, manager: manager) }
                writtenSleepIds.formUnion(sleepIds)
                return true
            } catch {
                log.error("Sleep write failed — \(sleepIds.count) sleep file(s) left un-ACKed for the next sync: \(DiagnosticLog.describe(error))")
                return false
            }
        }

        // A fetch can come back with a different file than the one requested: the band is still
        // pushing one it hasn't had ACKed. That file is complete and CRC-valid, so it is routed like
        // any other, then ACKed to unstick the band — a sleep file only after its night is written:
        // ACKing first lost it from the band while the write was about to fail (hardware, 2026-10-01:
        // four early ACKs, each followed by a locked-phone write failure). Returns false to stop
        // fetching when the band is stuck on a sleep file that can't be written.
        var handled = Set<Data>()
        func fetchEach(_ ids: [Data]) async -> Bool {
            for fileId in ids where !handled.contains(fileId) {
                for _ in 0 ..< 3 {
                    let delivered: (id: Data, data: Data)
                    do {
                        let (id, data) = try await surviveSessionRestart("Fetch \(fileId.hexString)", manager: manager) {
                            try await self.fetchActivityFile(fileId: fileId, manager: manager)
                        }
                        delivered = (id, data)
                    } catch {
                        log.error("Failed file \(fileId.hexString): \(DiagnosticLog.describe(error))")
                        break
                    }
                    if handled.insert(delivered.id).inserted {
                        await route(delivered.id, delivered.data)
                    }
                    if delivered.id == fileId { break }
                    if XiaomiActivityFileMeta(delivered.id)?.isSleep == true {
                        log.warning("Asked for \(fileId.hexString), band sent sleep file \(delivered.id.hexString) — writing it before the ACK that unsticks the band, retrying")
                        if writtenSleepIds.contains(delivered.id) {
                            sendAck(fileId: delivered.id, manager: manager)
                        } else if await !flushSleep() {
                            return false
                        }
                    } else {
                        log.warning("Asked for \(fileId.hexString), band sent \(delivered.id.hexString) — routed it, ACKing to unstick, retrying")
                        sendAck(fileId: delivered.id, manager: manager)
                    }
                }
            }
            return true
        }

        // Sleep first, written and ACKed before anything else is fetched: the band tends to push its
        // pending sleep file whatever is asked for, and it's the file a short background run must not
        // leave behind.
        let isSleepId = { (id: Data) in XiaomiActivityFileMeta(id)?.isSleep == true }
        let bandUnstuck = await fetchEach(fileIds.filter(isSleepId))

        // Local sessions reach disk before any Health write can throw: GetSleepStateIntent reads them,
        // and a background launch can be suspended before SwiftData's autosave runs.
        try? context.save()

        // Isolated from the rest of the batch: a throwing sleep write used to propagate out of here,
        // skipping the manual/workout/daily-detail writes and every ACK after it — so a sleep write
        // that kept failing stalled the whole sync, every sync. Now only the sleep files stay
        // un-ACKed (the band re-offers them) and everything else goes through.
        _ = await flushSleep()
        if bandUnstuck { _ = await fetchEach(fileIds.filter { !isSleepId($0) }) }
        // Sleep files the band pushed unasked while the rest was fetched.
        try? context.save()
        _ = await flushSleep()
        try? context.save()

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
            for (ts, track) in workoutGps.consumeStrengthRoutes() where workoutRoutes[ts] == nil && !track.isEmpty {
                workoutRoutes[ts] = track
            }
            if weatherSync.lastConditions == nil, manager.connectionState.isConnected {
                await weatherSync.pushWeather()
            }
            var weatherMap: [Int: WorkoutWeather] = [:]
            if let wx = weatherSync.lastConditions {
                let cutoff = Date().addingTimeInterval(-24 * 3600)
                for w in workoutsToWrite where w.startDate >= cutoff {
                    weatherMap[Int(w.startDate.timeIntervalSince1970)] = wx
                }
            }
            var endExtension: [Int: TimeInterval] = [:]
            if let pendingStart = workoutGps.recoveryPendingStrengthStart {
                let pendingTs = Int(pendingStart.timeIntervalSince1970)
                for w in workoutsToWrite {
                    let key = Int(w.startDate.timeIntervalSince1970)
                    if abs(key - pendingTs) <= 120 {
                        endExtension[key] = WorkoutGpsService.recoveryDuration
                    }
                }
            }
            let result = try await HealthKitManager.shared.writeWorkouts(
                workoutsToWrite,
                routes: workoutRoutes,
                heartRates: workoutHeartRates,
                weather: weatherMap,
                endExtension: endExtension
            )
            outcome.healthSamplesWritten += result.written
            for (key, hkWorkout) in result.saved {
                savedWorkoutsByStart[key] = hkWorkout
                if let pendingMatch = pendingRecoveryHRByStart.keys.first(where: { abs($0 - key) <= 120 }),
                   let pendingSamples = pendingRecoveryHRByStart.removeValue(forKey: pendingMatch) {
                    _ = try? await HealthKitManager.shared.writeRecoveryHR(pendingSamples, toWorkout: hkWorkout)
                }
            }
            if detailMinutes.isEmpty {
                _ = try? await HealthKitManager.shared.writeHeartRateRecoveries(minutes: [])
            }
        }
        // Workout summary + GPS files: a GPS file can be pending without a parseable summary (its
        // summary was ACKed in an earlier sync), which used to leave it dangling forever.
        workoutIds.forEach { sendAck(fileId: $0, manager: manager) }

        // Daily details last: HR/SpO₂ raw (band-exclusive), and steps/distance/energy reconciled
        // against the iPhone — excluding minutes inside a workout, whose distance/energy the workout
        // samples above already contribute.
        if !detailMinutes.isEmpty {
            persistWalkingHeartRate(detailMinutes, context)
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
    // and clears the stale duplicates. That first pass (V1) ran once.
    //
    // V2 exists because the write path V1 used still truncated nights: it cleared a night's window
    // before rewriting but merged only the reports in hand, so a partial report written after the full
    // one erased the rest of the night — and only a resync of that same night, which never comes for
    // an old one, would have restored it. The store still holds every report, so V2 rewrites each
    // stored night through the latest-report-wins merge. A night Apple Health already holds more of
    // than the store is kept as is (`HealthKitManager.healthHoldsMore`), and implausible stored reports
    // stay out (`isRepairableReport`). Foreground only: it walks the whole history, more than a
    // background task's budget. The flag advances only on success — a failure retries next sync.
    private static let sleepRepairKey = "sleepHistoryRepairedV2"

    private func repairSleepHistoryOnce(context: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: Self.sleepRepairKey) else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else {
            log.info("Sleep history repair pending — waits for a foreground sync")
            return
        }
        #endif
        let stored = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let repairable = stored.filter { Self.isRepairableReport($0) }
        guard !repairable.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
            return
        }
        do {
            let result = try await HealthKitManager.shared.repairSleep(from: repairable)
            log.notice("Sleep history repair (V2): \(result.nights) night(s) rewritten with \(result.written) sample(s), \(result.kept) kept as is — from \(repairable.count) stored report(s), \(stored.count - repairable.count) implausible left out")
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
        } catch {
            log.error("Sleep history repair failed, will retry next sync: \(DiagnosticLog.describe(error))")
        }
    }

    // MARK: - One-time sleep rebuild from Apple Health
    //
    // The repair above only reaches nights the local store still holds, and the store on hardware was
    // recreated on 2026-09-09 — every older night exists only in Apple Health, still stacked with the
    // duplicates of the old identifiers. This collapses those nights in Apple Health itself
    // (`HealthKitManager.rebuildSleepHistoryFromHealth`); it runs after the store-based repair, whose
    // nights come out clean and are skipped. Foreground only, flag advanced only on success.
    private static let sleepRebuildKey = "sleepHistoryRebuiltFromHealthV3"

    private func rebuildSleepHistoryFromHealthOnce() async {
        guard !UserDefaults.standard.bool(forKey: Self.sleepRebuildKey) else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else {
            log.info("Sleep rebuild from Apple Health pending — waits for a foreground sync")
            return
        }
        #endif
        do {
            let result = try await HealthKitManager.shared.rebuildSleepHistoryFromHealth()
            log.notice("Sleep rebuild from Apple Health (V3): \(result.rebuilt) night(s) rebuilt, \(result.replaced) sample(s) replaced by \(result.written); \(result.keptLong) night(s) over 16 h left as is, \(result.clean) already clean")
            UserDefaults.standard.set(true, forKey: Self.sleepRebuildKey)
        } catch {
            log.error("Sleep rebuild from Apple Health failed, will retry next sync: \(DiagnosticLog.describe(error))")
        }
    }

    /// A stored report the repair can rewrite from: a real window of at most a day, not before 2020
    /// and not in the future. Older parser versions stored sessions misread from other layouts.
    static func isRepairableReport(_ session: SleepSession, now: Date = Date()) -> Bool {
        let duration = session.endDate.timeIntervalSince(session.startDate)
        return duration > 0 && duration <= 24 * 3600
            && session.startDate.timeIntervalSince1970 >= 1_577_836_800
            && session.endDate <= now.addingTimeInterval(24 * 3600)
    }

    /// Most recent locally-synced sleep session, for `GetSleepStateIntent` — a pull-based read of
    /// whatever the last sync happened to capture (the band has no "fell asleep"/"woke up" push).
    func mostRecentSleepSession() -> SleepSession? {
        guard let context = modelContext else { return nil }
        return Self.mostRecentSleepSession(in: context)
    }

    /// Ordered by end, not start: each re-sync of a night is stored as its own session with the same
    /// bedtime, so a start-ordered fetch returned an arbitrary copy — often an early, partial one.
    /// Ties go to the latest fetch: the report that closed the night keeps the end of the one before.
    static func mostRecentSleepSession(in context: ModelContext) -> SleepSession? {
        var descriptor = FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.endDate, order: .reverse),
                                                                SortDescriptor(\.fetchedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// `batch` plus every stored session overlapping it, transitively. `writeSleep` clears all of its
    /// own samples inside a night's window before rewriting, so a partial report written alone — after
    /// a fuller one of the same night — erased the rest of that night from Apple Health.
    static func withStoredReports(_ batch: [SleepSession], in context: ModelContext) -> [SleepSession] {
        var all = batch
        var known = Set(batch.map(ObjectIdentifier.init))
        var frontier = batch
        while !frontier.isEmpty {
            var found: [SleepSession] = []
            for session in frontier {
                let start = session.startDate, end = session.endDate
                let overlapping = FetchDescriptor<SleepSession>(
                    predicate: #Predicate { $0.startDate < end && $0.endDate > start }
                )
                for stored in (try? context.fetch(overlapping)) ?? [] where known.insert(ObjectIdentifier(stored)).inserted {
                    found.append(stored)
                }
            }
            all += found
            frontier = found
        }
        return all
    }

    private static func stamp(_ unixSeconds: Int) -> String {
        unixSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(unixSeconds)).logStamp : "—"
    }

    // MARK: - Sleep files: ingest, store, stage

    static func parseSleepFile(_ data: Data, meta: XiaomiActivityFileMeta) -> ParsedSleep {
        meta.isSleepStages ? SleepStagesParser.parse(data, meta: meta) : SleepDetailsParser.parse(data, meta: meta)
    }

    /// Parses, logs and stores one sleep file. Returns the stored reports — an already-known file
    /// comes back as the stored object, so whatever is written for it marks that one synced.
    private func ingestSleepFile(_ fileId: Data, _ fileData: Data, meta: XiaomiActivityFileMeta,
                                 context: ModelContext) -> (sessions: [SleepSession], vitals: [ActivityMinuteSample], beats: [BeatWindow]) {
        let parsed = Self.parseSleepFile(fileData, meta: meta)
        let phaseCount = parsed.sessions.reduce(0) { $0 + $1.phases.count }
        log.info("Sleep file \(fileId.hexString) (subtype=\(meta.subtype) v\(meta.version)): \(parsed.sessions.count) session(s), \(phaseCount) phase(s), \(parsed.heartRates.count) HR, \(parsed.spo2.count) SpO₂\(parsed.hasSpO2Section == false ? " (no SpO₂ section in the header)" : "")")
        log.info("  header bed=\(Self.stamp(parsed.bedTime)) wake=\(Self.stamp(parsed.wakeupTime)) awakeFlag=\(parsed.awakeFlag.map { "\($0)" } ?? "n/a") packets=[\(parsed.packetSummary)]")
        if !parsed.beatWindows.isEmpty {
            log.info("  \(parsed.beatWindows.count) beat-to-beat block(s), \(parsed.beatWindows.reduce(0) { $0 + $1.intervalsMs.count }) interval(s)")
        }
        if parsed.stageRevisions > 0 {
            let check = parsed.finalRevisionMatchesSummary.map { $0 ? "matches" : "DIFFERS from" } ?? "has no"
            log.info("  \(parsed.stageRevisions) stage re-scoring(s), the last kept — it \(check) the band's summary")
        }
        for session in parsed.sessions {
            log.info("  session \(session.startDate.logStamp) → \(session.endDate.logStamp), last phase \(session.phases.last.map { "\($0.type)" } ?? "none")")
        }
        // The stored copy keeps only the report reaching furthest into the night (pruneRawData);
        // this line is still the only record of each report the band sent.
        log.debug("  raw \(fileData.hexString)")

        let stored = parsed.sessions.map {
            storeReport($0, raw: fileData, awakeFlag: parsed.awakeFlag, seenAt: Date(), context)
        }
        // HR/SpO₂ recorded during sleep — written within the sleep window so Apple Health's sleep
        // "Comparisons" tab can correlate them.
        let vitals = parsed.heartRates.map { ActivityMinuteSample(date: $0.date, heartRate: $0.bpm) }
            + parsed.spo2.map { ActivityMinuteSample(date: $0.date, spo2: $0.pct) }
        return (stored, vitals, parsed.beatWindows)
    }

    /// Inserts a freshly parsed report, or refreshes the stored one with the same bytes. A re-fetch of
    /// identical bytes moves `fetchedAt` but not `endDate`: the night stopped growing, which is how
    /// the sleep intent tells the user woke up. The stored phases are replaced by the fresh parse, so
    /// a report stored by an older parser is corrected the next time the band offers it.
    /// `seenAt` nil (a log import) leaves the fetch time alone.
    @discardableResult
    func storeReport(_ session: SleepSession, raw: Data, awakeFlag: Int?, seenAt: Date?,
                     _ context: ModelContext) -> SleepSession {
        let hash = session.rawDataHash
        let sameBytes = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
        let report: SleepSession
        if let existing = try? context.fetch(sameBytes).first {
            existing.startDate = session.startDate
            existing.endDate = session.endDate
            existing.phases = session.phases
            report = existing
        } else {
            session.device = currentDevice
            context.insert(session)
            report = session
        }
        report.awakeFlag = awakeFlag
        if let seenAt { report.fetchedAt = seenAt }
        if report.rawData == nil { report.rawData = raw }
        Self.pruneRawData(ofNightStartingAt: report.startDate, in: context)
        return report
    }

    /// Each sleep file holds everything the earlier reports of its night did, so only the one
    /// reaching furthest keeps its bytes (a long night is ~140 KB; every report of it ~1 MB).
    static func pruneRawData(ofNightStartingAt start: Date, in context: ModelContext) {
        // Filtered here, not in the predicate: an external-storage attribute can live outside the
        // SQLite row, so a store-side nil test on it isn't one to rely on.
        let sameNight = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.startDate == start })
        let reports = ((try? context.fetch(sameNight)) ?? []).filter { $0.rawData != nil }
        guard let keep = reports.max(by: {
            $0.endDate != $1.endDate ? $0.endDate < $1.endDate
                : ($0.fetchedAt ?? .distantPast) < ($1.fetchedAt ?? .distantPast)
        }) else { return }
        for report in reports where report !== keep { report.rawData = nil }
    }

    /// The phone is locked, so Apple Health can't be read: fetch only the sleep files, keep them in
    /// the store (the sleep intent reads it there) and leave everything else — every Health write,
    /// every ACK — to the sync owed to the unlock. The band keeps re-offering what wasn't ACKed.
    private func stageSleepUntilUnlock(_ fileIds: [Data], manager: BandManager,
                                       context: ModelContext) async -> HealthSyncOutcome {
        var outcome = HealthSyncOutcome()
        outcome.deferredUntilUnlock = true
        let sleepIds = fileIds.filter { XiaomiActivityFileMeta($0)?.isSleep == true }
        log.info("Phone locked — keeping \(sleepIds.count) sleep file(s) locally; \(fileIds.count - sleepIds.count) other file(s), Health writes and ACKs wait for the unlock")

        var handled = Set<Data>()
        for fileId in sleepIds where !handled.contains(fileId) {
            let delivered: (id: Data, data: Data)
            do {
                let (id, data) = try await surviveSessionRestart("Fetch \(fileId.hexString)", manager: manager) {
                    try await self.fetchActivityFile(fileId: fileId, manager: manager)
                }
                delivered = (id, data)
            } catch {
                log.error("Failed file \(fileId.hexString): \(DiagnosticLog.describe(error))")
                break
            }
            guard let meta = XiaomiActivityFileMeta(delivered.id), meta.isSleep else {
                // Stuck on a file we won't ACK while locked: nothing else will come through.
                log.warning("Asked for \(fileId.hexString), band sent \(delivered.id.hexString) — left for the unlock")
                break
            }
            if handled.insert(delivered.id).inserted {
                outcome.sleepSessions += ingestSleepFile(delivered.id, delivered.data, meta: meta, context: context).sessions.count
            }
            if delivered.id != fileId {
                log.warning("Asked for \(fileId.hexString), band sent sleep file \(delivered.id.hexString) — kept it, the rest waits for the unlock")
                break
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: Self.deferredSyncKey)
        lastStagedSync = Date()
        return outcome
    }

    /// Every stored report fetched while the phone was locked (or whose write failed) goes to Apple
    /// Health — no band needed, the store has the nights. Reports from before `fetchedAt` existed
    /// were all written when synced, so they never count as pending.
    private func writePendingSleep(_ context: ModelContext) async {
        let pending = Self.pendingSleepReports(in: context)
        guard !pending.isEmpty else { return }
        let nights = Self.withStoredReports(pending, in: context)
        do {
            let written = try await HealthKitManager.shared.writeSleep(nights)
            nights.forEach { $0.healthKitSynced = true }
            try? context.save()
            log.info("Pending sleep written — \(pending.count) report(s) kept while locked, \(written) sample(s)")
        } catch {
            log.error("Pending sleep write failed, will retry: \(DiagnosticLog.describe(error))")
        }
    }

    static func pendingSleepReports(in context: ModelContext) -> [SleepSession] {
        let query = FetchDescriptor<SleepSession>(predicate: #Predicate { !$0.healthKitSynced && $0.fetchedAt != nil })
        return (try? context.fetch(query)) ?? []
    }

    /// Unlock entry point: writes the nights fetched while locked, without the band.
    func flushPendingSleep() async {
        guard !isSyncing, Self.healthReadable, let context = modelContext else { return }
        isSyncing = true
        defer { isSyncing = false }
        try? await HealthKitManager.shared.requestAuthorization()
        await writePendingSleep(context)
    }

    var hasDeferredSync: Bool { UserDefaults.standard.bool(forKey: Self.deferredSyncKey) }

    /// Writes the night's heart rate variability, logs it, and never throws: the stored file can
    /// rebuild it, so it must not fail what it rides along with. Returns the samples written.
    private func writeHRV(_ blocks: [BeatWindow]) async -> Int {
        guard !blocks.isEmpty else { return 0 }
        do {
            let r = try await HealthKitManager.shared.writeHeartRateVariability(blocks)
            let median = r.medianSDNN.map { "\(Int($0.rounded())) ms" } ?? "—"
            log.info("HRV: \(r.minuteValues) minute value(s) (median SDNN \(median)), \(r.respiratoryValues) respiratory rate(s), \(r.seriesWritten) heartbeat series written, \(r.seriesAlreadyThere) already in Health")
            return r.minuteValues + r.respiratoryValues + r.seriesWritten
        } catch {
            log.error("HRV write failed: \(DiagnosticLog.describe(error))")
            return 0
        }
    }

    // MARK: - Re-reading stored sleep files
    //
    // Bump when SleepDetailsParser/SleepStagesParser change what they read from the same bytes: the
    // next foreground sync re-parses every stored file and rewrites its night. 2 = only the last
    // stage re-scoring per night (before, every re-scoring was merged, the earliest winning).
    // 3 = beat-to-beat intervals decoded, so stored nights gain heart rate variability.
    // 4 = v5 headerIdx off-by-one fixed (unlocks overnight SpO₂), <3h finalized short-sleep fallback,
    //     and overnight respiratoryRate derived from RSA beat-to-beat modulation.
    static let sleepParserRevision = 4
    private static let sleepParserRevisionKey = "sleepParserRevisionApplied"

    private func reparseStoredSleepIfParserChanged(context: ModelContext) async {
        guard UserDefaults.standard.integer(forKey: Self.sleepParserRevisionKey) < Self.sleepParserRevision else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else { return }
        #endif
        do {
            let result = try await reparseStoredSleep(context)
            log.notice("Sleep re-parse (parser revision \(Self.sleepParserRevision)): \(result.reports) stored file(s) re-read, \(result.nights) night(s) rewritten")
            UserDefaults.standard.set(Self.sleepParserRevision, forKey: Self.sleepParserRevisionKey)
        } catch {
            log.error("Sleep re-parse failed, will retry next sync: \(DiagnosticLog.describe(error))")
        }
    }

    /// Re-parses every stored sleep file and rewrites the nights they belong to.
    private func reparseStoredSleep(_ context: ModelContext) async throws -> (reports: Int, nights: Int) {
        // No `rawData != nil` predicate — see pruneRawData.
        var reread: [SleepSession] = []
        var vitals: [ActivityMinuteSample] = []
        var beats: [BeatWindow] = []
        for report in (try? context.fetch(FetchDescriptor<SleepSession>())) ?? [] {
            guard let raw = report.rawData, let meta = XiaomiActivityFileMeta(Data(raw.prefix(7))), meta.isSleep else { continue }
            let parsed = Self.parseSleepFile(raw, meta: meta)
            vitals += parsed.heartRates.map { ActivityMinuteSample(date: $0.date, heartRate: $0.bpm) }
                + parsed.spo2.map { ActivityMinuteSample(date: $0.date, spo2: $0.pct) }
            beats += parsed.beatWindows
            guard let fresh = parsed.sessions.first else { continue }
            report.startDate = fresh.startDate
            report.endDate = fresh.endDate
            report.phases = fresh.phases
            report.awakeFlag = parsed.awakeFlag
            reread.append(report)
        }
        if !vitals.isEmpty {
            _ = try? await HealthKitManager.shared.writeMinuteSamples(vitals)
        }
        guard !reread.isEmpty else {
            _ = await writeHRV(beats)
            return (0, 0)
        }
        let nights = Self.withStoredReports(reread, in: context)
        _ = try await HealthKitManager.shared.writeSleep(nights)
        nights.forEach { $0.healthKitSynced = true }
        try? context.save()
        _ = await writeHRV(beats)
        return (reread.count, HealthKitManager.groupOverlapping(nights).count)
    }

    /// Re-reads the sleep files in an exported diagnostic log (its `raw …` lines) and rewrites their
    /// nights in Apple Health — the way back for nights stored before the files themselves were
    /// kept, or already gone from the band. Foreground only (the user picks the file).
    func importSleepFiles(fromLog text: String) async throws -> (files: Int, nights: Int) {
        guard let context = modelContext else { throw SyncError.noDeviceRecord }
        guard !isSyncing else { throw ImportError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }
        try await HealthKitManager.shared.requestAuthorization()

        let files = Self.sleepFiles(inLog: text)
        var reports: [SleepSession] = []
        var vitals: [ActivityMinuteSample] = []
        var beats: [BeatWindow] = []
        for (data, meta) in files {
            let parsed = Self.parseSleepFile(data, meta: meta)
            vitals += parsed.heartRates.map { ActivityMinuteSample(date: $0.date, heartRate: $0.bpm) }
                + parsed.spo2.map { ActivityMinuteSample(date: $0.date, spo2: $0.pct) }
            beats += parsed.beatWindows
            reports += parsed.sessions.map {
                storeReport($0, raw: data, awakeFlag: parsed.awakeFlag, seenAt: nil, context)
            }
        }
        if !vitals.isEmpty {
            _ = try? await HealthKitManager.shared.writeMinuteSamples(vitals)
        }
        guard !reports.isEmpty else {
            _ = await writeHRV(beats)
            return (files.count, 0)
        }
        let nights = Self.withStoredReports(reports, in: context)
        _ = try await HealthKitManager.shared.writeSleep(nights)
        nights.forEach { $0.healthKitSynced = true }
        try? context.save()
        _ = await writeHRV(beats)
        let nightCount = HealthKitManager.groupOverlapping(nights).count
        log.notice("Sleep import from a diagnostic log: \(files.count) file(s), \(nightCount) night(s) rewritten")
        return (files.count, nightCount)
    }

    /// The distinct sleep files in a diagnostic log's `raw …` lines, in log order. A night synced
    /// many times appears many times; each distinct report counts once.
    static func sleepFiles(inLog text: String) -> [(data: Data, meta: XiaomiActivityFileMeta)] {
        var seen = Set<Substring>()
        var files: [(data: Data, meta: XiaomiActivityFileMeta)] = []
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "] Sync:   raw ") else { continue }
            let hex = line[range.upperBound...].prefix { $0.isHexDigit }
            guard hex.count >= 16, seen.insert(hex).inserted,
                  let data = Data(hexString: String(hex)),
                  let meta = XiaomiActivityFileMeta(Data(data.prefix(7))), meta.isSleep else { continue }
            files.append((data, meta))
        }
        return files
    }

    enum ImportError: LocalizedError {
        case syncInProgress
        var errorDescription: String? { "Uma sincronização está em andamento. Tente de novo em instantes." }
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

    private func persistWalkingHeartRate(_ minutes: [ActivityMinuteSample], _ context: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let grouped = Dictionary(grouping: minutes) { cal.startOfDay(for: $0.date) }
        for (day, dayMinutes) in grouped {
            guard let avg = HealthKitManager.walkingHeartRateAverage(dayMinutes) else { continue }
            let descriptor = FetchDescriptor<ActivityDay>(predicate: #Predicate { $0.date == day })
            let existing = (try? context.fetch(descriptor))?.first
            let record = existing ?? ActivityDay(date: day)
            record.walkingHeartRateAvg = avg
            record.device = currentDevice
            if existing == nil { context.insert(record) }
            if day == today { todayWalkingHeartRateAvg = avg }
        }
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

        for id in all {
            guard let meta = XiaomiActivityFileMeta(id) else { continue }
            log.info("  listed \(id.hexString) \(meta.kindLabel) v\(meta.version) \(meta.timestamp.logStamp)")
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
