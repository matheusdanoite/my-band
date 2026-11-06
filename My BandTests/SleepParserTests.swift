import Testing
import Foundation
import HealthKit
@testable import My_Band

// Synthetic sleep files built to the documented layouts — the fixtures hold no real sleep capture
// yet. They pin the byte offsets both parsers depend on, and which parser each file id routes to:
// subtype 0x03 used to go through SleepDetailsParser, whose offsets don't fit its layout at all.
@MainActor
struct SleepParserTests {

    // MARK: - Byte builders

    private func le16(_ v: Int) -> [UInt8] { (0 ..< 2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le64(_ v: Int) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    /// [ts u32 LE][tz][version][flags = subtype<<2 | detail] — activity type (bit 7 clear).
    private func fileId(version: Int, subtype: Int, detail: Int) -> [UInt8] {
        le32(bed) + [0, UInt8(version), UInt8((subtype << 2) | detail)]
    }

    private func meta(_ bytes: [UInt8]) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(Data(bytes.prefix(7))) else { fatalError("bad file id") }
        return m
    }

    /// Parsers strip the trailing CRC-32 (BandSyncer validated it on reassembly).
    private let crc: [UInt8] = [0, 0, 0, 0]
    private let bed = 1_780_000_000
    private func at(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(bed + offset)) }

    // MARK: - 0x08 · SleepDetailsParser

    /// Version 2, header bit 3 set (HR section present), one type-17 stage packet.
    private func detailsFile(version: Int = 2) -> [UInt8] {
        var b = fileId(version: version, subtype: 0x08, detail: 0)
        b += [0]                                    // padding
        b += [0x10]                                 // header: bit 3 (HR) only
        b += [1]                                    // isAwake
        b += le32(bed) + le32(bed + 3 * 3600)       // bedTime, wakeupTime
        b += le16(60) + le16(2) + le32(bed) + [58, 54]   // HR: unit 60 s, 2 samples
        let words = [(1, 60), (2, 30), (3, 20)].flatMap { be16(($0.0 << 12) | $0.1) }
        b += [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 17] + be16(words.count) + words
        return b + crc
    }

    @Test func detailsParserReadsHeartRateAndDurationEncodedStages() {
        let bytes = detailsFile()
        let parsed = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes))

        #expect(parsed.heartRates.map(\.bpm) == [58, 54])
        #expect(parsed.heartRates.map(\.date) == [at(0), at(60)])
        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions[0]
        #expect(session.startDate == at(0))
        #expect(session.endDate == at(3 * 3600))
        #expect(session.phases == [
            SleepPhase(startDate: at(0), endDate: at(3600), type: .light),
            SleepPhase(startDate: at(3600), endDate: at(5400), type: .deep),
            SleepPhase(startDate: at(5400), endDate: at(6600), type: .rem),
        ])
    }

    /// A type-16 summary followed by its type-17 stages, both stamped at `ts` — one re-scoring.
    private func revision(ts: Int, _ stages: [(code: Int, minutes: Int)]) -> [UInt8] {
        func total(_ code: Int) -> Int { stages.filter { $0.code == code }.reduce(0) { $0 + $1.minutes } }
        let asleep = total(1) + total(2) + total(3)
        let summary = [UInt8(0x10)] + be16(asleep) + be16(total(0)) + be16(total(1)) + be16(total(3)) + be16(total(2)) + [0x16, 0]
        let words = stages.flatMap { be16(($0.code << 12) | $0.minutes) }
        return [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(ts) + [0, 16] + be16(summary.count) + summary
             + [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(ts) + [0, 17] + be16(words.count) + words
    }

    /// The band re-scores the whole night in each revision; only the last one is its verdict.
    @Test func detailsParserKeepsOnlyTheLastRescoringOfTheNight() {
        var b = fileId(version: 2, subtype: 0x08, detail: 0)
        b += [0, 0x00, 0] + le32(bed) + le32(bed + 3 * 3600)     // padding, header, isAwake, bed, wake
        b += revision(ts: bed, [(1, 60), (2, 30)])                // first scoring: light then deep
        b += revision(ts: bed, [(3, 30), (1, 60), (0, 10)])       // re-scoring: REM, light, awake
        b += crc

        let parsed = SleepDetailsParser.parse(Data(b), meta: meta(b))

        #expect(parsed.sessions.first?.phases == [
            SleepPhase(startDate: at(0), endDate: at(1800), type: .rem),
            SleepPhase(startDate: at(1800), endDate: at(5400), type: .light),
            SleepPhase(startDate: at(5400), endDate: at(6000), type: .awake),
        ])
        #expect(parsed.stageRevisions == 2)
        #expect(parsed.finalRevisionMatchesSummary == true)
    }

    @Test func detailsParserReadsARealNightAsTheBandScoredIt() {
        let data = Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions)
        guard let meta = XiaomiActivityFileMeta(Data(data.prefix(7))) else {
            Issue.record("fixture id doesn't decode")
            return
        }
        let parsed = SleepDetailsParser.parse(data, meta: meta)

        #expect(parsed.awakeFlag == 0)
        #expect(parsed.stageRevisions == 3)
        #expect(parsed.finalRevisionMatchesSummary == true)
        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions.first
        #expect(session?.startDate == Date(timeIntervalSince1970: 1_790_827_200))   // 01:00 -03
        #expect(session?.endDate == Date(timeIntervalSince1970: 1_790_850_840))     // 07:34 -03
        let phases = session?.phases ?? []
        func minutes(_ type: SleepPhaseType) -> Int {
            Int(phases.filter { $0.type == type }.reduce(0) { $0 + $1.duration } / 60)
        }
        #expect(phases.count == 35)
        #expect(minutes(.light) == 161)
        #expect(minutes(.deep) == 125)
        #expect(minutes(.rem) == 86)
        #expect(minutes(.awake) == 22)
        #expect(parsed.hasSpO2Section == true)
        #expect(parsed.spo2.count == 35)
        #expect(parsed.spo2.prefix(10).map(\.pct) == [97, 93, 93, 95, 94, 94, 95, 94, 97, 97])
        #expect(parsed.heartRates.count == 301)
    }

    @Test func detailsParserSynthesizesShortSleepFromSummaryOnlyWhenFinalized() {
        func shortSleepFile(awakeFlag: UInt8) -> [UInt8] {
            var b = fileId(version: 5, subtype: 0x08, detail: 1)
            b += [0]                                    // padding
            b += [0xDF, 0x00]                           // v5 header (no HR/SpO₂ sections)
            b += [awakeFlag]                            // isAwake
            b += le32(bed) + le32(bed + 67 * 60)        // bedTime, wakeupTime (67 min)
            b += [0]                                    // sleepQuality (bit 3)
            b += [UInt8](repeating: 0, count: 9)        // v5 unknown (9B)
            b += le32(bed) + le32(bed + 67 * 60)        // bedTime2, wakeupTime2
            // Type 16 summary: 67 min total sleep (0x0043), 0 wake/light/rem/deep, 0x0100 flag
            let summary: [UInt8] = [0x10] + be16(67) + be16(0) + be16(0) + be16(0) + be16(0) + [0x01, 0x00]
            b += [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 16] + be16(summary.count) + summary
            // Type 17 stages: empty (band only scores stages for sessions ≥ 3h)
            b += [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 17] + be16(0)
            return b + crc
        }

        // In-progress (< 3h, awakeFlag == 0): sessions stays empty so BandSyncer holds the ACK.
        let openBytes = shortSleepFile(awakeFlag: 0)
        let parsedOpen = SleepDetailsParser.parse(Data(openBytes), meta: meta(openBytes))
        #expect(parsedOpen.sessions.isEmpty)

        // Finalized (< 3h, awakeFlag == 1): synthesized from type-16 total sleep duration (67 min).
        let closedBytes = shortSleepFile(awakeFlag: 1)
        let parsedClosed = SleepDetailsParser.parse(Data(closedBytes), meta: meta(closedBytes))
        #expect(parsedClosed.sessions.count == 1)
        #expect(parsedClosed.sessions.first?.phases == [
            SleepPhase(startDate: at(0), endDate: at(67 * 60), type: .light)
        ])
    }

    @Test func detailsParserRejectsAnUnknownVersionInsteadOfGuessingOffsets() {
        let bytes = detailsFile(version: 6)
        let parsed = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes))
        #expect(parsed.sessions.isEmpty)
        #expect(parsed.heartRates.isEmpty)
        #expect(parsed.spo2.isEmpty)
    }

    // MARK: - 0x03 · SleepStagesParser

    private func stagesFile(version: Int = 2, bedTime: Int? = nil,
                            events: [(offset: Int, code: UInt8)]) -> [UInt8] {
        let bedTime = bedTime ?? bed
        var b = fileId(version: version, subtype: 0x03, detail: 0)
        b += [0]                                    // padding
        b += [0xFF, 0xFF, 0, 0, 0, 0, 0]            // unknown (7)
        b += le16(180)                              // sleepDuration, minutes
        b += le32(bedTime) + le32(bed + 3 * 3600)   // bedTime, wakeupTime
        b += [0, 0, 0]                              // unknown (3)
        b += le16(30) + le16(120) + le16(20) + le16(10)  // deep, light, rem, wake
        b += [0]                                    // unknown
        for e in events { b += le32(bed + e.offset) + [e.code] }
        return b + crc
    }

    @Test func stagesParserTurnsTransitionsIntoPhases() {
        let bytes = stagesFile(events: [
            (-600, 5),   // awake, before the band's "real" sleep start
            (0, 3),      // light
            (3600, 2),   // deep
            (5400, 0),   // not sleeping — skipped
            (6000, 4),   // REM, runs to wakeupTime
        ])
        let parsed = SleepStagesParser.parse(Data(bytes), meta: meta(bytes))

        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions[0]
        #expect(session.phases == [
            SleepPhase(startDate: at(-600), endDate: at(0), type: .awake),
            SleepPhase(startDate: at(0), endDate: at(3600), type: .light),
            SleepPhase(startDate: at(3600), endDate: at(5400), type: .deep),
            SleepPhase(startDate: at(6000), endDate: at(3 * 3600), type: .rem),
        ])
        // Widened to enclose the early awake phase.
        #expect(session.startDate == at(-600))
        #expect(session.endDate == at(3 * 3600))
    }

    @Test func stagesParserFallsBackToTheSummaryDurationsWithoutTransitions() {
        let bytes = stagesFile(events: [])
        let parsed = SleepStagesParser.parse(Data(bytes), meta: meta(bytes))
        let phases = parsed.sessions.first?.phases ?? []
        #expect(phases.map(\.type) == [.light, .deep, .rem, .awake])
        let expectedMinutes: [TimeInterval] = [120, 30, 20, 10]
        #expect(phases.map(\.duration) == expectedMinutes.map { $0 * 60 })
    }

    @Test func stagesParserIgnoresUnknownVersionsAndEmptyNights() {
        let wrongVersion = stagesFile(version: 3, events: [(0, 3)])
        #expect(SleepStagesParser.parse(Data(wrongVersion), meta: meta(wrongVersion)).sessions.isEmpty)

        let noBedTime = stagesFile(bedTime: 0, events: [(0, 3)])
        #expect(SleepStagesParser.parse(Data(noBedTime), meta: meta(noBedTime)).sessions.isEmpty)
    }

    // MARK: - Routing

    @Test func eachSleepSubtypeRoutesToItsOwnParser() {
        let details = meta(fileId(version: 5, subtype: 0x08, detail: 1))
        #expect(details.isSleep && details.isSleepDetails && !details.isSleepStages)

        let stages = meta(fileId(version: 2, subtype: 0x03, detail: 0))
        #expect(stages.isSleep && stages.isSleepStages && !stages.isSleepDetails)

        // GadgetBridge has no parser for a 0x03 that isn't DETAILS — it must fall to the ACK-only branch.
        let stagesSummary = meta(fileId(version: 2, subtype: 0x03, detail: 1))
        #expect(!stagesSummary.isSleep)
    }

    @Test func fileIdListingDropsPlaceholderIds() {
        let real = fileId(version: 2, subtype: 0x08, detail: 0)
        let placeholder = [UInt8](repeating: 0, count: 7)
        let ids = BandSyncer.splitFileIds(Data(real + placeholder))
        #expect(ids == [Data(real)])
    }

    @Test func walkingHeartRateAverageFiltersSteadyWalkingMinutes() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let samples = [
            ActivityMinuteSample(date: now, steps: nil, heartRate: 62),                        // sedentary
            ActivityMinuteSample(date: now.addingTimeInterval(60), steps: 10, heartRate: 70),  // too slow (<20 steps)
            ActivityMinuteSample(date: now.addingTimeInterval(120), steps: 80, heartRate: 98), // walking
            ActivityMinuteSample(date: now.addingTimeInterval(180), steps: 105, heartRate: 106), // walking
            ActivityMinuteSample(date: now.addingTimeInterval(240), steps: 170, heartRate: 155), // running (>140 steps)
        ]
        #expect(HealthKitManager.walkingHeartRateAverage(samples) == 102)
    }

    @Test func mifflinStJeorDailyBasalKilocaloriesAndSwimmingStrokeMapping() {
        let maleBmr = HealthKitManager.mifflinStJeorDailyKcal(
            weightKg: 75, heightCm: 178, ageYears: 30, sex: .male
        )
        // 10*75 + 6.25*178 - 5*30 + 5 = 750 + 1112.5 - 150 + 5 = 1717.5
        #expect(abs(maleBmr - 1717.5) < 0.01)

        #expect(HealthKitManager.swimmingStrokeStyle("freestyle") == .freestyle)
        #expect(HealthKitManager.swimmingStrokeStyle("breaststroke") == .breaststroke)
        #expect(HealthKitManager.swimmingStrokeStyle("medley") == .mixed)
    }

    @Test func gattHeartRatePacketParsesAndEncodesStandard2A37Payloads() {
        // 8-bit BPM (flags = 0x06: 8-bit HR + sensor contact detected)
        let encoded8 = GattHeartRatePacket.encode(bpm: 142, contactDetected: true)
        #expect(encoded8 == Data([0x06, 142]))
        let parsed8 = GattHeartRatePacket.parse(encoded8)
        #expect(parsed8?.bpm == 142)
        #expect(parsed8?.sensorContactDetected == true)
        #expect(parsed8?.rrIntervalsMs == [])

        // 16-bit BPM + Energy Expended + RR-Interval (flags = 0x1F: 16-bit HR + contact detected + energy + RR)
        // BPM = 260 (0x0104), Energy = 500 kJ (0x01F4), RR = 1024/1024 s = 1000 ms (0x0400)
        let raw16 = Data([0x1F, 0x04, 0x01, 0xF4, 0x01, 0x00, 0x04])
        let parsed16 = GattHeartRatePacket.parse(raw16)
        #expect(parsed16?.bpm == 260)
        #expect(parsed16?.sensorContactDetected == true)
        #expect(parsed16?.rrIntervalsMs.count == 1)
        #expect(abs((parsed16?.rrIntervalsMs.first ?? 0) - 1000.0) < 0.01)
    }
}
