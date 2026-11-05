import Testing
import Foundation
@testable import My_Band

// The one-time repair rewrites every stored night, so its guard is what keeps it from making things
// worse: a night Apple Health holds more of than the store must survive untouched, while a night the
// partial-report bug truncated must be rewritten.
@MainActor
struct SleepHistoryRepairTests {

    private func date(_ hm: String, nextDay: Bool = false) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        guard let d = f.date(from: "\(nextDay ? "2026-09-13" : "2026-09-12") \(hm)") else {
            fatalError("bad fixture date")
        }
        return d
    }

    private func phase(_ start: String, _ end: String, _ type: SleepPhaseType, startNextDay: Bool = true) -> SleepPhase {
        SleepPhase(startDate: date(start, nextDay: startNextDay), endDate: date(end, nextDay: true), type: type)
    }

    private var fullNightPhases: [SleepPhase] {
        [
            phase("23:00", "00:30", .light, startNextDay: false),
            phase("00:30", "02:00", .deep),
            phase("02:00", "03:00", .rem),
            phase("03:00", "07:00", .light),
        ]
    }

    // MARK: - healthHoldsMore

    @Test func aNightTruncatedByAPartialReportIsRewritten() {
        // Apple Health after the bug: the partial report's in-bed and stages up to 03:00, plus the
        // full night's stage that lay after that window.
        let existing = [
            (start: date("23:00"), end: date("03:00", nextDay: true), asleep: false),
            (start: date("23:00"), end: date("01:00", nextDay: true), asleep: true),
            (start: date("01:00", nextDay: true), end: date("03:00", nextDay: true), asleep: true),
            (start: date("03:00", nextDay: true), end: date("07:00", nextDay: true), asleep: true),
        ]
        #expect(HealthKitManager.healthHoldsMore(existing, than: fullNightPhases,
                                                 from: date("23:00"), to: date("07:00", nextDay: true)) == nil)
    }

    @Test func aNightHealthHoldsFurtherThanTheStoreIsKept() {
        // The store lost the morning report; only the 3 a.m. one is left.
        let existing = [
            (start: date("23:00"), end: date("07:00", nextDay: true), asleep: false),
            (start: date("23:00"), end: date("07:00", nextDay: true), asleep: true),
        ]
        let partial = [phase("23:00", "03:00", .light, startNextDay: false)]
        #expect(HealthKitManager.healthHoldsMore(existing, than: partial,
                                                 from: date("23:00"), to: date("03:00", nextDay: true)) != nil)
    }

    @Test func clearlyMoreTimeAsleepInHealthIsKeptButDuplicatesCountOnce() {
        let window = (start: date("23:00"), end: date("07:00", nextDay: true))
        let storedWithLongWake = [
            phase("23:00", "01:00", .light, startNextDay: false),
            phase("01:00", "03:00", .awake),
            phase("03:00", "07:00", .light),
        ]
        let asleepAllNight = [(start: window.start, end: window.end, asleep: true)]
        #expect(HealthKitManager.healthHoldsMore(asleepAllNight, than: storedWithLongWake,
                                                 from: window.start, to: window.end) != nil)

        // The same night written twice by an older build: 16 h of samples, 8 h of sleep.
        let duplicated = asleepAllNight + asleepAllNight
        #expect(HealthKitManager.healthHoldsMore(duplicated, than: fullNightPhases,
                                                 from: window.start, to: window.end) == nil)
    }

    @Test func aNightMissingFromHealthIsWritten() {
        #expect(HealthKitManager.healthHoldsMore([], than: fullNightPhases,
                                                 from: date("23:00"), to: date("07:00", nextDay: true)) == nil)
    }

    // MARK: - Stored reports

    @Test func implausibleStoredReportsAreLeftOut() {
        let now = date("12:00", nextDay: true)
        func report(_ start: Date, _ end: Date) -> SleepSession { SleepSession(startDate: start, endDate: end, phases: []) }

        #expect(BandSyncer.isRepairableReport(report(date("23:00"), date("07:00", nextDay: true)), now: now))
        #expect(!BandSyncer.isRepairableReport(report(date("07:00", nextDay: true), date("23:00")), now: now))
        #expect(!BandSyncer.isRepairableReport(report(date("23:00"), date("23:00").addingTimeInterval(30 * 3600)), now: now))
        #expect(!BandSyncer.isRepairableReport(report(Date(timeIntervalSince1970: 3600), Date(timeIntervalSince1970: 7200)), now: now))
        #expect(!BandSyncer.isRepairableReport(report(now.addingTimeInterval(2 * 86_400), now.addingTimeInterval(2 * 86_400 + 3600)), now: now))
    }

    @Test func aStageStampedHoursAwayFromItsReportIsIgnoredByTheMerge() {
        let misread = SleepPhase(startDate: date("23:00").addingTimeInterval(2 * 86_400),
                                 endDate: date("23:00").addingTimeInterval(2 * 86_400 + 3600), type: .deep)
        let report = SleepSession(startDate: date("23:00"), endDate: date("07:00", nextDay: true),
                                  phases: fullNightPhases + [misread])
        #expect(HealthKitManager.mergedPhases([report]) == fullNightPhases)
    }
}
