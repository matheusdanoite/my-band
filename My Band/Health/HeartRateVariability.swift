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

    /// One window per start, the last one seen winning: every report of a night repeats the blocks
    /// of the reports before it.
    static func distinct(_ windows: [BeatWindow]) -> [BeatWindow] {
        var byStart: [Date: BeatWindow] = [:]
        for window in windows { byStart[window.start] = window }
        return byStart.values.sorted { $0.start < $1.start }
    }
}
