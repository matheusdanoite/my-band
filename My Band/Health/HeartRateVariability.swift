import Foundation

// MARK: - Beat-to-beat intervals → HRV
//
// The band records the interval between consecutive heartbeats while the user sleeps and sends it in
// the sleep file as ~10-minute blocks (type-1 stage packets, decoded by SleepDetailsParser). Each block
// becomes, in Apple Health, one heartbeat series (every beat with its time) and one SDNN value per
// minute (heartRateVariabilitySDNN) — the window the Apple Watch measures over, since SDNN grows with
// the window (hardware nights of 2026-10-01…03: median 46–59 ms over 1 min, 63–78 ms over 5 min) and
// Health has no field saying which window a value used.
//
// The band's intervals come in 40 ms steps (25 Hz PPG). That inflates SDNN by ~1–2% only; RMSSD would
// be distorted far more (a third of successive differences are exactly zero), which is why SDNN.

/// One block of beat-to-beat intervals: the first beat at `start`, each following beat one interval
/// after the previous one.
struct BeatWindow: Equatable {
    var start: Date
    var intervalsMs: [Int]
}

enum HeartRateVariability {

    /// 30–200 bpm. Outside it an interval is a missed or a spurious beat, not a heartbeat.
    static let plausibleIntervalMs = 300 ... 2000
    /// An interval more than 20% off the median of its neighbourhood (5 each side) is an artifact —
    /// the usual ectopic/artifact rule; ~3% of the hardware intervals fail it.
    static let maxDeviationFromLocalMedian = 0.2
    static let neighbours = 5

    /// SDNN windows: back-to-back minutes from the block's first beat.
    static let minute: TimeInterval = 60
    /// A minute gets a value only if its intervals cover at least this much of it…
    static let minCoverage: TimeInterval = 50
    /// …and at least this share of them survive the artifact filter. A minute that fails gets no
    /// value — a gap in the chart, not a number built on noise.
    static let minAcceptedShare = 0.8

    /// Whether each interval is a clean beat-to-beat interval.
    static func accepted(_ intervals: [Int]) -> [Bool] {
        intervals.indices.map { i in
            let value = intervals[i]
            guard plausibleIntervalMs.contains(value) else { return false }
            let lo = max(0, i - neighbours), hi = min(intervals.count, i + neighbours + 1)
            let around = intervals[lo ..< hi].sorted()
            let median = Double(around[around.count / 2])
            return abs(Double(value) - median) <= maxDeviationFromLocalMedian * median
        }
    }

    struct Beat: Equatable {
        /// Seconds after the block's first beat.
        var offset: TimeInterval
        /// The interval ending at this beat is not to be used (artifact, or the block's first beat).
        var precededByGap: Bool
    }

    /// Every beat of the block. An interval rejected by the filter isn't dropped from the timeline —
    /// the beat at its end really happened when the sum says — it's flagged so no consumer measures
    /// variability across it. A zero interval adds no beat (two beats can't share an instant).
    static func beats(_ window: BeatWindow) -> [Beat] {
        let clean = accepted(window.intervalsMs)
        var beats = [Beat(offset: 0, precededByGap: true)]
        var elapsedMs = 0
        var gapPending = false
        for (i, interval) in window.intervalsMs.enumerated() {
            elapsedMs += interval
            guard interval > 0 else { gapPending = true; continue }
            beats.append(Beat(offset: TimeInterval(elapsedMs) / 1000, precededByGap: gapPending || !clean[i]))
            gapPending = false
        }
        return beats
    }

    struct MinuteValue: Equatable {
        var start: Date
        var end: Date
        var sdnnMs: Double
        /// Clean intervals the value was computed from.
        var intervals: Int
    }

    /// SDNN of each full, clean minute of the block. An interval belongs to the minute in which the
    /// beat that ends it falls.
    static func minuteSDNN(_ window: BeatWindow) -> [MinuteValue] {
        let clean = accepted(window.intervalsMs)
        var byMinute: [Int: (all: [Int], kept: [Int])] = [:]
        var elapsedMs = 0
        for (i, interval) in window.intervalsMs.enumerated() {
            elapsedMs += interval
            let index = Int(Double(elapsedMs) / 1000 / minute)
            var bucket = byMinute[index] ?? ([], [])
            bucket.all.append(interval)
            if clean[i] { bucket.kept.append(interval) }
            byMinute[index] = bucket
        }
        return byMinute.keys.sorted().compactMap { index in
            guard let bucket = byMinute[index], bucket.kept.count >= 2,
                  TimeInterval(bucket.all.reduce(0, +)) / 1000 >= minCoverage,
                  Double(bucket.kept.count) >= minAcceptedShare * Double(bucket.all.count) else { return nil }
            let start = window.start.addingTimeInterval(TimeInterval(index) * minute)
            return MinuteValue(start: start, end: start.addingTimeInterval(minute),
                               sdnnMs: standardDeviation(bucket.kept), intervals: bucket.kept.count)
        }
    }

    /// Sample standard deviation (n − 1), the usual SDNN estimator.
    static func standardDeviation(_ values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        let squares = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
        return (squares / Double(values.count - 1)).squareRoot()
    }

    struct RespiratoryRateValue: Equatable {
        var start: Date
        var end: Date
        var breathsPerMinute: Double
        var cycles: Int
    }

    /// Overnight respiratory rate derived from Respiratory Sinus Arrhythmia (RSA) modulation of
    /// the beat-to-beat interval series across a ~10-minute sleep `BeatWindow`.
    ///
    /// Inhalation shortens RR intervals and exhalation lengthens them in the physiological sleep
    /// breathing band (10–24 breaths/min, period 2.5–6.0 s). Detrending with a 9-beat moving
    /// average removes VLF/LF drift (< 0.12 Hz) and a 3-beat smooth suppresses 40 ms PPG quantization
    /// steps; upward zero-crossings within 2.5–6.0 s yield the block's breathing period.
    static func respiratoryRate(_ window: BeatWindow) -> RespiratoryRateValue? {
        let clean = accepted(window.intervalsMs)
        var pts: [(t: TimeInterval, rr: Double)] = []
        pts.reserveCapacity(window.intervalsMs.count)
        var elapsedMs = 0
        for (i, interval) in window.intervalsMs.enumerated() {
            if interval > 0 { elapsedMs += interval }
            if clean[i] {
                pts.append((TimeInterval(elapsedMs) / 1000.0, Double(interval)))
            }
        }
        guard pts.count >= 120, elapsedMs > 0 else { return nil }

        var detrended: [(t: TimeInterval, y: Double)] = []
        detrended.reserveCapacity(pts.count - 8)
        for i in 4 ..< (pts.count - 4) {
            var sum9 = 0.0
            for j in (i - 4) ... (i + 4) { sum9 += pts[j].rr }
            let avg9 = sum9 / 9.0
            let s3 = (pts[i - 1].rr + pts[i].rr + pts[i + 1].rr) / 3.0
            detrended.append((pts[i].t, s3 - avg9))
        }
        guard detrended.count >= 2 else { return nil }

        var crossings: [TimeInterval] = []
        for i in 1 ..< detrended.count {
            let (t0, y0) = detrended[i - 1]
            let (t1, y1) = detrended[i]
            if y0 <= 0 && y1 > 0 {
                let tc = y1 != y0 ? t0 + (0.0 - y0) * (t1 - t0) / (y1 - y0) : t1
                crossings.append(tc)
            }
        }
        guard crossings.count >= 2 else { return nil }

        var validPeriods: [TimeInterval] = []
        for i in 1 ..< crossings.count {
            let period = crossings[i] - crossings[i - 1]
            if (2.5 ... 6.0).contains(period) {
                validPeriods.append(period)
            }
        }
        guard validPeriods.count >= 15 else { return nil }

        let meanPeriod = validPeriods.reduce(0.0, +) / Double(validPeriods.count)
        let bpm = (60.0 / meanPeriod * 10.0).rounded() / 10.0
        guard (10.0 ... 24.0).contains(bpm) else { return nil }
        return RespiratoryRateValue(
            start: window.start,
            end: window.start.addingTimeInterval(TimeInterval(elapsedMs) / 1000.0),
            breathsPerMinute: bpm,
            cycles: validPeriods.count
        )
    }

    /// One window per start, the last one seen winning: every report of a night repeats the blocks
    /// of the reports before it.
    static func distinct(_ windows: [BeatWindow]) -> [BeatWindow] {
        var byStart: [Date: BeatWindow] = [:]
        for window in windows { byStart[window.start] = window }
        return byStart.values.sorted { $0.start < $1.start }
    }
}
