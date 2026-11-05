import Testing
import Foundation
@testable import My_Band

// Regression coverage for the sleep double-counting bug found via a real Apple Health export:
// resyncing a still-in-progress (or previously partial) night reported the same real stage with a
// later end each time, and multiple files for the same/overlapping night could land in one batch —
// neither case was sanitized against the other, so Apple Health accumulated overlapping,
// double-counted stage and in-bed intervals. `sanitizeStages` (per-session) and
// `HealthKitManager.groupOverlapping` + the pooled re-sanitize in `writeSleep` fix this together.
@MainActor
struct SleepReconciliationTests {

    private func date(_ hm: String, day: String = "2026-06-23") -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        guard let d = f.date(from: "\(day) \(hm)") else { fatalError("bad fixture date") }
        return d
    }

    private func phase(_ start: String, _ end: String, _ type: SleepPhaseType) -> SleepPhase {
        SleepPhase(startDate: date(start), endDate: date(end), type: type)
    }

    // MARK: - sanitizeStages

    @Test func passesThroughNonOverlappingPhasesUnchanged() {
        let stages = [
            phase("04:54", "04:58", .deep),
            phase("04:58", "05:01", .awake),
            phase("05:13", "05:16", .rem),
        ]
        let sanitized = SleepDetailsParser.sanitizeStages(stages)
        #expect(sanitized.count == 3)
        #expect(sanitized.map(\.type) == [.deep, .awake, .rem])
    }

    @Test func dropsAFullyContainedDuplicate() {
        // A later cumulative packet re-reports the same window verbatim — should vanish, not double up.
        let stages = [
            phase("05:01", "05:13", .deep),
            phase("05:01", "05:10", .deep),
        ]
        let sanitized = SleepDetailsParser.sanitizeStages(stages)
        #expect(sanitized == [phase("05:01", "05:13", .deep)])
    }

    @Test func clipsAStageThatExtendsPastAnOverlappingOne() {
        // The exact pattern found in production: same start, growing end across a resync.
        let stages = [
            phase("05:01", "05:13", .deep),
            phase("05:01", "05:22", .deep),
        ]
        let sanitized = SleepDetailsParser.sanitizeStages(stages)
        #expect(sanitized == [
            phase("05:01", "05:13", .deep),
            phase("05:13", "05:22", .deep),
        ])
    }

    @Test func sanitizingTwiceIsIdempotent() {
        let once = SleepDetailsParser.sanitizeStages([
            phase("05:01", "05:13", .deep),
            phase("05:01", "05:22", .deep),
            phase("05:13", "05:16", .rem),
        ])
        let twice = SleepDetailsParser.sanitizeStages(once)
        #expect(once == twice)
    }

    // MARK: - Pooling across sessions (the actual production bug)

    @Test func poolingAndResanitizingCollapsesOverlapsThatSurvivedTwoIndependentFiles() {
        // File A (an earlier, partial fetch) sanitized this on its own — internally clean.
        let sessionA = SleepSession(
            startDate: date("04:22"), endDate: date("09:01"),
            phases: SleepDetailsParser.sanitizeStages([phase("05:01", "05:13", .deep)])
        )
        // File B (a later resync of the same still-in-progress night) sanitized *its* view on its
        // own too — also internally clean — but it overlaps file A's phase, which a per-file
        // sanitize can never see.
        let sessionB = SleepSession(
            startDate: date("04:22"), endDate: date("09:01"),
            phases: SleepDetailsParser.sanitizeStages([phase("05:01", "05:22", .deep), phase("05:13", "05:16", .rem)])
        )

        // Concatenating naively (the old behavior) leaves the overlap in place.
        let naive = sessionA.phases + sessionB.phases
        #expect(naive.contains(phase("05:01", "05:13", .deep)))
        #expect(naive.contains(phase("05:01", "05:22", .deep)))

        // Re-sanitizing the pool leaves no overlap. (File B's REM never reaches the pool: its own
        // sanitize already dropped it, being inside B's longer deep phase.) Which report wins where
        // they disagree is `HealthKitManager.mergedPhases`'s job — see SleepNightMergeTests.
        let pooled = SleepDetailsParser.sanitizeStages(naive)
        #expect(pooled == [
            phase("05:01", "05:13", .deep),
            phase("05:13", "05:22", .deep),
        ])
    }

    // MARK: - groupOverlapping

    @Test func groupsTwoSessionsWithOverlappingWindows() {
        let a = SleepSession(startDate: date("04:22"), endDate: date("07:00"), phases: [])
        let b = SleepSession(startDate: date("06:00"), endDate: date("09:01"), phases: [])
        let groups = HealthKitManager.groupOverlapping([a, b])
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test func keepsDisjointSessionsInSeparateGroups() {
        let night1 = SleepSession(startDate: date("04:22"), endDate: date("09:01"), phases: [])
        let night2 = SleepSession(startDate: date("04:30", day: "2026-06-24"),
                                  endDate: date("08:00", day: "2026-06-24"), phases: [])
        let groups = HealthKitManager.groupOverlapping([night1, night2])
        #expect(groups.count == 2)
    }

    @Test func transitivelyOverlappingSessionsAllGroupTogether() {
        // A overlaps B, B overlaps C, but A and C don't directly overlap each other.
        let a = SleepSession(startDate: date("00:00"), endDate: date("02:00"), phases: [])
        let b = SleepSession(startDate: date("01:30"), endDate: date("03:30"), phases: [])
        let c = SleepSession(startDate: date("03:00"), endDate: date("05:00"), phases: [])
        let groups = HealthKitManager.groupOverlapping([a, b, c])
        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
    }
}
