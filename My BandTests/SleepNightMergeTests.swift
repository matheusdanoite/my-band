import Testing
import Foundation
import SwiftData
@testable import My_Band

// A night reaches Apple Health as several reports: a file fetched mid-night, the morning file, and
// whatever is already stored locally. writeSleep clears everything it wrote inside the night's window
// before rewriting, so the merge must keep the most complete report's view — a partial report
// written after it must not truncate the night.
@MainActor
struct SleepNightMergeTests {

    private func date(_ hm: String, nextDay: Bool = false) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        guard let d = f.date(from: "\(nextDay ? "2026-09-13" : "2026-09-12") \(hm)") else {
            fatalError("bad fixture date")
        }
        return d
    }

    private func phase(_ start: String, _ end: String, _ type: SleepPhaseType,
                       startNextDay: Bool = true, endNextDay: Bool = true) -> SleepPhase {
        SleepPhase(startDate: date(start, nextDay: startNextDay), endDate: date(end, nextDay: endNextDay), type: type)
    }

    /// Fetched at 3 a.m., mid-night.
    private func partialNight() -> SleepSession {
        SleepSession(startDate: date("23:00"), endDate: date("03:00", nextDay: true), phases: [
            phase("23:00", "01:00", .light, startNextDay: false),
            phase("01:00", "03:00", .deep),
        ], rawDataHash: 1)
    }

    /// The morning file for the same bedtime, with 1 a.m. re-scored.
    private func fullNight() -> SleepSession {
        SleepSession(startDate: date("23:00"), endDate: date("07:00", nextDay: true), phases: [
            phase("23:00", "00:30", .light, startNextDay: false),
            phase("00:30", "02:00", .deep),
            phase("02:00", "03:00", .rem),
            phase("03:00", "07:00", .light),
        ], rawDataHash: 2)
    }

    // MARK: - mergedPhases

    @Test func theReportReachingFurthestIntoTheNightWinsInAnyOrder() {
        let full = fullNight()
        #expect(HealthKitManager.mergedPhases([partialNight(), full]) == full.phases)
        #expect(HealthKitManager.mergedPhases([full, partialNight()]) == full.phases)
    }

    @Test func earlierReportsStillFillTimeTheLaterOneDoesNotCover() {
        let earlierBedtime = SleepSession(startDate: date("22:30"), endDate: date("03:00", nextDay: true), phases: [
            phase("22:30", "23:00", .awake, startNextDay: false, endNextDay: false),
            phase("23:00", "03:00", .light, startNextDay: false),
        ])
        let full = fullNight()
        #expect(HealthKitManager.mergedPhases([earlierBedtime, full])
                == [phase("22:30", "23:00", .awake, startNextDay: false, endNextDay: false)] + full.phases)
    }

    // MARK: - Stored reports

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: BandDevice.self, SleepSession.self, ActivityDay.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func storedReportsOfTheSameNightJoinAPartialWrite() throws {
        let container = try makeContainer()
        let full = fullNight()
        // Overlaps the full night but not the partial one: reachable only transitively. It also ends
        // later, so it wins the 06:45–07:00 overlap.
        let morningNap = SleepSession(startDate: date("06:45", nextDay: true), endDate: date("08:00", nextDay: true),
                                      phases: [phase("06:45", "08:00", .light)], rawDataHash: 3)
        let nextNight = SleepSession(startDate: date("23:00", nextDay: true),
                                     endDate: date("23:00", nextDay: true).addingTimeInterval(8 * 3600),
                                     phases: [], rawDataHash: 4)
        [full, morningNap, nextNight].forEach(container.mainContext.insert)
        try container.mainContext.save()

        let partial = partialNight()
        let batch = BandSyncer.withStoredReports([partial], in: container.mainContext)

        #expect(batch.count == 3)
        #expect(batch.contains { $0 === full })
        #expect(batch.contains { $0 === morningNap })
        #expect(!batch.contains { $0 === nextNight })
        #expect(HealthKitManager.mergedPhases(batch) == [
            phase("23:00", "00:30", .light, startNextDay: false),
            phase("00:30", "02:00", .deep),
            phase("02:00", "03:00", .rem),
            phase("03:00", "06:45", .light),
            phase("06:45", "08:00", .light),
        ])
    }

    @Test func latestSessionIsTheOneEndingLastNotAnyCopyWithTheSameBedtime() throws {
        let container = try makeContainer()
        let full = fullNight()
        let previousNight = SleepSession(startDate: date("23:00").addingTimeInterval(-86_400),
                                         endDate: date("07:00"), phases: [], rawDataHash: 5)
        [full, partialNight(), previousNight].forEach(container.mainContext.insert)
        try container.mainContext.save()

        #expect(BandSyncer.mostRecentSleepSession(in: container.mainContext) === full)
    }
}
