import Foundation

// MARK: - SleepDetailsParser
//
// Parses the binary sleep file returned by Mi Band 10. Faithful port of GadgetBridge
// SleepDetailsParser.java (XiaomiActivityFileFetcher → SleepDetailsParser).
//
// File layout (received from activity characteristic after CRC-32 validation):
//
//   [0..6]   XiaomiActivityFileId (7 bytes)
//   [7]      padding (expect 0x00)
//   [...]    header bitmask: 1 byte (versions 1–4) or 2 bytes (version 5).
//            validData(header, i) gates whether optional field `i` is present.
//   then, in order (each gated/sized by version + header bits):
//     isAwake (u8), bedTime (u32 LE), wakeupTime (u32 LE),
//     sleepQuality (v≥4), bedTime2/wakeupTime2 block (v≥5),
//     Heart-rate section, SpO₂ section, snore section (v≥3),
//     then interleaved stage packets.
//
// Each section: [unit: u16 LE][count: u16 LE]([firstRecordTime: u32 LE] if v≥2)[samples].
//   HR/SpO₂ samples are one u8 each; sample i timestamp = firstRecordTime + unit·i (seconds).
//   Snore samples are 4 bytes each (skipped).
//
// Stage packet header (17 bytes):
//   [0..3]   magic = 0xFFFCFAFB read **little-endian** → on-wire bytes FB FA FC FF
//   [4]      headerLen (= 17)
//   [5..12]  ts (Int64 LE, seconds for types 16/17)
//   [13]     parity
//   [14]     type
//   [15..16] dataLen (UInt16 **big-endian**)
//   [17..]   payload (dataLen bytes, big-endian fields)
//
// Stage packet types: 16 = summary, 17 = stages. Types 2/3/9/12/13/14/15 are flag-only
// (no payload). Type 1 is beat-to-beat (RR) intervals: ts in milliseconds = the block's first beat,
// then one u8 per interval in 10 ms units, always a multiple of 4 (25 Hz PPG, 40 ms steps); a block
// spans ~600 s and the next starts ~605 s later. Confirmed on the two hardware nights of
// 2026-10-01…03: the HR they imply matches the header HR section within ~1 bpm per block when anchored
// at the block's start (~2.3 bpm anchored at its end). Each block keeps its own ts — GadgetBridge
// chains the beats across blocks and drifts up to 30 s before resyncing. HR still comes from the
// header HR section. A file carries one 16 + 17 pair per re-scoring of the night; see parse.
//
// Type 17 entries are UInt16 BE: bits[15:12] = stage, bits[11:0] = duration_minutes of
// that stage. The stage starts at the running cursor; the cursor advances by the duration.
// Stage codes: 0 awake · 1 light · 2 deep · 3 rem · 4 not-sleeping (skipped).

struct ParsedSleep {
    var sessions: [SleepSession] = []
    var heartRates: [(date: Date, bpm: Int)] = []
    var spo2: [(date: Date, pct: Int)] = []

    // Header as read. The awake byte reads 0 while the night is still open and 1 once the band has
    // closed it (hardware, 2026-10-01: 0 at five syncs through 13:31 with wake frozen at 12:37, 1 at
    // 15:17) — GetSleepStateIntent leans on it.
    var bedTime = 0
    var wakeupTime = 0
    var awakeFlag: Int?
    var packetTypes: [Int] = []
    /// Type-17 packets that carried stages — each one a full re-scoring of the night so far.
    var stageRevisions = 0
    /// Whether the re-scoring kept adds up to the type-16 summary sent just before it; nil without one.
    var finalRevisionMatchesSummary: Bool?
    /// Whether the header announced a SpO₂ section at all (nil for layouts without the bitmask). Every
    /// hardware night so far had none — a band setting, not a parse, would be the first suspect.
    var hasSpO2Section: Bool?
    /// Beat-to-beat intervals recorded during the night (type-1 packets), one block per packet.
    var beatWindows: [BeatWindow] = []

    /// Stage-packet types in the order first seen, with counts — e.g. "1×42 17×3 16×1".
    var packetSummary: String {
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for type in packetTypes {
            if counts[type] == nil { order.append(type) }
            counts[type, default: 0] += 1
        }
        return order.map { "\($0)×\(counts[$0] ?? 0)" }.joined(separator: " ")
    }
}

enum SleepDetailsParser {

    private static let stagePacketLen = 17

    // MARK: - Public API

    /// Parses a complete, CRC-validated sleep file. `meta.version` selects the header layout.
    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> ParsedSleep {
        var result = ParsedSleep()
        guard data.count > 4 else { return result }

        let version = meta.version
        // The header layout is only known for 1–5 (GadgetBridge rejects the rest too). Guessing
        // misreads every offset after it, and the HR/SpO₂ sections would then write garbage to Health.
        guard (1...5).contains(version) else { return result }
        let headerSize = version == 5 ? 2 : 1

        // Strip trailing CRC-32 before parsing fixed-length sections.
        let r = LEReader(Data(data.dropLast(4)))
        r.skip(7)                              // fileId
        _ = r.u8()                             // padding (expected 0)

        var header = [UInt8]()
        for _ in 0 ..< headerSize { header.append(r.u8()) }

        var headerIdx = 0
        result.awakeFlag = Int(r.u8()); headerIdx += 1   // isAwake
        let bedTime = Int(r.i32()); headerIdx += 1
        let wakeupTime = Int(r.i32()); headerIdx += 1
        result.bedTime = bedTime
        result.wakeupTime = wakeupTime

        if version >= 4 {
            if validData(header, headerIdx) { _ = r.u8() }   // sleepQuality
            headerIdx += 1
        }
        if version >= 5 {
            r.skip(9)
            _ = r.i32()                        // bedTime2
            _ = r.i32()                        // wakeupTime2
            headerIdx += 5
        }

        // Heart-rate samples recorded during sleep — the data Apple Health's sleep
        // "Comparisons" tab correlates against the sleep window.
        if validData(header, headerIdx) {
            result.heartRates = readSamples(r, version: version, bedTime: bedTime, range: 30...250)
                .map { (date: $0.0, bpm: $0.1) }
        }
        headerIdx += 1

        // SpO₂ samples during sleep.
        result.hasSpO2Section = validData(header, headerIdx)
        if validData(header, headerIdx) {
            result.spo2 = readSamples(r, version: version, bedTime: bedTime, range: 50...100)
                .map { (date: $0.0, pct: $0.1) }
        }
        headerIdx += 1

        // Snore section (v≥3) — 4 bytes/sample, skipped.
        if version >= 3 {
            if validData(header, headerIdx) {
                _ = r.u16()                    // unit
                let count = Int(r.u16())
                if count > 0 {
                    if version >= 2 { _ = r.i32() }
                    r.skip(count * 4)
                }
            }
            headerIdx += 1
        }

        // Stage packets.
        guard bedTime > 0, wakeupTime > bedTime else { return result }
        let sessionStart = Date(timeIntervalSince1970: TimeInterval(bedTime))
        let sessionEnd   = Date(timeIntervalSince1970: TimeInterval(wakeupTime))

        // The band appends a summary + stages pair every time it re-scores the night, each covering
        // the whole night from its bedtime — not just the stretch since the previous pair — and it
        // re-classifies earlier stretches as it goes (a hardware night disagreed with its first
        // scoring on 13% of its minutes). Only the last pair per start is the band's verdict; each
        // summary matched the stages right after it to the minute.
        var revisions: [Int64: [SleepPhase]] = [:]
        var summaryMinutes: (deep: Int, light: Int, rem: Int, wake: Int)?
        var lastStagesSummary: (deep: Int, light: Int, rem: Int, wake: Int)?
        var lastStagesTs: Int64?
        var beatBlocks: [Int64: BeatWindow] = [:]
        // Stage packets carry their own timestamps; one far outside the night is a misread, and
        // widening the session to enclose it would make writeSleep clear everything in between.
        let plausible = sessionStart.addingTimeInterval(-6 * 3600) ... sessionEnd.addingTimeInterval(6 * 3600)

        while r.remaining >= stagePacketLen {
            guard scanForStageMagic(r) else { break }   // leaves cursor after the 4 magic bytes
            guard r.remaining >= 13 else { break }

            _ = r.u8()                          // headerLen (== 17)
            let ts = r.i64()                    // seconds (LE)
            _ = r.u8()                          // parity
            let type = Int(r.u8())
            let dataLen = (Int(r.u8()) << 8) | Int(r.u8())   // big-endian
            result.packetTypes.append(type)

            // Flag-only packets: the dataLen bytes are flags, no payload follows.
            if [0x2, 0x3, 0x9, 0xC, 0xD, 0xE, 0xF].contains(type) { continue }
            guard dataLen >= 0, r.remaining >= dataLen else { break }
            let payload = r.read(dataLen)

            switch type {
            case 1:
                // Milliseconds; a block stamped outside the plausible night is a misread.
                let start = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
                guard plausible.contains(start), !payload.isEmpty else { break }
                beatBlocks[ts] = BeatWindow(start: start, intervalsMs: payload.map { Int($0) * 10 })
            case 16: summaryMinutes = parseSleepSummary(payload)
            case 17:
                // An empty one is a stray (seen stamped days before the night) — it re-scores nothing.
                let phases = parseSleepStages(payload, base: TimeInterval(ts))
                guard !phases.isEmpty else { break }
                revisions[ts] = phases
                result.stageRevisions += 1
                lastStagesTs = ts
                lastStagesSummary = summaryMinutes
            default: break                      // type 1 etc. — not decoded
            }
        }

        if let ts = lastStagesTs, let summary = lastStagesSummary, let phases = revisions[ts] {
            func minutes(_ type: SleepPhaseType) -> Int {
                Int(phases.filter { $0.type == type }.reduce(0) { $0 + $1.duration } / 60)
            }
            result.finalRevisionMatchesSummary = minutes(.deep) == summary.deep && minutes(.light) == summary.light
                && minutes(.rem) == summary.rem && minutes(.awake) == summary.wake
        }
        let stages = revisions.keys.sorted().flatMap { revisions[$0] ?? [] }
        result.beatWindows = beatBlocks.keys.sorted().compactMap { beatBlocks[$0] }

        let sanitized = sanitizeStages(stages.filter { plausible.contains($0.startDate) && plausible.contains($0.endDate) })
        let phases = sanitized.isEmpty
            ? summaryMinutes.map { buildPhasesFromSummary(start: sessionStart, deepMin: $0.deep, lightMin: $0.light,
                                                         remMin: $0.rem, wakeMin: $0.wake) } ?? []
            : sanitized
        guard let first = phases.first, let last = phases.last else { return result }

        // Widened to enclose every phase, as in SleepStagesParser: the window becomes the in-bed sample
        // and the range writeSleep clears, so a reclassified phase outside it would survive a rewrite
        // next to its replacement.
        result.sessions = [SleepSession(startDate: min(sessionStart, first.startDate),
                                        endDate: max(sessionEnd, last.endDate),
                                        phases: phases, rawDataHash: hashOf(data))]
        return result
    }

    // MARK: - HR / SpO₂ section

    private static func readSamples(_ r: LEReader, version: Int, bedTime: Int,
                                    range: ClosedRange<Int>) -> [(Date, Int)] {
        let unit = Int(r.u16())
        let count = Int(r.u16())
        guard count > 0 else { return [] }
        let rawFirst = version >= 2 ? Int(r.u32()) : bedTime
        let first: Int
        if rawFirst > 1_500_000_000 {
            first = rawFirst
        } else if bedTime > 1_500_000_000 && rawFirst > 0 && rawFirst < 86400 {
            let bedDate = Date(timeIntervalSince1970: TimeInterval(bedTime))
            let dayStart = Calendar.current.startOfDay(for: bedDate).timeIntervalSince1970
            first = Int(dayStart) + rawFirst
        } else {
            first = bedTime
        }
        var out: [(Date, Int)] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let v = Int(r.u8())
            guard range.contains(v) else { continue }
            let sampleTime = TimeInterval(first + unit * i)
            guard sampleTime > 1_500_000_000 else { continue }
            out.append((Date(timeIntervalSince1970: sampleTime), v))
        }
        return out
    }

    // MARK: - Stage packet magic finder
    //
    // Sliding 4-byte search for FB FA FC FF (0xFFFCFAFB little-endian), matching
    // GadgetBridge readStagePacketHeader. Leaves the cursor just past the magic.

    private static func scanForStageMagic(_ r: LEReader) -> Bool {
        var b0: UInt8 = 0, b1: UInt8 = 0, b2: UInt8 = 0, b3: UInt8 = 0
        var filled = 0
        while r.remaining > 0 {
            b0 = b1; b1 = b2; b2 = b3; b3 = r.u8()
            filled += 1
            if filled >= 4 && b0 == 0xFB && b1 == 0xFA && b2 == 0xFC && b3 == 0xFF { return true }
        }
        return false
    }

    // MARK: - Type 0x11 (17): Sleep stages

    private static func parseSleepStages(_ data: Data, base: TimeInterval) -> [SleepPhase] {
        guard data.count >= 2 else { return [] }
        var phases: [SleepPhase] = []
        var cursor = base
        let count = data.count / 2

        for idx in 0 ..< count {
            let word        = data.readUInt16BE(at: idx * 2)
            let stageRaw    = UInt8(word >> 12)        // bits [15:12]
            let durationMin = Int(word & 0x0FFF)       // bits [11:0]

            let start = Date(timeIntervalSince1970: cursor)
            cursor += TimeInterval(durationMin * 60)
            let end = Date(timeIntervalSince1970: cursor)

            guard end > start else { continue }        // zero-length marker

            let stage: SleepPhaseType
            switch stageRaw {
            case 0: stage = .awake
            case 1: stage = .light
            case 2: stage = .deep
            case 3: stage = .rem
            default: continue                           // 4 = not sleeping, others
            }
            phases.append(SleepPhase(startDate: start, endDate: end, type: stage))
        }
        return phases
    }

    // MARK: - Type 0x10 (16): Sleep summary
    //
    //   byte[0]:   (sleep_index << 4) | wake_count
    //   [1..2]:    sleep_duration (minutes, UInt16 BE)
    //   [3..4]:    wake_duration
    //   [5..6]:    light_duration
    //   [7..8]:    rem_duration
    //   [9..10]:   deep_duration

    private static func parseSleepSummary(_ data: Data) -> (deep: Int, light: Int, rem: Int, wake: Int)? {
        guard data.count >= 11 else { return nil }
        return (
            deep:  Int(data.readUInt16BE(at: 9)),
            light: Int(data.readUInt16BE(at: 5)),
            rem:   Int(data.readUInt16BE(at: 7)),
            wake:  Int(data.readUInt16BE(at: 3))
        )
    }

    // MARK: - Fallback: synthesise phases from the summary durations

    fileprivate static func buildPhasesFromSummary(
        start: Date, deepMin: Int, lightMin: Int, remMin: Int, wakeMin: Int
    ) -> [SleepPhase] {
        var phases: [SleepPhase] = []
        var cursor = start

        func add(_ type: SleepPhaseType, minutes: Int) {
            guard minutes > 0 else { return }
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            phases.append(SleepPhase(startDate: cursor, endDate: end, type: type))
            cursor = end
        }

        add(.light, minutes: lightMin)
        add(.deep,  minutes: deepMin)
        add(.rem,   minutes: remMin)
        add(.awake, minutes: wakeMin)
        return phases
    }

    // MARK: - Helpers

    /// Eliminates overlapping phases caused by cumulative Xiaomi stage packets. Also reused by
    /// `HealthKitManager.writeSleep` to collapse phases pooled across multiple `SleepSession`s —
    /// incremental resyncs of the same still-in-progress night arrive as separate sessions, each
    /// already sanitized on its own, but not against each other.
    static func sanitizeStages(_ stages: [SleepPhase]) -> [SleepPhase] {
        let sorted = stages.sorted { $0.startDate < $1.startDate }
        var merged: [SleepPhase] = []
        for s in sorted {
            guard s.endDate > s.startDate else { continue }
            if let last = merged.last, s.startDate < last.endDate {
                if s.endDate <= last.endDate { continue }
                merged.append(SleepPhase(startDate: last.endDate, endDate: s.endDate, type: s.type))
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// header bit `i`: byte `i/8`, MSB-first within the byte.
    private static func validData(_ header: [UInt8], _ i: Int) -> Bool {
        let byteIdx = i / 8
        guard byteIdx < header.count else { return false }
        return (header[byteIdx] & (1 << (7 - (i % 8)))) != 0
    }

    /// FNV-1a 64-bit over the whole file. The previous XOR-fold collapsed to a single byte
    /// (0–255), so distinct nights collided and the store's dedup silently dropped legitimate new
    /// sessions from SwiftData (Apple Health was unaffected — it always rewrites).
    fileprivate static func hashOf(_ data: Data) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}

// MARK: - SleepStagesParser
//
// Subtype 0x03 (ACTIVITY_SLEEP_STAGES), version 2. Port of GadgetBridge SleepStagesParser.java.
// A different layout from 0x08: a fixed summary header, then phase *transition events* instead of
// duration-encoded packets. Both subtypes used to go through SleepDetailsParser, which read these
// bytes at the wrong offsets — at best no session, at worst stray bytes passing as HR/SpO₂.
//
//   [0..6]   fileId · [7] padding · [8..14] unknown
//   [15..16] sleepDuration (i16 LE, minutes)
//   [17..20] bedTime · [21..24] wakeupTime (u32 LE)
//   [25..27] unknown
//   [28..35] deep / light / rem / wake durations (i16 LE each, minutes)
//   [36]     unknown
//   then 5-byte records [time: u32 LE][phase: u8] — the phase in effect *from* `time`; the last
//   one runs until wakeupTime.
//
// Phase codes are GadgetBridge's own sample codes: 2 deep · 3 light · 4 rem · 5 awake
// (0 not sleeping, 1 unknown — skipped).

enum SleepStagesParser {

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> ParsedSleep {
        var result = ParsedSleep()
        guard meta.version == 2, data.count > 4 else { return result }

        // CRC stripped: GadgetBridge reads records up to the buffer limit, CRC included.
        let r = LEReader(Data(data.dropLast(4)))
        r.skip(7 + 1 + 7)                       // fileId, padding, unknown
        let sleepDuration = Int(r.i16())
        let bedTime = Int(r.u32())
        let wakeupTime = Int(r.u32())
        r.skip(3)
        let deep = Int(r.i16()), light = Int(r.i16()), rem = Int(r.i16()), wake = Int(r.i16())
        r.skip(1)
        result.bedTime = bedTime
        result.wakeupTime = wakeupTime

        guard bedTime > 0, wakeupTime > bedTime, sleepDuration > 0 else { return result }

        // The first transition can precede bedTime (the band's "real" sleep start), but not by
        // hours; anything outside that window is a misread, not a phase.
        let window = (bedTime - 6 * 3600)...wakeupTime
        var events: [(time: Int, code: UInt8)] = []
        while r.remaining >= 5 {
            let event = (time: Int(r.u32()), code: r.u8())
            if window.contains(event.time) { events.append(event) }
        }
        events.sort { $0.time < $1.time }

        var phases: [SleepPhase] = []
        for (i, event) in events.enumerated() {
            let end = i + 1 < events.count ? events[i + 1].time : wakeupTime
            guard end > event.time, let type = phaseType(event.code) else { continue }
            phases.append(SleepPhase(startDate: Date(timeIntervalSince1970: TimeInterval(event.time)),
                                     endDate: Date(timeIntervalSince1970: TimeInterval(end)),
                                     type: type))
        }

        let bed = Date(timeIntervalSince1970: TimeInterval(bedTime))
        let wakeup = Date(timeIntervalSince1970: TimeInterval(wakeupTime))
        if phases.isEmpty {
            phases = SleepDetailsParser.buildPhasesFromSummary(start: bed, deepMin: deep, lightMin: light,
                                                              remMin: rem, wakeMin: wake)
        }
        guard let first = phases.first, let last = phases.last else { return result }

        // Widened to enclose every phase — the window becomes the in-bed sample.
        result.sessions = [SleepSession(startDate: min(bed, first.startDate),
                                        endDate: max(wakeup, last.endDate),
                                        phases: phases,
                                        rawDataHash: SleepDetailsParser.hashOf(data))]
        return result
    }

    private static func phaseType(_ code: UInt8) -> SleepPhaseType? {
        switch code {
        case 2: .deep
        case 3: .light
        case 4: .rem
        case 5: .awake
        default: nil
        }
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        let base = startIndex + offset
        return (UInt16(self[base]) << 8) | UInt16(self[base + 1])
    }
}
