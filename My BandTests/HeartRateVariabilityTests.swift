import Testing
import Foundation
@testable import My_Band

// Beat-to-beat intervals from the sleep file (type-1 packets) → heartbeat series + SDNN per minute.
// The real-night expectations were computed independently (a Python port of the same rules) from the
// fixture's bytes; the synthetic cases pin each rule on its own.
@MainActor
struct HeartRateVariabilityTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_829_958.797)

    // MARK: - Real night

    private func realNight() -> ParsedSleep {
        let data = Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions)
        guard let meta = XiaomiActivityFileMeta(Data(data.prefix(7))) else { fatalError("fixture id") }
        return SleepDetailsParser.parse(data, meta: meta)
    }

    @Test func theParserReadsEachBlockAtItsOwnMillisecondStamp() {
        let blocks = realNight().beatWindows
        #expect(blocks.count == 27)
        #expect(blocks.first?.start == t0)                                     // 2026-10-01 01:45:58.797 -03
        #expect(blocks.first?.intervalsMs.count == 950)
        #expect(blocks.first?.intervalsMs.prefix(5) == [1200, 640, 600, 600, 640])
        #expect(blocks.allSatisfy { $0.intervalsMs.allSatisfy { $0 % 40 == 0 } })   // 25 Hz PPG
        #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test func aRealNightYieldsTheExpectedMinuteValues() {
        let blocks = realNight().beatWindows
        let minutes = blocks.flatMap(HeartRateVariability.minuteSDNN)
        #expect(minutes.count == 264)
        let sorted = minutes.map(\.sdnnMs).sorted()
        #expect(abs(sorted[sorted.count / 2] - 31.9887) < 0.001)

        let intervals = blocks.flatMap(\.intervalsMs)
        let rejected = blocks.reduce(0) { $0 + HeartRateVariability.accepted($1.intervalsMs).filter { !$0 }.count }
        #expect(intervals.count == 19_699)
        #expect(rejected == 349)

        let beats = blocks.flatMap(HeartRateVariability.beats)
        #expect(beats.count == 19_725)
        #expect(beats.filter(\.precededByGap).count == 375)
    }

    @Test func theFirstMinutesOfTheNightMatchTheReference() {
        guard let first = realNight().beatWindows.first else { Issue.record("no block"); return }
        let minutes = HeartRateVariability.minuteSDNN(first)
        #expect(minutes.map(\.intervals) == [94, 97, 96, 91, 79, 98, 97, 88, 95, 92])
        #expect(minutes.map { ($0.sdnnMs * 1000).rounded() / 1000 } == [20.107, 20.077, 19.664, 28.108, 65.779,
                                                                        27.093, 32.576, 39.727, 36.998, 21.559])
        #expect(minutes.first?.start == t0)
        #expect(minutes.first?.end == t0.addingTimeInterval(60))
    }

    @Test func aRealNightYieldsOvernightRespiratoryRateFromRSA() {
        let blocks = realNight().beatWindows
        let resp = blocks.compactMap(HeartRateVariability.respiratoryRate)
        #expect(resp.count == 27)
        #expect(resp.allSatisfy { (13.0 ... 17.0).contains($0.breathsPerMinute) })
        #expect(resp.first?.breathsPerMinute == 16.7)
        #expect(resp.first?.start == t0)
    }

    // MARK: - Rules

    @Test func implausibleAndOutOfLineIntervalsAreRejected() {
        var intervals = Array(repeating: 1000, count: 21)
        intervals[3] = 2100     // outside 300–2000 ms: a missed beat
        intervals[10] = 1250    // 25% above its neighbourhood
        intervals[15] = 1160    // 16%: still a heartbeat
        let accepted = HeartRateVariability.accepted(intervals)
        #expect(accepted.indices.filter { !accepted[$0] } == [3, 10])
    }

    @Test func beatsKeepTheirTimeButFlagTheIntervalsNotToMeasureAcross() {
        let window = BeatWindow(start: t0, intervalsMs: [1000, 1000, 2600, 1000, 0, 1000] + Array(repeating: 1000, count: 6))
        let beats = HeartRateVariability.beats(window)
        #expect(beats.prefix(6) == [
            .init(offset: 0, precededByGap: true),       // the block's first beat
            .init(offset: 1, precededByGap: false),
            .init(offset: 2, precededByGap: false),
            .init(offset: 4.6, precededByGap: true),     // after the 2.6 s artifact
            .init(offset: 5.6, precededByGap: false),
            .init(offset: 6.6, precededByGap: true),     // the zero interval added no beat
        ])
    }

    @Test func eachCleanFullMinuteGetsItsOwnValue() {
        // 150 s of a steady alternation (960/1040 ms): two full minutes, then 30 s that don't count.
        let intervals = (0 ..< 150).map { $0.isMultiple(of: 2) ? 960 : 1040 }
        let minutes = HeartRateVariability.minuteSDNN(BeatWindow(start: t0, intervalsMs: intervals))
        #expect(minutes.count == 2)
        #expect(minutes.map(\.start) == [t0, t0.addingTimeInterval(60)])
        #expect(minutes.allSatisfy { abs($0.sdnnMs - 40) < 1 })
    }

    @Test func aMinuteMostlyMadeOfArtifactsGetsNoValue() {
        var intervals = Array(repeating: 1000, count: 60)
        for i in stride(from: 0, to: 60, by: 4) { intervals[i] = 2400 }   // 25% impossible intervals
        #expect(HeartRateVariability.minuteSDNN(BeatWindow(start: t0, intervalsMs: intervals)).isEmpty)
    }

    @Test func repeatedBlocksOfLaterReportsCollapseToOne() {
        let a = BeatWindow(start: t0, intervalsMs: [1000])
        let later = BeatWindow(start: t0.addingTimeInterval(605), intervalsMs: [900])
        let again = BeatWindow(start: t0, intervalsMs: [1000, 1000])
        #expect(HeartRateVariability.distinct([later, a, again]) == [again, later])
    }

    @Test func theSeriesIdentifierKeepsTheMilliseconds() {
        #expect(HealthKitManager.heartbeatSeriesID(BeatWindow(start: t0, intervalsMs: [])) == "mb-beats-1790829958797")
    }
}
