import Foundation
import HealthKit
import CoreLocation
import OSLog

// MARK: - HealthKitManager
//
// Writes Mi Band data to Apple Health. Deduplication uses HKMetadataKeySyncIdentifier +
// HKMetadataKeySyncVersion: re-saving a sample with the same identifier and an equal/greater
// version replaces the existing one instead of creating a duplicate — so re-syncing is safe.
//
// Cross-source reconciliation (steps / distance / active energy). The iPhone's motion
// coprocessor writes these same quantities, and Apple Health *sums* every third-party source on
// top of the iPhone instead of merging them (its private iPhone+Watch dedup does not extend to
// third parties, and there's no API to influence the aggregation). So writing the band's totals
// raw would double-count a shared walk. Instead `writeReconciledActivity` writes only the band's
// *surplus* over what the iPhone already recorded for the same minute — net total per minute =
// max(band, iPhone). That kills the double count, keeps the iPhone's Mobility metrics (Walking
// Asymmetry, Step Length, etc., which the band can't produce and which need Fitness Tracking on),
// and still captures steps taken without the phone. SpO₂ stays out of this — the iPhone has no
// such sensor, so it's written at full per-minute granularity in `writeMinuteSamples`.

@MainActor
final class HealthKitManager {

    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private let log = AppLogger(category: "Health")

    private let syncVersion = 1
    /// Reconciled minutes newer than this are skipped: the iPhone pedometer may not have written
    /// them to HealthKit yet, so reconciling them would delta against a near-zero baseline and inflate
    /// the surplus. They're reconciled on a later sync once settled (the band re-offers today's file).
    private let reconcileSettleWindow: TimeInterval = 15 * 60

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // Types we write.
    private let sleepType   = HKCategoryType(.sleepAnalysis)
    private let heartRate   = HKQuantityType(.heartRate)
    private let stepCount   = HKQuantityType(.stepCount)
    private let distance    = HKQuantityType(.distanceWalkingRunning)
    private let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private let basalEnergy  = HKQuantityType(.basalEnergyBurned)
    private let spo2        = HKQuantityType(.oxygenSaturation)
    private let respiratoryRate = HKQuantityType(.respiratoryRate)
    private let bodyTemp    = HKQuantityType(.bodyTemperature)
    private let restingHR   = HKQuantityType(.restingHeartRate)
    private let vo2Max      = HKQuantityType(.vo2Max)
    private let distanceCycling  = HKQuantityType(.distanceCycling)
    private let distanceSwimming = HKQuantityType(.distanceSwimming)
    private let swimStrokes      = HKQuantityType(.swimmingStrokeCount)
    private let bodyMass         = HKQuantityType(.bodyMass)
    private let bodyMassIndex    = HKQuantityType(.bodyMassIndex)
    private let height           = HKQuantityType(.height)
    private let physicalEffort   = HKQuantityType(.physicalEffort)
    private let runningSpeed     = HKQuantityType(.runningSpeed)
    private let runningStride    = HKQuantityType(.runningStrideLength)
    private let runningGroundContactTime = HKQuantityType(.runningGroundContactTime)
    private let runningVerticalOscillation = HKQuantityType(.runningVerticalOscillation)
    private let walkingSpeed     = HKQuantityType(.walkingSpeed)
    private let walkingStepLength = HKQuantityType(.walkingStepLength)
    private let cyclingSpeedType = HKQuantityType(.cyclingSpeed)
    private let cyclingCadence   = HKQuantityType(.cyclingCadence)
    private let flightsClimbed   = HKQuantityType(.flightsClimbed)
    private let hrRecovery       = HKQuantityType(.heartRateRecoveryOneMinute)
    private let workoutType      = HKObjectType.workoutType()
    private let routeType        = HKSeriesType.workoutRoute()
    private let hrvType          = HKQuantityType(.heartRateVariabilitySDNN)
    private let heartbeatType    = HKSeriesType.heartbeat()

    /// Plausible sample date window: 2020-01-01 UTC through 24 h ahead of now. Rejects epoch-zero
    /// (1969/1970) and corrupted header timestamps before they can reach Apple Health.
    private static let minValidDate = Date(timeIntervalSince1970: 1_577_836_800)
    static var validDateRange: ClosedRange<Date> {
        minValidDate ... Date().addingTimeInterval(86_400)
    }
    private static let pre2020CleanupKey = "myband.pre2020CleanupDone.v1"

    /// MET: 1 kcal per kg per hour — the unit of physicalEffort and HKMetadataKeyAverageMETs.
    private static let metUnit = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [sleepType, heartRate, stepCount, distance, activeEnergy, basalEnergy,
         spo2, respiratoryRate, bodyTemp, restingHR, vo2Max, distanceCycling, distanceSwimming, swimStrokes,
         bodyMass, bodyMassIndex, height, workoutType, routeType,
         physicalEffort, runningSpeed, runningStride, runningGroundContactTime, runningVerticalOscillation,
         walkingSpeed, walkingStepLength, cyclingSpeedType, cyclingCadence, flightsClimbed,
         hrRecovery, hrvType, heartbeatType]
        if #available(iOS 18.0, *) {
            types.insert(HKQuantityType(.estimatedWorkoutEffortScore))
            types.insert(HKQuantityType(.distanceRowing))
        }
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthError.unavailable }
        // Date of birth and biological sex are read-only characteristics: age drives the max-HR
        // estimate behind the workout effort score, and both feed the Mifflin-St Jeor resting
        // energy (BMR) calculation. Denial is fine — both fall back to sensible defaults.
        var readTypes: Set<HKObjectType> = shareTypes
        readTypes.insert(HKCharacteristicType(.dateOfBirth))
        readTypes.insert(HKCharacteristicType(.biologicalSex))
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// The newer, enrichment-only types are guarded by this before being added to a save batch: a
    /// single denied type fails the whole `store.save`, which would break the established pipeline
    /// (HR/SpO₂/workouts) over an optional metric. Denied/undetermined → that metric is skipped.
    private func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    // MARK: - Sleep

    // A night reaches us as several reports. A resync of a still-in-progress (or previously partial)
    // night comes back as another file with the same bedtime and different boundaries, and BandSyncer
    // adds every stored report overlapping the batch (`withStoredReports`). Each report is sanitized
    // on its own (`SleepDetailsParser.sanitizeStages`), never against the others, and the old
    // per-phase/per-inBed identifier baked in `endDate` — exactly what changes between resyncs — so
    // HealthKit's sync-identifier dedup (see header comment) never recognized them as updates.
    // Per night, then: (1) merge every overlapping report, the one reaching furthest into the night
    // winning where they disagree (`mergedPhases`); (2) key identifiers on the phase's own start +
    // type only (stable across a growing end); and (3) clear whatever this app already wrote for the
    // window first, so a reclassified stage (same start, different type — not caught by a stable id
    // alone) is superseded instead of sitting alongside the old one. Because of (3) the batch must
    // hold everything known about the night: a partial report written alone erases the rest of it.
    func writeSleep(_ sessions: [SleepSession]) async throws -> Int {
        try await writeNights(Self.groupOverlapping(sessions), keepingRicherHealthNights: false).written
    }

    /// One-time history repair (`BandSyncer.repairSleepHistoryOnce`): every stored night rewritten
    /// through the merge, except one Apple Health already holds more of than its stored reports
    /// (`healthHoldsMore`) — a repair must never shrink a night.
    func repairSleep(from sessions: [SleepSession]) async throws -> (nights: Int, kept: Int, written: Int) {
        try await writeNights(Self.groupOverlapping(sessions), keepingRicherHealthNights: true)
    }

    /// Each night is cleared and saved on its own, so a failure loses at most the night being written —
    /// whose reports are still un-ACKed on the band (sync) or in the store (repair).
    private func writeNights(_ nights: [[SleepSession]],
                             keepingRicherHealthNights: Bool) async throws -> (nights: Int, kept: Int, written: Int) {
        var result = (nights: 0, kept: 0, written: 0)
        let validDates = Self.validDateRange
        for group in nights {
            guard let start = group.map(\.startDate).min(), let end = group.map(\.endDate).max(),
                  end > start, validDates.contains(start), validDates.contains(end) else { continue }
            let phases = Self.mergedPhases(group)

            if keepingRicherHealthNights {
                let existing = try await ownSleepSamples(overlapping: start, to: end).map {
                    (start: $0.startDate, end: $0.endDate, asleep: Self.asleepValues.contains($0.value))
                }
                if let reason = Self.healthHoldsMore(existing, than: phases, from: start, to: end) {
                    log.info("Sleep repair kept night \(start.logStamp) → \(end.logStamp) as is — \(reason)")
                    result.kept += 1
                    continue
                }
            }

            let cleared = try await deleteExistingSleep(overlapping: start, to: end)

            // Enclosing in-bed window so Apple Health reports "Time in Bed" alongside the stages.
            var samples: [HKSample] = [HKCategorySample(
                type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: start, end: end,
                metadata: syncMetadata("mb-inbed-\(Int(start.timeIntervalSince1970))")
            )]
            for phase in phases {
                guard phase.endDate > phase.startDate, let value = Self.sleepValue(phase.type) else { continue }
                let id = "mb-sleep-\(Int(phase.startDate.timeIntervalSince1970))-\(phase.type.rawValue)"
                samples.append(HKCategorySample(
                    type: sleepType, value: value.rawValue,
                    start: phase.startDate, end: phase.endDate,
                    metadata: syncMetadata(id)
                ))
            }
            result.written += try await save(samples)
            result.nights += 1
            log.info("Sleep night \(start.logStamp) → \(end.logStamp): \(group.count) report(s) merged into \(phases.count) phase(s), \(cleared) old sample(s) cleared")
        }
        return result
    }

    /// Groups sessions whose `[startDate, endDate]` windows transitively overlap — incremental
    /// resyncs of the same night, however many files/sessions it was split across. Public so tests
    /// can validate grouping independent of HealthKit.
    static func groupOverlapping(_ sessions: [SleepSession]) -> [[SleepSession]] {
        let sorted = sessions.sorted { $0.startDate < $1.startDate }
        var groups: [[SleepSession]] = []
        for s in sorted {
            if let lastEnd = groups.last?.map(\.endDate).max(), s.startDate < lastEnd {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        return groups
    }

    /// One night's phases across all of its reports. Where reports overlap, the one reaching furthest
    /// into the night wins — the band re-scores stages as the night goes on, so what a mid-night file
    /// said about 1 a.m. yields to the morning file — and earlier reports only fill time the later
    /// ones don't cover. Public so tests can validate it independent of HealthKit.
    static func mergedPhases(_ group: [SleepSession]) -> [SleepPhase] {
        let byReach = group.sorted {
            $0.endDate != $1.endDate ? $0.endDate > $1.endDate : $0.startDate < $1.startDate
        }
        var covered: [(start: Date, end: Date)] = []
        var merged: [SleepPhase] = []
        for report in byReach {
            guard report.endDate > report.startDate else { continue }
            // The same ±6 h slack the parsers allow: a stage stamped hours away from its report's
            // window is a misread, and it would claim that time from every other report of the night.
            let plausible = report.startDate.addingTimeInterval(-6 * 3600) ... report.endDate.addingTimeInterval(6 * 3600)
            let phases = SleepDetailsParser.sanitizeStages(report.phases.filter {
                plausible.contains($0.startDate) && plausible.contains($0.endDate)
            })
            for phase in phases {
                merged += uncovered(phase, by: covered)
            }
            covered.append((start: min(report.startDate, phases.first?.startDate ?? report.startDate),
                            end: max(report.endDate, phases.last?.endDate ?? report.endDate)))
        }
        return merged.sorted { $0.startDate < $1.startDate }
    }

    /// The parts of `phase` outside every window in `covered`.
    private static func uncovered(_ phase: SleepPhase, by covered: [(start: Date, end: Date)]) -> [SleepPhase] {
        var pieces = [phase]
        for window in covered {
            var remaining: [SleepPhase] = []
            for piece in pieces {
                guard window.start < piece.endDate, window.end > piece.startDate else {
                    remaining.append(piece)
                    continue
                }
                if piece.startDate < window.start {
                    remaining.append(SleepPhase(startDate: piece.startDate, endDate: window.start, type: piece.type))
                }
                if window.end < piece.endDate {
                    remaining.append(SleepPhase(startDate: window.end, endDate: piece.endDate, type: piece.type))
                }
            }
            pieces = remaining
        }
        return pieces
    }

    private static let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))

    /// Why rewriting a night from its stored reports would lose data — nil if it wouldn't. Apple
    /// Health's copy (this app's own samples) reaching past the reports' window, or holding clearly
    /// more time asleep than their merge, was written from a report the store no longer has: lost to
    /// the old 1-byte hash collisions, or to a store reset after corruption. The tolerances absorb the
    /// band re-scoring stages between reports. Public so tests can validate it independent of HealthKit.
    static func healthHoldsMore(_ existing: [(start: Date, end: Date, asleep: Bool)], than phases: [SleepPhase],
                                from start: Date, to end: Date) -> String? {
        guard let healthStart = existing.map({ $0.start }).min(),
              let healthEnd = existing.map({ $0.end }).max() else { return nil }
        let edgeTolerance: TimeInterval = 5 * 60
        if healthStart < start.addingTimeInterval(-edgeTolerance) {
            return "Apple Health starts at \(healthStart.logStamp), the stored reports at \(start.logStamp)"
        }
        if healthEnd > end.addingTimeInterval(edgeTolerance) {
            return "Apple Health ends at \(healthEnd.logStamp), the stored reports at \(end.logStamp)"
        }
        let healthAsleep = coveredDuration(existing.filter { $0.asleep }.map { (start: $0.start, end: $0.end) })
        let storedAsleep = coveredDuration(phases.filter { $0.type != .awake }.map { (start: $0.startDate, end: $0.endDate) })
        if healthAsleep > storedAsleep + 15 * 60 {
            return "Apple Health has \(Int(healthAsleep / 60)) min asleep, the stored reports \(Int(storedAsleep / 60))"
        }
        return nil
    }

    /// Length of the union of `intervals`: overlapping samples — duplicates left by older builds — count once.
    private static func coveredDuration(_ intervals: [(start: Date, end: Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var run: (start: Date, end: Date)?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let current = run, interval.start <= current.end {
                run = (start: current.start, end: max(current.end, interval.end))
            } else {
                if let current = run { total += current.end.timeIntervalSince(current.start) }
                run = interval
            }
        }
        if let current = run { total += current.end.timeIntervalSince(current.start) }
        return total
    }

    private func ownSleepSamples(overlapping start: Date, to end: Date) async throws -> [HKCategorySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: ownSleepPredicate(start, end))],
            sortDescriptors: []
        )
        return try await descriptor.result(for: store)
    }

    private func ownSleepPredicate(_ start: Date, _ end: Date) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: [HKSource.default()]),
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
        ])
    }

    private func deleteExistingSleep(overlapping start: Date, to end: Date) async throws -> Int {
        do {
            return try await store.deleteObjects(of: sleepType, predicate: ownSleepPredicate(start, end))
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing of ours in the window yet — a night's first write. Letting this throw would
            // fail the save that follows, every time a new night shows up.
            return 0
        }
    }

    // MARK: - Sleep history rebuild (from Apple Health)
    //
    // Nights written before the stable identifiers sit in Apple Health with every re-sync stacked on the
    // previous ones — several in-bed samples, overlapping stages, time asleep counted several times over —
    // and for everything older than the local store (recreated on hardware on 2026-09-09) Apple Health
    // holds the only copy. So the rebuild reads it back: this app's own sleep samples, grouped into
    // nights by transitive overlap, and every stacked night collapsed to one in-bed sample plus
    // non-overlapping stages.
    //
    // Which stage wins an overlap can't be recovered exactly: HealthKit doesn't expose which re-sync
    // wrote a sample. `collapsedPhases` puts the shortest sample first at each start and lets the rest
    // only extend past it. Against a real export, on the 12 nights whose creation times still separate
    // the re-syncs, that matched the furthest-reaching-report rule (`mergedPhases`) on 92% of minutes —
    // the best of five rules tried (longest first 90%, latest end wins 89%). Time covered is exact.
    //
    // Nights spanning more than 16 h are left as they are and logged: blocks that long aren't only
    // duplication, and collapsing them would still be wrong.

    struct StoredSleepSample {
        let start: Date
        let end: Date
        /// `HKCategoryValueSleepAnalysis` raw value.
        let value: Int
    }

    struct SleepRebuildResult {
        var rebuilt = 0
        var replaced = 0
        var written = 0
        var keptLong = 0
        var clean = 0
    }

    static let rebuildMaxSpan: TimeInterval = 16 * 3600
    /// Above the version every normal write uses, so a rebuilt sample sharing an identifier with an
    /// original replaces it in the save itself.
    private static let rebuildSyncVersion = 2

    func rebuildSleepHistoryFromHealth() async throws -> SleepRebuildResult {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: HKQuery.predicateForObjects(from: [HKSource.default()]))],
            sortDescriptors: []
        )
        let all = try await descriptor.result(for: store)
        var result = SleepRebuildResult()

        for night in Self.overlapGroups(all, start: { $0.startDate }, end: { $0.endDate }) {
            let samples = night.map { StoredSleepSample(start: $0.startDate, end: $0.endDate, value: $0.value) }
            guard Self.needsRebuild(samples),
                  let start = samples.map(\.start).min(), let end = samples.map(\.end).max() else {
                result.clean += 1
                continue
            }
            let span = end.timeIntervalSince(start)
            guard span <= Self.rebuildMaxSpan else {
                log.warning("Sleep rebuild left \(start.logStamp) → \(end.logStamp) as is — \(String(format: "%.1f", span / 3600)) h, more than duplication explains")
                result.keptLong += 1
                continue
            }

            let phases = Self.collapsedPhases(samples)
            var rebuilt: [HKSample] = [HKCategorySample(
                type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue, start: start, end: end,
                metadata: syncMetadata("mb-inbed-\(Int(start.timeIntervalSince1970))", version: Self.rebuildSyncVersion)
            )]
            for phase in phases {
                guard let value = Self.sleepValue(phase.type) else { continue }
                rebuilt.append(HKCategorySample(
                    type: sleepType, value: value.rawValue, start: phase.startDate, end: phase.endDate,
                    metadata: syncMetadata("mb-sleep-\(Int(phase.startDate.timeIntervalSince1970))-\(phase.type.rawValue)",
                                           version: Self.rebuildSyncVersion)
                ))
            }

            // Save first: Apple Health is the only copy of these nights, so a failed save must not come
            // after the originals are gone.
            result.written += try await save(rebuilt)
            let rebuiltIds = Set(rebuilt.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
            let superseded = night.filter { original in
                !rebuiltIds.contains(original.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "")
            }
            if !superseded.isEmpty { try await store.delete(superseded) }
            result.replaced += night.count
            result.rebuilt += 1

            let summed: TimeInterval = samples.filter { Self.asleepValues.contains($0.value) }
                .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            let asleep: TimeInterval = phases.filter { $0.type != .awake }.reduce(0) { $0 + $1.duration }
            log.info("Sleep rebuild \(start.logStamp) → \(end.logStamp): \(night.count) sample(s) → \(rebuilt.count), asleep \(String(format: "%.1f", summed / 3600)) h summed → \(String(format: "%.1f", asleep / 3600)) h")
        }
        return result
    }

    /// Groups by transitive overlap: an item joins the current group when it starts before the group's
    /// furthest end. Public so tests can validate it independent of HealthKit.
    static func overlapGroups<T>(_ items: [T], start: (T) -> Date, end: (T) -> Date) -> [[T]] {
        var groups: [[T]] = []
        var reach = Date.distantPast
        for item in items.sorted(by: { start($0) < start($1) }) {
            if !groups.isEmpty, start(item) < reach {
                groups[groups.count - 1].append(item)
                reach = max(reach, end(item))
            } else {
                groups.append([item])
                reach = end(item)
            }
        }
        return groups
    }

    /// More than one in-bed sample, or stages overlapping each other: a night stacked by re-syncs.
    static func needsRebuild(_ night: [StoredSleepSample]) -> Bool {
        let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
        if night.filter({ $0.value == inBed }).count > 1 { return true }
        var reach = Date.distantPast
        for stage in night.filter({ $0.value != inBed }).sorted(by: { $0.start < $1.start }) {
            if stage.start < reach { return true }
            reach = max(reach, stage.end)
        }
        return false
    }

    /// One non-overlapping timeline from a stacked night: at each start the shortest sample goes first,
    /// later ones only extend past what's already kept, and touching pieces of the same stage are
    /// joined. Public so tests can validate it independent of HealthKit.
    static func collapsedPhases(_ night: [StoredSleepSample]) -> [SleepPhase] {
        let stages = night.compactMap { sample -> SleepPhase? in
            guard sample.end > sample.start, let type = phaseType(sample.value) else { return nil }
            return SleepPhase(startDate: sample.start, endDate: sample.end, type: type)
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.type.rawValue < $1.type.rawValue
        }
        var timeline: [SleepPhase] = []
        for stage in stages {
            let from = max(stage.startDate, timeline.last?.endDate ?? stage.startDate)
            guard stage.endDate > from else { continue }
            if let last = timeline.last, last.endDate == from, last.type == stage.type {
                timeline[timeline.count - 1].endDate = stage.endDate
            } else {
                timeline.append(SleepPhase(startDate: from, endDate: stage.endDate, type: stage.type))
            }
        }
        return timeline
    }

    private static func phaseType(_ value: Int) -> SleepPhaseType? {
        guard let analysis = HKCategoryValueSleepAnalysis(rawValue: value) else { return nil }
        switch analysis {
        case .awake:                          return .awake
        case .asleepCore, .asleepUnspecified: return .light
        case .asleepDeep:                     return .deep
        case .asleepREM:                      return .rem
        default:                              return nil
        }
    }

    private static func sleepValue(_ type: SleepPhaseType) -> HKCategoryValueSleepAnalysis? {
        switch type {
        case .awake: .awake
        case .light: .asleepCore
        case .deep:  .asleepDeep
        case .rem:   .asleepREM
        }
    }

    // MARK: - Daily summary (steps, calories, HR/SpO₂ extremes)

    func writeDailySummary(_ s: DailySummary) async throws -> Int {
        var samples: [HKSample] = []
        let dayStart = Calendar.current.startOfDay(for: s.date)
        let dayEnd = min(dayStart.addingTimeInterval(86_400 - 1), Date())
        let dayKey = Int(dayStart.timeIntervalSince1970)

        // Steps, distance and active energy are intentionally NOT written here. They would be
        // summed on top of the iPhone's own values; the per-minute daily-details file carries the
        // same totals and goes through writeReconciledActivity, which deltas them against the
        // iPhone. The daily summary keeps only band-exclusive readings (HR/SpO₂ extremes), which
        // the iPhone never produces and so never conflict.
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let validDateRange = Self.validDateRange
        guard validDateRange.contains(dayStart) else { return 0 }

        if let resting = s.restingHR, (35...150).contains(resting) {
            samples.append(quantity(restingHR, bpm, Double(resting),
                                    start: dayStart, end: dayEnd, id: "mb-hrresting-\(dayKey)"))
        }
        if let max = s.maxHR, (35...220).contains(max.bpm), validDateRange.contains(max.at) {
            samples.append(quantity(heartRate, bpm, Double(max.bpm), start: max.at, end: max.at, id: "mb-hrmax-\(Int(max.at.timeIntervalSince1970))"))
        }
        if let min = s.minHR, (35...220).contains(min.bpm), validDateRange.contains(min.at) {
            samples.append(quantity(heartRate, bpm, Double(min.bpm), start: min.at, end: min.at, id: "mb-hrmin-\(Int(min.at.timeIntervalSince1970))"))
        }
        if let mx = s.spo2Max, (50...100).contains(mx.pct), validDateRange.contains(mx.at) {
            samples.append(quantity(spo2, .percent(), Double(mx.pct) / 100.0, start: mx.at, end: mx.at, id: "mb-spo2max-\(Int(mx.at.timeIntervalSince1970))"))
        }
        if let mn = s.spo2Min, (50...100).contains(mn.pct), validDateRange.contains(mn.at) {
            samples.append(quantity(spo2, .percent(), Double(mn.pct) / 100.0, start: mn.at, end: mn.at, id: "mb-spo2min-\(Int(mn.at.timeIntervalSince1970))"))
        }
        // Daily Resting Energy (basalEnergyBurned) outside workouts: Mifflin-St Jeor BMR pro-rated
        // across the elapsed non-workout portion of the day. Uses a monotonic sync version so
        // later syncs of the same day replace the earlier partial-day sample in place.
        if canShare(basalEnergy), dayEnd > dayStart {
            let dailyBMR = await estimatedDailyBasalKilocalories()
            let workouts = (try? await ownWorkouts(endingBetween: dayStart, and: dayEnd.addingTimeInterval(7200))) ?? []
            let workoutWindows: [(start: Date, end: Date)] = workouts.compactMap { w in
                let start = max(dayStart, w.startDate)
                let end = min(dayEnd, w.endDate)
                return end > start ? (start: start, end: end) : nil
            }
            let workoutSeconds = Self.coveredDuration(workoutWindows)
            let nonWorkoutSeconds = max(0, dayEnd.timeIntervalSince(dayStart) - workoutSeconds)
            if nonWorkoutSeconds >= 60 {
                let basalKcal = dailyBMR * (nonWorkoutSeconds / 86_400.0)
                let version = Int(Date().timeIntervalSince1970)
                samples.append(quantity(basalEnergy, .kilocalorie(), basalKcal,
                                        start: dayStart, end: dayEnd,
                                        id: "mb-basal-day-\(dayKey)", version: version))
            }
        }
        // NOTE: standingHours (DailySummary) is intentionally NOT written. HKCategoryType
        // .appleStandHour is reserved — HealthKit disallows third-party apps from sharing it
        // (requesting authorization throws NSInvalidArgumentException). There is no
        // third-party-writable "stand hour" type, so the band's mask stays local-only.
        return try await save(samples)
    }

    // MARK: - Per-minute detail (HR / SpO₂ / Physical Effort time series)
    //
    // Band-exclusive vitals only. Distance moved to writeReconciledActivity (it double-counts with
    // the iPhone); HR and SpO₂ have no iPhone equivalent here, so they're written raw at full
    // granularity. Also used for the HR/SpO₂ samples recorded during sleep.
    //
    // Physical Effort (METs, the same all-day metric the Apple Watch populates) derives from the
    // band's per-minute active calories and the user's weight: MET = 1 (resting baseline, which the
    // band's *active* kcal excludes by definition) + kcal·60/kg. No reconciliation needed — the
    // iPhone never writes physicalEffort. Sleep-vitals batches carry no calories, so they skip it.

    func writeMinuteSamples(_ minutes: [ActivityMinuteSample]) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let validDates = Self.validDateRange
        var weightKg: Double?
        if canShare(physicalEffort), minutes.contains(where: { ($0.caloriesKcal ?? 0) > 0 }) {
            weightKg = (try? await latestBodyMassKg()) ?? nil
        }
        var samples: [HKSample] = []
        for m in minutes {
            guard validDates.contains(m.date) else { continue }
            let key = Int(m.date.timeIntervalSince1970)
            if let hr = m.heartRate, (30...250).contains(hr) {
                let isActive = (m.steps ?? 0) > 0
                var hrMeta = syncMetadata("mb-hr-\(key)")
                hrMeta[HKMetadataKeyHeartRateMotionContext] = (isActive ? HKHeartRateMotionContext.active : .sedentary).rawValue
                hrMeta[HKMetadataKeyUserMotionContext] = (isActive ? HKUserMotionContext.active : .stationary).rawValue
                samples.append(HKQuantitySample(
                    type: heartRate,
                    quantity: HKQuantity(unit: bpm, doubleValue: Double(hr)),
                    start: m.date, end: m.date,
                    metadata: hrMeta
                ))
            }
            if let s = m.spo2, (50...100).contains(s) {
                samples.append(quantity(spo2, .percent(), Double(s) / 100.0, start: m.date, end: m.date, id: "mb-spo2-\(key)"))
            }
            if let kcal = m.caloriesKcal, kcal > 0, let w = weightKg, w > 0 {
                let met = 1.0 + Double(kcal) * 60.0 / w
                if (1.0...30.0).contains(met) {
                    samples.append(quantity(physicalEffort, Self.metUnit, met,
                                            start: m.date, end: m.date.addingTimeInterval(60),
                                            id: "mb-effort-\(key)"))
                }
            }
        }
        return try await save(samples)
    }

    /// Writes a single live heart rate reading (received via GATT 2A37 or Protobuf `RealTimeStats`)
    /// to Apple Health with `.active` motion context and `.wrist` sensor location so third-party
    /// fitness apps observing HealthKit (`HKObserverQuery` / `HKAnchoredObjectQuery`) receive live
    /// BPM updates.
    func writeLiveHeartRate(bpm: Int, date: Date = Date()) async throws -> Int {
        guard canShare(heartRate), (30...250).contains(bpm), Self.validDateRange.contains(date) else { return 0 }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        var meta = syncMetadata("mb-livehr-\(Int(date.timeIntervalSince1970))")
        meta[HKMetadataKeyHeartRateMotionContext] = HKHeartRateMotionContext.active.rawValue
        meta[HKMetadataKeyUserMotionContext] = HKUserMotionContext.active.rawValue
        meta[HKMetadataKeyHeartRateSensorLocation] = HKHeartRateSensorLocation.wrist.rawValue
        let sample = HKQuantitySample(
            type: heartRate,
            quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(bpm)),
            start: date,
            end: date,
            metadata: meta
        )
        return try await save([sample])
    }

    /// Daily Walking Heart Rate Average (BPM) computed from per-minute samples where the user is
    /// walking at a steady cadence (20...140 steps/min) with a plausible walking HR (40...190 bpm).
    /// `HKQuantityType(.walkingHeartRateAverage)` itself is Apple-Watch-restricted in HealthKit and
    /// throws NSInvalidArgumentException if shared by a third-party app, so we tag the underlying
    /// `heartRate` samples with `HKHeartRateMotionContext` for HealthKit and compute this average
    /// for ActivityDay / DashboardView.
    static func walkingHeartRateAverage(_ minutes: [ActivityMinuteSample]) -> Int? {
        let hrs = minutes.compactMap { m -> Int? in
            guard let steps = m.steps, (20...140).contains(steps),
                  let hr = m.heartRate, (40...190).contains(hr) else { return nil }
            return hr
        }
        guard !hrs.isEmpty else { return nil }
        let sum = hrs.reduce(0, +)
        return Int((Double(sum) / Double(hrs.count)).rounded())
    }

    // MARK: - Heart rate variability & overnight respiratory rate (sleep beat-to-beat intervals)
    //
    // Per block of the band's beat-to-beat intervals (see HeartRateVariability): one heartbeat series
    // with every beat, one SDNN value per clean minute, and one overnight respiratoryRate value derived
    // from Respiratory Sinus Arrhythmia (RSA). All three types are optional enrichment, so a denied one
    // is skipped (canShare) instead of failing the batch.
    //
    // Re-syncs: each report of a night repeats the blocks of the ones before it. SDNN and respiratory
    // rate values carry a sync identifier and are replaced in place. A heartbeat series is built, not
    // saved whole, so the sync-identifier replacement isn't something to lean on — identifiers already
    // in Health are looked up and their blocks skipped.

    /// Bump when HeartRateVariability changes how a minute's value is computed: a higher version
    /// replaces the SDNN values already in Health on the next write of their nights.
    private let hrvVersion = 1

    struct HRVWriteResult {
        var minuteValues = 0
        var respiratoryValues = 0
        var seriesWritten = 0
        var seriesAlreadyThere = 0
        var medianSDNN: Double?
    }

    func writeHeartRateVariability(_ blocks: [BeatWindow]) async throws -> HRVWriteResult {
        var result = HRVWriteResult()
        let validDates = Self.validDateRange
        let blocks = HeartRateVariability.distinct(blocks).filter { validDates.contains($0.start) }
        guard !blocks.isEmpty else { return result }

        if canShare(hrvType) {
            let minutes = blocks.flatMap(HeartRateVariability.minuteSDNN)
            let ms = HKUnit.secondUnit(with: .milli)
            let samples = minutes.map {
                quantity(hrvType, ms, $0.sdnnMs, start: $0.start, end: $0.end,
                         id: "mb-hrv-\(Int($0.start.timeIntervalSince1970))", version: hrvVersion)
            }
            result.minuteValues = try await save(samples)
            let sorted = minutes.map(\.sdnnMs).sorted()
            if !sorted.isEmpty { result.medianSDNN = sorted[sorted.count / 2] }
        }

        if canShare(respiratoryRate) {
            let respSamples = blocks.compactMap(HeartRateVariability.respiratoryRate)
            let brpm = HKUnit.count().unitDivided(by: .minute())
            let hkResp = respSamples.map {
                quantity(respiratoryRate, brpm, $0.breathsPerMinute, start: $0.start, end: $0.end,
                         id: "mb-resp-\(Int($0.start.timeIntervalSince1970))", version: hrvVersion)
            }
            result.respiratoryValues = try await save(hkResp)
        }

        if canShare(heartbeatType) {
            let ids = blocks.map(Self.heartbeatSeriesID)
            let present = try await existingSyncIdentifiers(of: heartbeatType, among: ids)
            for (block, id) in zip(blocks, ids) {
                if present.contains(id) { result.seriesAlreadyThere += 1; continue }
                try await saveHeartbeatSeries(block, id: id)
                result.seriesWritten += 1
            }
        }
        return result
    }

    /// Milliseconds: blocks are ~605 s apart, but the identifier has to be exact for the lookup.
    static func heartbeatSeriesID(_ block: BeatWindow) -> String {
        "mb-beats-\(Int64((block.start.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// The builder takes offsets that must be strictly positive, so the series starts one band unit
    /// (10 ms) before its first beat. A block longer than the builder's limit is split in parts that
    /// carry their own identifiers; a part starts with a gap, since its first interval is unknown.
    private func saveHeartbeatSeries(_ block: BeatWindow, id: String) async throws {
        let lead: TimeInterval = 0.01
        let beats = HeartRateVariability.beats(block)
        let limit = max(2, Int(HKHeartbeatSeriesBuilder.maximumCount))
        for (part, chunkStart) in stride(from: 0, to: beats.count, by: limit).enumerated() {
            let chunk = beats[chunkStart ..< min(beats.count, chunkStart + limit)]
            guard let first = chunk.first else { continue }
            let seriesStart = block.start.addingTimeInterval(first.offset - lead)
            let builder = HKHeartbeatSeriesBuilder(healthStore: store, device: .local(), start: seriesStart)
            for (i, beat) in chunk.enumerated() {
                try await builder.addHeartbeat(at: beat.offset - first.offset + lead,
                                               precededByGap: i == 0 || beat.precededByGap)
            }
            try await builder.addMetadata(syncMetadata(part == 0 ? id : "\(id)-\(part)"))
            _ = try await builder.finishSeries()
        }
    }

    private func existingSyncIdentifiers(of type: HKSampleType, among ids: [String]) async throws -> Set<String> {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: [HKSource.default()]),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ids),
        ])
        let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)],
                                                 sortDescriptors: [])
        let found = try await descriptor.result(for: store)
        return Set(found.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
    }

    // MARK: - Reconciled activity (steps / distance / active energy)
    //
    // Writes only the band's surplus over the iPhone, per minute, so the Health total stops
    // double-counting (see the type header). Each band minute is reconciled against the iPhone's
    // already-recorded value for that exact minute: delta = max(0, band − iPhone). Two things keep
    // the surplus accurate across re-syncs: (1) minutes inside reconcileSettleWindow are skipped, so
    // the iPhone's pedometer has had time to write them before we delta against it; (2) a monotonic
    // sync version lets a later sync REPLACE an earlier surplus with a corrected one — HealthKit only
    // replaces a same-identifier sample when the new version is strictly greater (equal/lower saves
    // are ignored), so a constant version would freeze a first, possibly inflated, write forever. If
    // the user denied read access the iPhone sums come back empty and we fall back to writing the
    // full band value — the safe direction (band stays authoritative).

    func writeReconciledActivity(_ minutes: [ActivityMinuteSample],
                                 excludingWorkouts windows: [(start: Date, end: Date)] = []) async throws -> Int {
        // Distance and active energy measured during a workout are already written as the workout's
        // own samples (writeWorkouts), which Apple Health also folds into the daily totals — so skip
        // those minutes here to avoid counting them twice. Steps aren't part of a workout's samples,
        // so they're always reconciled.
        func inWorkout(_ d: Date) -> Bool { windows.contains { d >= $0.start && d < $0.end } }

        // Skip minutes the iPhone may not have finalised yet (see the type header). Skipped recent
        // minutes are reconciled on a later sync — the band keeps re-offering today's growing file.
        let cutoff = Date().addingTimeInterval(-reconcileSettleWindow)
        let validDates = Self.validDateRange
        func settled(_ d: Date) -> Bool { d < cutoff && validDates.contains(d) }

        let steps = minutes.filter { settled($0.date) }.compactMap { m in m.steps.map { (m.date, Double($0)) } }
        let dist  = minutes.filter { settled($0.date) && !inWorkout($0.date) }.compactMap { m in m.distanceMeters.map { (m.date, $0) } }
        let cals  = minutes.filter { settled($0.date) && !inWorkout($0.date) }.compactMap { m in m.caloriesKcal.map { (m.date, Double($0)) } }

        // Strictly-increasing across the BLE-round-trip gap between any two syncs, so the later sync's
        // recomputed (usually smaller) delta replaces the earlier one instead of being discarded.
        let version = Int(Date().timeIntervalSince1970)

        var samples: [HKSample] = []
        samples += try await reconciledSurplus(stepCount, .count(), steps, idPrefix: "mb-steps-rec", version: version)
        samples += try await reconciledSurplus(distance, .meter(), dist, idPrefix: "mb-dist-rec", version: version)
        samples += try await reconciledSurplus(activeEnergy, .kilocalorie(), cals, idPrefix: "mb-cal-rec", version: version)
        return try await save(samples)
    }

    /// Builds per-minute "surplus" samples for one quantity type: band value minus the iPhone's sum
    /// for the same minute, dropped when ≤ 0. `version` is the monotonic sync version (see caller).
    private func reconciledSurplus(_ type: HKQuantityType, _ unit: HKUnit,
                                   _ values: [(date: Date, value: Double)],
                                   idPrefix: String, version: Int) async throws -> [HKSample] {
        let points = values.filter { $0.value > 0 }.sorted { $0.date < $1.date }
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        let end = last.addingTimeInterval(60)
        let iphone = try await otherSourceSumsByMinute(type: type, unit: unit, start: first, end: end)

        return Self.surplusValues(points, otherSourceSums: iphone).map { key, delta in
            quantity(type, unit, delta,
                    start: Date(timeIntervalSince1970: TimeInterval(key)),
                    end: Date(timeIntervalSince1970: TimeInterval(key)).addingTimeInterval(60),
                    id: "\(idPrefix)-\(key)", version: version)
        }
    }

    /// Pure delta math for cross-source reconciliation: band value minus the iPhone's sum for the
    /// same minute, dropped when ≤ 0. Split out from `reconciledSurplus` (which also does the live
    /// HealthKit query and builds `HKSample`s) so the math itself — the part a re-sync's changing
    /// iPhone totals can actually get wrong — is testable without HealthKit.
    static func surplusValues(_ points: [(date: Date, value: Double)],
                              otherSourceSums: [Int: Double]) -> [(key: Int, delta: Double)] {
        points.compactMap { p in
            let key = Int(p.date.timeIntervalSince1970)
            let delta = p.value - (otherSourceSums[key] ?? 0)
            guard delta > 0 else { return nil }
            return (key, delta)
        }
    }

    /// Per-minute cumulative sum of `type` from every source *except this app*, over [start, end).
    /// A single HKStatisticsCollectionQuery handles partial-overlap samples by pro-rating cumulative
    /// quantities across the 1-minute buckets, so boundary crossings don't skew the totals. Buckets
    /// are anchored at `start` (a band minute boundary) so their keys line up with the band's minutes.
    private func otherSourceSumsByMinute(type: HKQuantityType, unit: HKUnit,
                                         start: Date, end: Date) async throws -> [Int: Double] {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let notMine = NSCompoundPredicate(notPredicateWithSubpredicate: mine)
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [notMine, time])
        var interval = DateComponents(); interval.minute = 1

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Int: Double], Error>) in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: start, intervalComponents: interval)
            query.initialResultsHandler = { _, results, error in
                if let error { cont.resume(throwing: error); return }
                var map: [Int: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    if let sum = stat.sumQuantity() {
                        map[Int(stat.startDate.timeIntervalSince1970)] = sum.doubleValue(for: unit)
                    }
                }
                cont.resume(returning: map)
            }
            store.execute(query)
        }
    }

    // MARK: - Manual (on-demand) measurements

    func writeManualSamples(_ manual: [ManualSample]) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let validDates = Self.validDateRange
        var samples: [HKSample] = []
        for m in manual {
            guard validDates.contains(m.date) else { continue }
            let key = Int(m.date.timeIntervalSince1970)
            switch m.kind {
            case .heartRate where (30...250).contains(m.value):
                samples.append(quantity(heartRate, bpm, m.value, start: m.date, end: m.date, id: "mb-mhr-\(key)"))
            case .spo2 where (50...100).contains(m.value):
                samples.append(quantity(spo2, .percent(), m.value / 100.0, start: m.date, end: m.date, id: "mb-mspo2-\(key)"))
            case .temperature where (30...45).contains(m.value):
                samples.append(quantity(bodyTemp, .degreeCelsius(), m.value, start: m.date, end: m.date, id: "mb-mtemp-\(key)"))
            default:
                continue   // stress (no Apple Health type) or out-of-range reading
            }
        }
        return try await save(samples)
    }

    // MARK: - Workouts
    //
    // Each workout becomes an HKWorkout via HKWorkoutBuilder. Energy/distance/stroke totals
    // are added as samples so Apple Health computes the summary; VO₂max is written as its own
    // sample timestamped at the workout end. A GPS track, when present, becomes an
    // HKWorkoutRoute attached to the finished workout. HKMetadataKeySyncIdentifier makes
    // re-syncing idempotent.

    func writeWorkouts(_ workouts: [WorkoutSummary],
                       routes: [Int: [WorkoutTrackPoint]],
                       heartRates: [Int: [WorkoutHRSample]] = [:],
                       weather: [Int: WorkoutWeather] = [:],
                       endExtension: [Int: TimeInterval] = [:]) async throws -> (written: Int, saved: [Int: HKWorkout]) {
        var written = 0
        var saved: [Int: HKWorkout] = [:]
        let bpm = HKUnit.count().unitDivided(by: .minute())
        // Weight (average METs) and age (max-HR estimate behind the effort score) are fetched once
        // per batch; both degrade gracefully when absent.
        let weightKg = (try? await latestBodyMassKg()) ?? nil
        let estimatedMaxHR = estimatedMaxHeartRate()

        for w in workouts {
            guard w.endDate > w.startDate else { continue }
            let key = Int(w.startDate.timeIntervalSince1970)
            let track = Self.route(forWorkoutStart: w.startDate, in: routes)
            // A strength workout with a pending cooldown extends its window by the cooldown length so
            // the folded-in cooldown route (attached later) falls inside [start, end]. Samples still
            // span only the real workout window.
            let workoutEnd = w.endDate.addingTimeInterval(endExtension[key] ?? 0)

            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(w.kind)
            if let loc = Self.swimmingLocation(w.kind) { config.swimmingLocationType = loc }

            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: w.startDate)

            var samples: [HKSample] = []
            if let kcal = w.caloriesKcal {
                samples.append(quantity(activeEnergy, .kilocalorie(), kcal,
                                        start: w.startDate, end: w.endDate, id: "mb-wkcal-\(key)"))
            }
            if let basal = w.basalCaloriesKcal, canShare(basalEnergy) {
                samples.append(quantity(basalEnergy, .kilocalorie(), basal,
                                        start: w.startDate, end: w.endDate, id: "mb-wbasal-\(key)"))
            }
            if let dist = w.distanceMeters {
                var distType = Self.distanceType(w.kind, distance, distanceCycling, distanceSwimming)
                // Rowing got its own quantity on iOS 18; before that it fell into the default
                // distanceWalkingRunning branch, silently inflating the walking total.
                if #available(iOS 18.0, *), w.kind == .rowing || w.kind == .rowingMachine,
                   canShare(HKQuantityType(.distanceRowing)) {
                    distType = HKQuantityType(.distanceRowing)
                }
                samples.append(quantity(distType, .meter(), dist,
                                        start: w.startDate, end: w.endDate, id: "mb-wdist-\(key)"))
            }
            if let strokes = w.strokes, Self.activityType(w.kind) == .swimming {
                samples.append(quantity(swimStrokes, .count(), strokes,
                                        start: w.startDate, end: w.endDate, id: "mb-wstrokes-\(key)"))
            }
            // In-workout speed series from the GPS track (V2 points carry m/s), so Apple Health
            // draws the speed/pace graph, falling back to average workout speed when no GPS track is
            // present. Running kinds → runningSpeed, walking/hiking → walkingSpeed, cycling → cyclingSpeed.
            if let speedType = Self.speedType(w.kind), canShare(speedType) {
                let mps = HKUnit.meter().unitDivided(by: .second())
                var addedTrackSpeed = false
                if let track {
                    for p in track where w.startDate ... w.endDate ~= p.date {
                        guard let v = p.speed, v > 0, v < 30 else { continue }
                        samples.append(quantity(speedType, mps, v, start: p.date, end: p.date,
                                                id: "mb-wspd-\(key)-\(Int(p.date.timeIntervalSince1970))"))
                        addedTrackSpeed = true
                    }
                }
                if !addedTrackSpeed, let avgKmh = w.speedAvgKmh {
                    let avgMps = avgKmh / 3.6
                    if (0.1 ..< 30.0).contains(avgMps) {
                        samples.append(quantity(speedType, mps, avgMps, start: w.startDate, end: w.endDate,
                                                id: "mb-wspd-avg-\(key)"))
                    }
                }
            }
            let actType = Self.activityType(w.kind)
            // Average stride length and running dynamics (ground contact time, vertical oscillation)
            // for runs. Prefer the band's directly measured stepLengthAvg (cm) when present, falling
            // back to distance / steps.
            if actType == .running {
                if canShare(runningStride) {
                    let measuredStride = w.stepLengthAvgCm.map { $0 / 100.0 }
                    let fallbackStride: Double? = {
                        guard let dist = w.distanceMeters, let steps = w.steps, steps > 0 else { return nil }
                        return dist / steps
                    }()
                    if let stride = measuredStride ?? fallbackStride, (0.3...3.0).contains(stride) {
                        samples.append(quantity(runningStride, .meter(), stride,
                                                start: w.startDate, end: w.endDate, id: "mb-wstride-\(key)"))
                    }
                }
                if canShare(runningGroundContactTime),
                   let gctMs = w.avgGroundContactTimeMs, (50...1000).contains(gctMs) {
                    samples.append(quantity(runningGroundContactTime, .secondUnit(with: .milli), gctMs,
                                            start: w.startDate, end: w.endDate, id: "mb-wgct-\(key)"))
                }
                if canShare(runningVerticalOscillation),
                   let voCm = w.avgVerticalOscillationCm, (1...30).contains(voCm) {
                    samples.append(quantity(runningVerticalOscillation, .meterUnit(with: .centi), voCm,
                                            start: w.startDate, end: w.endDate, id: "mb-wvo-\(key)"))
                }
            }
            // Average walking step length for walking and hiking workouts.
            if (actType == .walking || actType == .hiking), canShare(walkingStepLength) {
                let measuredStride = w.stepLengthAvgCm.map { $0 / 100.0 }
                let fallbackStride: Double? = {
                    guard let dist = w.distanceMeters, let steps = w.steps, steps > 0 else { return nil }
                    return dist / steps
                }()
                if let stride = measuredStride ?? fallbackStride, (0.2...2.5).contains(stride) {
                    samples.append(quantity(walkingStepLength, .meter(), stride,
                                            start: w.startDate, end: w.endDate, id: "mb-wwalkstride-\(key)"))
                }
            }
            // Average cycling cadence (RPM) for outdoor and indoor cycling workouts.
            if actType == .cycling, canShare(cyclingCadence),
               let rpm = w.cadenceAvgRpm, (10...250).contains(rpm) {
                samples.append(quantity(cyclingCadence, bpm, rpm,
                                        start: w.startDate, end: w.endDate, id: "mb-wcadence-\(key)"))
            }
            // Flights climbed derived from vertical ascent (Apple Health standard: 1 flight = 3.0 m).
            if (actType == .walking || actType == .hiking || actType == .running),
               canShare(flightsClimbed), let gain = w.elevationGainMeters, gain >= 3.0 {
                let flights = floor(gain / 3.0)
                if flights >= 1 {
                    samples.append(quantity(flightsClimbed, .count(), flights,
                                            start: w.startDate, end: w.endDate, id: "mb-wflights-\(key)"))
                }
            }
            // Per-second HR series recorded during the workout, attached to this HKWorkout so Apple
            // Health shows the in-workout heart-rate graph. Added to the builder collection (before
            // endCollection) so they associate with the workout. Sync ids keep re-sync idempotent.
            if let hr = Self.heartRateSeries(forWorkoutStart: w.startDate, in: heartRates) {
                var attached = 0
                for s in hr where w.startDate ... w.endDate ~= s.date {
                    var hrMeta = syncMetadata("mb-whr-\(key)-\(Int(s.date.timeIntervalSince1970))")
                    hrMeta[HKMetadataKeyHeartRateMotionContext] = HKHeartRateMotionContext.active.rawValue
                    hrMeta[HKMetadataKeyUserMotionContext] = HKUserMotionContext.active.rawValue
                    samples.append(HKQuantitySample(
                        type: heartRate,
                        quantity: HKQuantity(unit: bpm, doubleValue: Double(s.bpm)),
                        start: s.date, end: s.date,
                        metadata: hrMeta
                    ))
                    attached += 1
                }
                log.info("Workout \(key): attaching \(attached) in-workout HR sample(s) to HKWorkout")
            }
            if !samples.isEmpty {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    builder.add(samples) { _, error in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                }
            }

            var metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "mb-workout-\(key)",
                HKMetadataKeySyncVersion: syncVersion,
                HKMetadataKeyIndoorWorkout: Self.swimmingLocation(w.kind) == nil && Self.isIndoor(w.kind),
                "MiBandWorkoutRealEnd": w.endDate.timeIntervalSince1970,
            ]
            if let avg = w.hrAvg { metadata["MiBandAverageHeartRate"] = avg }
            if let mx = w.hrMax  { metadata["MiBandMaxHeartRate"] = mx }
            if let mn = w.hrMin  { metadata["MiBandMinHeartRate"] = mn }
            if let style = w.swimStyle {
                metadata["MiBandSwimStyle"] = style
                if actType == .swimming {
                    metadata[HKMetadataKeySwimmingStrokeStyle] = Self.swimmingStrokeStyle(style).rawValue
                }
            }
            if actType == .swimming, let laneMeters = w.configuredLaneLengthMeters, laneMeters > 0 {
                metadata[HKMetadataKeyLapLength] = HKQuantity(unit: .meter(), doubleValue: laneMeters)
            }
            if let gain = w.elevationGainMeters {
                metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: gain)
            }
            if let loss = w.elevationLossMeters {
                metadata[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: loss)
            }
            if let avgKmh = w.speedAvgKmh {
                let mps = HKUnit.meter().unitDivided(by: .second())
                metadata[HKMetadataKeyAverageSpeed] = HKQuantity(unit: mps, doubleValue: avgKmh / 3.6)
            }
            if let maxKmh = w.speedMaxKmh {
                let mps = HKUnit.meter().unitDivided(by: .second())
                metadata[HKMetadataKeyMaximumSpeed] = HKQuantity(unit: mps, doubleValue: maxKmh / 3.6)
            }
            if let swolf = w.swolfAvg { metadata[HKMetadataKeySWOLFScore] = swolf }
            if let laps = w.laps { metadata["MiBandLaps"] = laps }
            if let te = w.trainingEffectAerobic { metadata["MiBandTrainingEffectAerobic"] = te }
            if let te = w.trainingEffectAnaerobic { metadata["MiBandTrainingEffectAnaerobic"] = te }
            if let load = w.workoutLoad { metadata["MiBandWorkoutLoad"] = load }
            if let rec = w.recoveryTimeHours { metadata["MiBandRecoveryTimeHours"] = rec }
            // Weather at the workout's location/time (Open-Meteo). Apple Health shows condition,
            // temperature and humidity in the workout detail. Humidity is a fraction (0–1) in the
            // percent unit; condition is the HKWeatherCondition raw value.
            if let wx = weather[key] {
                metadata[HKMetadataKeyWeatherCondition] = Self.weatherCondition(wmo: wx.wmoCode).rawValue
                metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: wx.temperatureC)
                metadata[HKMetadataKeyWeatherHumidity] = HKQuantity(unit: .percent(), doubleValue: wx.humidityPct / 100.0)
            }
            // Average intensity in METs (same math as the per-minute physicalEffort samples):
            // resting baseline + active kcal per kg per hour. Health shows it in the workout detail.
            if let kcal = w.caloriesKcal, let weightKg, weightKg > 0, w.duration > 60 {
                let met = 1.0 + kcal * 3600.0 / (weightKg * w.duration)
                if (1.0...30.0).contains(met) {
                    metadata[HKMetadataKeyAverageMETs] = HKQuantity(unit: Self.metUnit, doubleValue: met)
                }
            }
            try await builder.addMetadata(metadata)

            try await builder.endCollection(at: workoutEnd)
            guard let workout = try await builder.finishWorkout() else { continue }
            written += 1
            saved[key] = workout

            // VO₂max is a standalone sample (not a workout statistic). The test-type metadata tells
            // Health it's a sub-maximal exercise prediction (which is how the band estimates it),
            // same as the Apple Watch's own samples.
            if let vo2 = w.vo2Max, (10...90).contains(vo2) {
                let unit = HKUnit.literUnit(with: .milli)
                    .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
                var meta = syncMetadata("mb-vo2-\(key)")
                meta[HKMetadataKeyVO2MaxTestType] = HKVO2MaxTestType.predictionSubMaxExercise.rawValue
                try await save([HKQuantitySample(type: vo2Max, quantity: HKQuantity(unit: unit, doubleValue: vo2),
                                                 start: w.endDate, end: w.endDate, metadata: meta)])
            }

            // Estimated workout effort (iOS 18): the Fitness app's 1–10 "Effort" scale, derived
            // from the band's average workout HR as a fraction of the age-estimated max HR
            // (linear: 45% → 1, 90%+ → 10). The sample must be saved and then *related* to the
            // workout — the relationship is what Fitness displays. Best-effort: a failure here
            // must not abort the batch (the workout itself is already saved).
            if #available(iOS 18.0, *), let avg = w.hrAvg, (60...220).contains(avg),
               canShare(HKQuantityType(.estimatedWorkoutEffortScore)) {
                let score = min(10.0, max(1.0, ((avg / estimatedMaxHR - 0.40) * 20).rounded()))
                let sample = HKQuantitySample(
                    type: HKQuantityType(.estimatedWorkoutEffortScore),
                    quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: score),
                    start: w.startDate, end: w.endDate,
                    metadata: syncMetadata("mb-weffort-\(key)"))
                do {
                    try await save([sample])
                    _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
                } catch {
                    log.error("Workout effort score failed (start \(key)): \(error.localizedDescription)")
                }
            }

            // Attach the GPS route, if this workout had one. A route failure must not abort the
            // whole batch — the workout is already saved, so log it and move on; the file still
            // gets ACKed and the workout itself is intact in Apple Health.
            if let track = Self.route(forWorkoutStart: w.startDate, in: routes) {
                do { try await attachRoute(track, to: workout) }
                catch { log.error("Workout route attach failed (start \(key)): \(error.localizedDescription)") }
            }
        }
        return (written, saved)
    }

    // MARK: - HR recovery (post-strength)

    /// Writes the 3-minute post-workout heart-rate recovery samples. When `workout` is given (the
    /// usual case), they're saved and then associated with it via `add(_:to:)` so they extend the
    /// workout's HR graph into the recovery period; the workout's window was extended by the recovery
    /// length at write time so the samples fall inside it. When it's nil (the workout didn't sync in
    /// time), the samples are still saved as standalone heart rate so the recovery curve isn't lost.
    /// Sync-ids keep re-writes idempotent.
    func writeRecoveryHR(_ samples: [WorkoutHRSample], toWorkout workout: HKWorkout?) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hkSamples = samples.map { s in
            quantity(heartRate, bpm, Double(s.bpm), start: s.date, end: s.date,
                     id: "mb-recovery-\(Int(s.date.timeIntervalSince1970))")
        }
        try await save(hkSamples)
        if let workout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                store.add(hkSamples, to: workout) { _, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        return hkSamples.count
    }

    // MARK: - GPS route

    /// Picks the GPS track for a workout. The band tags the workout summary and its GPS track with
    /// the same session-start timestamp, but the two file ids can differ by a second or two, so
    /// fall back to the nearest track that starts within two minutes of the workout.
    private static func route(forWorkoutStart start: Date,
                              in routes: [Int: [WorkoutTrackPoint]]) -> [WorkoutTrackPoint]? {
        let key = Int(start.timeIntervalSince1970)
        if let exact = routes[key] { return exact }
        return routes
            .filter { abs($0.key - key) <= 120 }
            .min { abs($0.key - key) < abs($1.key - key) }?
            .value
    }

    /// Picks the per-second HR series for a workout. Same nearest-within-two-minutes match as the
    /// GPS route: the summary and detail files share the session-start timestamp but their file ids
    /// can differ by a second or two.
    private static func heartRateSeries(forWorkoutStart start: Date,
                                        in series: [Int: [WorkoutHRSample]]) -> [WorkoutHRSample]? {
        let key = Int(start.timeIntervalSince1970)
        if let exact = series[key] { return exact }
        return series
            .filter { abs($0.key - key) <= 120 }
            .min { abs($0.key - key) < abs($1.key - key) }?
            .value
    }

    /// Builds an HKWorkoutRoute from a band GPS track. Two HealthKit constraints drive the
    /// cleanup here: CoreLocation treats a sample with negative `horizontalAccuracy` as invalid
    /// and `insertRouteData` rejects the whole batch if any is invalid; and the builder requires
    /// strictly increasing timestamps. So duplicate/out-of-order fixes are dropped and the band's
    /// hdop is mapped to a positive metre estimate.
    private func attachRoute(_ track: [WorkoutTrackPoint], to workout: HKWorkout) async throws {
        var lastTime = -Double.greatestFiniteMagnitude
        let locations: [CLLocation] = track
            .sorted { $0.date < $1.date }
            .compactMap { p in
                let t = p.date.timeIntervalSince1970
                guard t > lastTime else { return nil }   // strictly increasing — drop dupes
                lastTime = t
                // hdop is a dimensionless dilution of precision; scale by a nominal 5 m UERE to
                // get a usable accuracy estimate. Missing/zero hdop (V1 tracks) → a conservative
                // fixed value, which keeps the sample valid so HealthKit accepts the route.
                let accuracy: CLLocationAccuracy
                if let hdop = p.hdop, hdop > 0 { accuracy = hdop * 5.0 } else { accuracy = 10.0 }
                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                    altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                    course: -1, speed: p.speed ?? -1, timestamp: p.date
                )
            }
        guard locations.count >= 2 else { return }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }

    // MARK: - Workout type mapping

    private static func activityType(_ kind: WorkoutKind) -> HKWorkoutActivityType {
        switch kind {
        case .running, .trailRun, .treadmill:        .running
        case .hiking, .trekking:                     .hiking
        case .walking:                               .walking
        case .outdoorCycling, .indoorCycling:        .cycling
        case .poolSwim, .openWaterSwim:              .swimming
        case .elliptical:                            .elliptical
        case .rowing, .rowingMachine:                .rowing
        case .jumpRoping:                            .jumpRope
        case .hiit:                                  .highIntensityIntervalTraining
        case .yoga:                                  .yoga
        case .strengthTraining:                      .traditionalStrengthTraining
        case .freeTraining, .other:                  .other
        }
    }

    /// WMO weather code (Open-Meteo) → HKWeatherCondition for workout metadata. Unknown codes map to
    /// `.none` so Health simply omits the condition icon rather than showing a wrong one.
    private static func weatherCondition(wmo: Int) -> HKWeatherCondition {
        switch wmo {
        case 0:            return .clear
        case 1:            return .fair
        case 2:            return .partlyCloudy
        case 3:            return .cloudy
        case 45, 48:       return .foggy
        case 51, 53, 55:   return .drizzle
        case 56, 57:       return .freezingDrizzle
        case 61, 63, 65:   return .showers
        case 66, 67:       return .freezingRain
        case 71, 73, 75, 77: return .snow
        case 80, 81:       return .scatteredShowers
        case 82:           return .showers
        case 85, 86:       return .snow
        case 95, 96, 99:   return .thunderstorms
        default:           return .none
        }
    }

    private static func swimmingLocation(_ kind: WorkoutKind) -> HKWorkoutSwimmingLocationType? {
        switch kind {
        case .poolSwim:      .pool
        case .openWaterSwim: .openWater
        default:             nil
        }
    }

    private static func isIndoor(_ kind: WorkoutKind) -> Bool {
        switch kind {
        case .treadmill, .indoorCycling, .elliptical, .rowingMachine, .hiit, .yoga, .freeTraining, .strengthTraining: true
        default: false
        }
    }

    private static func distanceType(_ kind: WorkoutKind, _ walkRun: HKQuantityType,
                                     _ cycling: HKQuantityType, _ swimming: HKQuantityType) -> HKQuantityType {
        switch kind {
        case .outdoorCycling, .indoorCycling: cycling
        case .poolSwim, .openWaterSwim:        swimming
        default:                               walkRun
        }
    }

    /// Quantity type for the in-workout GPS/summary speed series.
    private static func speedType(_ kind: WorkoutKind) -> HKQuantityType? {
        switch kind {
        case .running, .trailRun, .treadmill:     HKQuantityType(.runningSpeed)
        case .walking, .hiking, .trekking:        HKQuantityType(.walkingSpeed)
        case .outdoorCycling, .indoorCycling:     HKQuantityType(.cyclingSpeed)
        default:                                  nil
        }
    }

    static func swimmingStrokeStyle(_ name: String) -> HKSwimmingStrokeStyle {
        switch name.lowercased() {
        case "medley", "mixed": return .mixed
        case "breaststroke":    return .breaststroke
        case "freestyle":       return .freestyle
        case "backstroke":      return .backstroke
        case "butterfly":       return .butterfly
        case "kickboard":       return .kickboard
        default:                return .unknown
        }
    }

    // MARK: - Cardio Recovery (heartRateRecoveryOneMinute)
    //
    // The band's 1 Hz workout series stops exactly at the workout end (sample count == duration),
    // so recovery can't come from the workout file alone. But the daily per-minute file keeps
    // sampling HR after the workout: once that batch arrives, each recent workout's end-of-exercise
    // peak (the 1 Hz samples already written to Health) is paired with the per-minute reading
    // closest to end+60 s. Both readings are real band measurements — nothing synthesized. This
    // runs on the daily-details path (not writeWorkouts) because the workout may have been written
    // by an earlier targeted post-workout sync, before the minute file existed.

    func writeHeartRateRecoveries(minutes: [ActivityMinuteSample]) async throws -> Int {
        guard canShare(hrRecovery) else { return 0 }
        let hrMinutes = minutes
            .compactMap { m in m.heartRate.map { (date: m.date, bpm: $0) } }
            .filter { (30...250).contains($0.bpm) }
            .sorted { $0.date < $1.date }

        let now = Date()
        let windowStart = hrMinutes.first?.date.addingTimeInterval(-300) ?? now.addingTimeInterval(-7 * 86_400)
        let windowEnd = max(hrMinutes.last?.date ?? now, now)
        let workouts = try await ownWorkouts(endingBetween: windowStart, and: windowEnd)
        guard !workouts.isEmpty else { return 0 }

        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        for workout in workouts where workout.duration >= 60 {
            let realEnd: Date
            if let realEndEpoch = workout.metadata?["MiBandWorkoutRealEnd"] as? TimeInterval, realEndEpoch > 0 {
                realEnd = Date(timeIntervalSince1970: realEndEpoch)
            } else {
                realEnd = workout.endDate
            }
            let target = realEnd.addingTimeInterval(60)
            // Look in the incoming per-minute batch first; if absent (e.g. post-strength recovery HR
            // written directly to HealthKit, or workout synced in a separate batch), fall back to
            // querying this app's HR samples in [realEnd + 15, realEnd + 120].
            var candidates = hrMinutes.filter { $0.date >= realEnd.addingTimeInterval(15) && $0.date <= realEnd.addingTimeInterval(120) }
            if candidates.isEmpty,
               let stored = try? await ownHeartRateSamples(from: realEnd.addingTimeInterval(15), to: realEnd.addingTimeInterval(120)) {
                candidates = stored
            }
            guard let recovery = candidates.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
            else { continue }
            // try? — a window with no samples reports errorNoData; that just means "no recovery for
            // this one", not a batch failure.
            guard let peak = try? await ownHeartRatePeak(
                from: realEnd.addingTimeInterval(-120), to: realEnd) else { continue }
            let drop = peak - Double(recovery.bpm)
            guard (1...120).contains(drop) else { continue }   // HR must actually have dropped
            let key = Int(workout.startDate.timeIntervalSince1970)
            var meta = syncMetadata("mb-hrr-\(key)")
            meta[HKMetadataKeyHeartRateRecoveryTestType] = HKHeartRateRecoveryTestType.maxExercise.rawValue
            meta[HKMetadataKeyHeartRateRecoveryActivityType] = workout.workoutActivityType.rawValue
            meta[HKMetadataKeyHeartRateRecoveryActivityDuration] = HKQuantity(
                unit: .second(),
                doubleValue: max(60, realEnd.timeIntervalSince(workout.startDate))
            )
            meta[HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate] = HKQuantity(
                unit: bpm,
                doubleValue: peak
            )
            samples.append(HKQuantitySample(
                type: hrRecovery,
                quantity: HKQuantity(unit: bpm, doubleValue: drop),
                start: target, end: target,
                metadata: meta
            ))
        }
        return try await save(samples)
    }

    /// One-time cleanup of pre-2020 corrupted records (1928, 1969, 1970) written by early builds
    /// before file-ID mismatch and timestamp bounds were enforced.
    func cleanupPre2020CorruptedSamplesIfNeeded() async {
        guard isAvailable, !UserDefaults.standard.bool(forKey: Self.pre2020CleanupKey) else { return }
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let before2020 = HKQuery.predicateForSamples(withStart: .distantPast, end: Self.minValidDate, options: .strictStartDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, before2020])
        let typesToClean: [HKSampleType] = [
            heartRate, restingHR, spo2, activeEnergy, basalEnergy, respiratoryRate, stepCount, distance, physicalEffort, sleepType
        ]
        var totalDeleted = 0
        for sampleType in typesToClean where canShare(sampleType) {
            do {
                let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: sampleType, predicate: predicate)], sortDescriptors: [])
                let found = try await descriptor.result(for: store)
                if !found.isEmpty {
                    try await store.delete(found)
                    totalDeleted += found.count
                }
            } catch {
                log.error("Pre-2020 cleanup failed for \(sampleType.identifier): \(error.localizedDescription)")
                return
            }
        }
        UserDefaults.standard.set(true, forKey: Self.pre2020CleanupKey)
        if totalDeleted > 0 {
            log.info("Pre-2020 cleanup removed \(totalDeleted) corrupted historical sample(s)")
        }
    }

    private func ownHeartRateSamples(from start: Date, to end: Date) async throws -> [(date: Date, bpm: Int)] {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRate, predicate: predicate)],
            sortDescriptors: []
        )
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let found = try await descriptor.result(for: store)
        return found.map { (date: $0.startDate, bpm: Int($0.quantity.doubleValue(for: bpmUnit).rounded())) }
    }

    /// Workouts written by this app whose endDate falls in [start, end].
    private func ownWorkouts(endingBetween start: Date, and end: Date) async throws -> [HKWorkout] {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkout], Error>) in
            let q = HKSampleQuery(sampleType: workoutType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Peak of this app's own HR samples in [start, end] — the workout's 1 Hz series tail.
    private func ownHeartRatePeak(from start: Date, to end: Date) async throws -> Double? {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double?, Error>) in
            let q = HKStatisticsQuery(quantityType: heartRate, quantitySamplePredicate: predicate,
                                      options: .discreteMax) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats?.maximumQuantity()?.doubleValue(for: bpm))
            }
            store.execute(q)
        }
    }

    // MARK: - Helpers

    // MARK: - Body mass (scale)
    //
    // Writes a weight reading from the BLE scale as bodyMass, plus a derived bodyMassIndex when the
    // user's height is available in Apple Health (the scale only measures weight). Sync identifiers
    // key off the reading timestamp so a re-broadcast of the same weighing collapses to one sample.

    @discardableResult
    func writeBodyMass(_ kg: Double, date: Date, heightMeters: Double? = nil) async throws -> Int {
        guard (2...500).contains(kg) else { return 0 }   // reject implausible readings
        let key = Int(date.timeIntervalSince1970)
        var samples: [HKSample] = [
            quantity(bodyMass, .gramUnit(with: .kilo), kg, start: date, end: date, id: "mb-weight-\(key)")
        ]
        // BMI needs height: prefer the value the caller passed (the app's profile), else the most
        // recent height already in Apple Health. Without either, weight is written on its own.
        var m = heightMeters
        if m == nil { m = (try? await latestHeightMeters()) ?? nil }
        if let m, m > 0.5 {
            let bmi = kg / (m * m)
            samples.append(quantity(bodyMassIndex, .count(), bmi, start: date, end: date, id: "mb-bmi-\(key)"))
        }
        return try await save(samples)
    }

    /// Writes the user's height (entered in the app's profile) so Apple Health has it and BMI derives.
    @discardableResult
    func writeHeight(meters: Double, date: Date = Date()) async throws -> Int {
        guard (0.5...2.6).contains(meters) else { return 0 }
        return try await save([quantity(height, .meter(), meters, start: date, end: date, id: "mb-height")])
    }

    /// Most recent height sample from Apple Health, in metres, or nil if none/denied.
    private func latestHeightMeters() async throws -> Double? {
        try await latestQuantity(of: height, unit: .meter())
    }

    /// Most recent body-mass sample from Apple Health (the BLE scale keeps it fresh), in kg.
    /// Feeds the MET math (physical effort, average workout METs); nil when none/denied.
    private func latestBodyMassKg() async throws -> Double? {
        try await latestQuantity(of: bodyMass, unit: .gramUnit(with: .kilo))
    }

    private func latestQuantity(of type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double?, Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// Tanaka estimate (208 − 0.7·idade) from the Health profile's date of birth; 190 bpm when
    /// the characteristic is missing or denied. Drives the workout effort score only — never stored.
    private func estimatedMaxHeartRate() -> Double {
        guard let dob = try? store.dateOfBirthComponents(),
              let birth = Calendar.current.date(from: dob) else { return 190 }
        let age = Date().timeIntervalSince(birth) / 31_557_600
        guard (5...120).contains(age) else { return 190 }
        return 208 - 0.7 * age
    }

    /// Daily Basal Metabolic Rate (kcal/day) via Mifflin-St Jeor from the user's latest HealthKit
    /// weight, height, age, and biological sex, falling back to adult defaults when unavailable.
    private func estimatedDailyBasalKilocalories() async -> Double {
        let weightKg = ((try? await latestBodyMassKg()) ?? nil) ?? 70.0
        let heightMeters = ((try? await latestHeightMeters()) ?? nil) ?? 1.70
        let ageYears: Double = {
            guard let dob = try? store.dateOfBirthComponents(),
                  let birth = Calendar.current.date(from: dob) else { return 35.0 }
            let a = Date().timeIntervalSince(birth) / 31_557_600
            return (5...120).contains(a) ? a : 35.0
        }()
        let sex = (try? store.biologicalSex().biologicalSex) ?? .notSet
        return Self.mifflinStJeorDailyKcal(weightKg: weightKg, heightCm: heightMeters * 100.0,
                                           ageYears: ageYears, sex: sex)
    }

    static func mifflinStJeorDailyKcal(weightKg: Double, heightCm: Double,
                                       ageYears: Double, sex: HKBiologicalSex) -> Double {
        let sexOffset: Double
        switch sex {
        case .male:   sexOffset = 5.0
        case .female: sexOffset = -161.0
        case .other, .notSet: sexOffset = -78.0
        @unknown default: sexOffset = -78.0
        }
        let bmr = 10.0 * weightKg + 6.25 * heightCm - 5.0 * ageYears + sexOffset
        return min(4000.0, max(800.0, bmr))
    }

    private func quantity(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double,
                          start: Date, end: Date, id: String, version: Int? = nil) -> HKQuantitySample {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, metadata: syncMetadata(id, version: version))
    }

    /// `version` defaults to the constant syncVersion — fine for immutable data (sleep, manual,
    /// workout). The reconciled-activity path passes a monotonic version so re-syncs can replace.
    private func syncMetadata(_ id: String, version: Int? = nil) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version ?? syncVersion]
    }

    @discardableResult
    private func save(_ samples: [HKSample]) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        try await store.save(samples)
        return samples.count
    }
}

// MARK: - Errors

enum HealthError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is not available on this device."
        }
    }
}
