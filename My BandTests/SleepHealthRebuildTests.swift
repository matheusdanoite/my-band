import Testing
import Foundation
import HealthKit
@testable import My_Band

// Fixture: the first night in a real Apple Health export (2026-06-23), written before the stable
// identifiers — one in-bed sample and 34 stages with the band's cumulative re-reports stacked on top of
// each other (deep 05:01–05:13 next to deep 05:01–05:22, REM 07:02–07:30 over core 07:05–07:30).
@MainActor
struct SleepHealthRebuildTests {

    private typealias Sample = HealthKitManager.StoredSleepSample

    private func t(_ hm: String, day: String = "2026-06-23") -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        guard let d = f.date(from: "\(day) \(hm)") else { fatalError("bad fixture date") }
        return d
    }

    private func s(_ start: String, _ end: String, _ value: HKCategoryValueSleepAnalysis) -> Sample {
        Sample(start: t(start), end: t(end), value: value.rawValue)
    }

    private func p(_ start: String, _ end: String, _ type: SleepPhaseType) -> SleepPhase {
        SleepPhase(startDate: t(start), endDate: t(end), type: type)
    }

    private var stackedNight: [Sample] {
        [
            s("04:22", "04:54", .asleepCore), s("04:22", "09:01", .inBed), s("04:54", "04:58", .asleepDeep),
            s("04:58", "05:01", .awake), s("05:01", "05:13", .asleepDeep), s("05:01", "05:22", .asleepDeep),
            s("05:13", "05:16", .asleepREM), s("05:16", "05:24", .asleepDeep), s("05:22", "05:28", .asleepREM),
            s("05:24", "05:25", .asleepCore), s("05:25", "05:28", .asleepREM), s("05:28", "05:31", .awake),
            s("05:31", "05:54", .asleepDeep), s("05:31", "05:56", .asleepDeep), s("05:54", "05:56", .asleepCore),
            s("05:56", "05:59", .asleepREM), s("05:59", "06:02", .awake), s("06:02", "06:25", .asleepREM),
            s("06:25", "06:30", .awake), s("06:30", "06:59", .asleepREM), s("06:59", "07:02", .awake),
            s("07:02", "07:05", .asleepREM), s("07:02", "07:30", .asleepREM), s("07:05", "07:30", .asleepCore),
            s("07:30", "07:33", .awake), s("07:33", "07:36", .asleepREM), s("07:33", "08:00", .asleepREM),
            s("07:36", "08:00", .asleepCore), s("08:00", "08:09", .awake), s("08:09", "08:12", .asleepREM),
            s("08:09", "08:31", .asleepREM), s("08:12", "08:31", .asleepCore), s("08:31", "08:32", .awake),
            s("08:32", "08:35", .asleepREM), s("08:35", "09:01", .asleepCore),
        ]
    }

    // MARK: - needsRebuild

    @Test func aStackedNightNeedsRebuildingAndAWrittenOnceNightDoesNot() {
        #expect(HealthKitManager.needsRebuild(stackedNight))

        let writtenOnce = [s("04:22", "09:01", .inBed), s("04:22", "06:00", .asleepCore), s("06:00", "09:01", .asleepDeep)]
        #expect(!HealthKitManager.needsRebuild(writtenOnce))

        let twoInBed = [s("04:22", "06:00", .inBed), s("04:22", "09:01", .inBed), s("04:22", "09:01", .asleepCore)]
        #expect(HealthKitManager.needsRebuild(twoInBed))
    }

    // MARK: - collapsedPhases

    @Test func collapsingKeepsEveryMinuteOnceWithTheShortestSampleFirst() {
        let phases = HealthKitManager.collapsedPhases(stackedNight)
        #expect(phases == [
            p("04:22", "04:54", .light), p("04:54", "04:58", .deep), p("04:58", "05:01", .awake),
            p("05:01", "05:24", .deep), p("05:24", "05:28", .rem), p("05:28", "05:31", .awake),
            p("05:31", "05:56", .deep), p("05:56", "05:59", .rem), p("05:59", "06:02", .awake),
            p("06:02", "06:25", .rem), p("06:25", "06:30", .awake), p("06:30", "06:59", .rem),
            p("06:59", "07:02", .awake), p("07:02", "07:30", .rem), p("07:30", "07:33", .awake),
            p("07:33", "08:00", .rem), p("08:00", "08:09", .awake), p("08:09", "08:31", .rem),
            p("08:31", "08:32", .awake), p("08:32", "08:35", .rem), p("08:35", "09:01", .light),
        ])

        // Every minute of the night once: 279 min covered, 249 of them asleep — the export summed 378.
        let covered = phases.reduce(0) { $0 + $1.duration }
        let asleep = phases.filter { $0.type != .awake }.reduce(0) { $0 + $1.duration }
        #expect(covered == 279 * 60)
        #expect(asleep == 249 * 60)
    }

    @Test func atTheSameStartTheShortestStageWinsItsSpan() {
        let phases = HealthKitManager.collapsedPhases([
            s("01:00", "02:00", .asleepCore),
            s("01:00", "01:20", .asleepDeep),
        ])
        #expect(phases == [p("01:00", "01:20", .deep), p("01:20", "02:00", .light)])
    }

    // MARK: - overlapGroups

    @Test func nightsGroupByTransitiveOverlapOnly() {
        let chained = [s("00:00", "02:00", .inBed), s("01:30", "03:30", .inBed), s("03:00", "05:00", .inBed)]
        let separate = [s("22:00", "23:00", .inBed)]
        let groups = HealthKitManager.overlapGroups(chained + separate, start: { $0.start }, end: { $0.end })
        #expect(groups.map(\.count) == [3, 1])

        let touching = [s("00:00", "02:00", .inBed), s("02:00", "03:00", .inBed)]
        #expect(HealthKitManager.overlapGroups(touching, start: { $0.start }, end: { $0.end }).count == 2)
    }
}
