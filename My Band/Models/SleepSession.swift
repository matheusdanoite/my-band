import Foundation
import SwiftData

// MARK: - Sleep phase types

enum SleepPhaseType: Int, Codable, CaseIterable, Equatable {
    case awake = 0
    case light = 1
    case deep  = 2
    case rem   = 3

    var localizedName: String {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light Sleep"
        case .deep:  return "Deep Sleep"
        case .rem:   return "REM"
        }
    }
}

struct SleepPhase: Codable, Equatable {
    var startDate: Date
    var endDate: Date
    var type: SleepPhaseType

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
}

// MARK: - SleepSession model

@Model
final class SleepSession {

    var id: UUID
    var startDate: Date
    var endDate: Date
    /// Encoded as binary via SwiftData's Codable support
    var phases: [SleepPhase]
    var healthKitSynced: Bool
    var rawDataHash: Int           // hash of the raw packet — used for deduplication

    var device: BandDevice?

    // MARK: - Computed

    var totalDuration: TimeInterval { endDate.timeIntervalSince(startDate) }

    var efficiency: Double {
        guard totalDuration > 0 else { return 0 }
        let asleep = phases.filter { $0.type != .awake }.reduce(0) { $0 + $1.duration }
        return min(asleep / totalDuration, 1.0)
    }

    var deepDuration: TimeInterval   { phases.filter { $0.type == .deep  }.reduce(0) { $0 + $1.duration } }
    var remDuration: TimeInterval    { phases.filter { $0.type == .rem   }.reduce(0) { $0 + $1.duration } }
    var lightDuration: TimeInterval  { phases.filter { $0.type == .light }.reduce(0) { $0 + $1.duration } }

    // MARK: - Init

    init(startDate: Date, endDate: Date, phases: [SleepPhase], rawDataHash: Int = 0) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = endDate
        self.phases = phases
        self.healthKitSynced = false
        self.rawDataHash = rawDataHash
    }
}
