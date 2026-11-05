import Testing
import Foundation
import SwiftData
@testable import My_Band

// How reports of one night are kept: one stored report per distinct file, its bytes only on the
// report reaching furthest, and the fetch time that lets GetSleepStateIntent tell an open night still
// growing from one that stopped. Times follow the hardware night of 2026-10-01 (bed 01:00).
@MainActor
struct SleepReportStoreTests {

    private let bed = Date(timeIntervalSince1970: 1_790_827_200)        // 2026-10-01 01:00 -03
    private func at(_ minutes: Int) -> Date { bed.addingTimeInterval(TimeInterval(minutes * 60)) }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: BandDevice.self, SleepSession.self, ActivityDay.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func report(until minutes: Int, hash: Int, last: SleepPhaseType = .light) -> SleepSession {
        SleepSession(startDate: bed, endDate: at(minutes), phases: [
            SleepPhase(startDate: bed, endDate: at(minutes - 10), type: .deep),
            SleepPhase(startDate: at(minutes - 10), endDate: at(minutes), type: last),
        ], rawDataHash: hash)
    }

    // MARK: - storeReport

    @Test func theSameBytesAgainRefreshTheStoredReportInsteadOfAddingOne() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncer = BandSyncer()
        let first = syncer.storeReport(report(until: 394, hash: 7), raw: Data([1]), awakeFlag: 0, seenAt: at(395), context)
        let again = syncer.storeReport(report(until: 394, hash: 7), raw: Data([1]), awakeFlag: 0, seenAt: at(414), context)

        #expect(again === first)
        #expect(try context.fetchCount(FetchDescriptor<SleepSession>()) == 1)
        #expect(first.fetchedAt == at(414))
        #expect(first.awakeFlag == 0)
    }

    @Test func onlyTheReportReachingFurthestKeepsTheFileBytes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncer = BandSyncer()
        let morning = syncer.storeReport(report(until: 394, hash: 1), raw: Data([1]), awakeFlag: 0, seenAt: at(395), context)
        let noon = syncer.storeReport(report(until: 697, hash: 2), raw: Data([2]), awakeFlag: 0, seenAt: at(698), context)
        // Same end, flag flipped: the band closing the night. The latest fetch is the one to keep.
        let closed = syncer.storeReport(report(until: 697, hash: 3), raw: Data([3]), awakeFlag: 1, seenAt: at(857), context)

        #expect(morning.rawData == nil)
        #expect(noon.rawData == nil)
        #expect(closed.rawData == Data([3]))
        #expect(BandSyncer.mostRecentSleepSession(in: context) === closed)
    }

    @Test func anImportedReportLeavesTheFetchTimeAlone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncer = BandSyncer()
        let imported = syncer.storeReport(report(until: 697, hash: 9), raw: Data([9]), awakeFlag: 1, seenAt: nil, context)
        #expect(imported.fetchedAt == nil)
        #expect(imported.rawData == Data([9]))
    }

    @Test func onlyReportsFetchedSinceTheFetchTimeExistedAndNotYetWrittenArePending() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncer = BandSyncer()
        let lockedFetch = syncer.storeReport(report(until: 394, hash: 1), raw: Data([1]), awakeFlag: 0, seenAt: at(395), context)
        let written = syncer.storeReport(report(until: 697, hash: 2), raw: Data([2]), awakeFlag: 0, seenAt: at(698), context)
        written.healthKitSynced = true
        let legacy = report(until: 300, hash: 3)        // stored by an older version: no fetch time
        context.insert(legacy)
        try context.save()

        let pending = BandSyncer.pendingSleepReports(in: context)
        #expect(pending.count == 1)
        #expect(pending.first === lockedFetch)
    }

    @Test func aDiagnosticLogYieldsEachDistinctSleepFileOnce() {
        let hex = Fixtures.sleepDetailsV5ThreeRevisions
        let log = """
        2026-10-01 07:34:52.135-0300 [DBG] Sync:   raw \(hex)
        2026-10-01 07:34:52.213-0300 [WRN] Sync: Asked for 982fbe6af40400, band sent c0dabd6af40521
        2026-10-01 07:36:39.078-0300 [DBG] Sync:   raw \(hex)
        2026-10-01 07:36:40.000-0300 [DBG] Sync:   raw \(Fixtures.dailyDetailsV4Short)
        """
        let files = BandSyncer.sleepFiles(inLog: log)
        #expect(files.count == 1)
        #expect(files.first?.data == Fixtures.bytes(hex))
        #expect(files.first?.meta.isSleepDetails == true)
    }

    // MARK: - SleepStateRule

    private func stored(until minutes: Int, flag: Int?, fetchedAt fetched: Int?, last: SleepPhaseType = .light) -> SleepSession {
        let session = report(until: minutes, hash: 0, last: last)
        session.awakeFlag = flag
        session.fetchedAt = fetched.map(at)
        return session
    }

    @Test func anOpenNightStillGrowingAtTheFetchIsSleep() {
        // 07:34 sync: wake 07:34, flag 0.
        let session = stored(until: 394, flag: 0, fetchedAt: 395)
        #expect(SleepStateRule.evaluate(session, now: at(400)).asleep)
    }

    @Test func anOpenNightThatStoppedGrowingIsAwakeBeforeTheBandClosesIt() {
        // 13:31 sync: wake frozen at 12:37, flag still 0. The old rule answered "asleep" here.
        let session = stored(until: 697, flag: 0, fetchedAt: 751)
        #expect(!SleepStateRule.evaluate(session, now: at(752)).asleep)
    }

    @Test func aClosedNightIsAwake() {
        #expect(!SleepStateRule.evaluate(stored(until: 697, flag: 1, fetchedAt: 698), now: at(699)).asleep)
    }

    @Test func aGrowingNightFetchedLongAgoSaysNothingAboutNow() {
        #expect(!SleepStateRule.evaluate(stored(until: 394, flag: 0, fetchedAt: 395), now: at(460)).asleep)
    }

    @Test func lyingAwakeInAnOpenNightIsAwake() {
        #expect(!SleepStateRule.evaluate(stored(until: 394, flag: 0, fetchedAt: 395, last: .awake), now: at(396)).asleep)
    }

    @Test func reportsStoredBeforeTheFlagFallBackToTheOneHourRule() {
        let legacy = stored(until: 394, flag: nil, fetchedAt: nil)
        #expect(SleepStateRule.evaluate(legacy, now: at(420)).asleep)
        #expect(!SleepStateRule.evaluate(legacy, now: at(460)).asleep)
    }
}
