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
    /// Set once the night this report belongs to was written to Apple Health. A report fetched with
    /// the phone locked stays false until the unlock flush (`BandSyncer.flushPendingSleep`).
    var healthKitSynced: Bool
    var rawDataHash: Int           // hash of the raw packet — used for deduplication

    /// Header byte of the sleep file: 0 while the band still has the night open, 1 once it closed it.
    var awakeFlag: Int?
    /// When this exact report was last received from the band. With the night open, `endDate` keeps
    /// pace with it; a gap between the two means the night stopped growing — the user woke up.
    var fetchedAt: Date?
    /// The file as the band sent it, kept so a parser fix can re-read nights already gone from the
    /// band. Only the report reaching furthest into its night keeps it (each file is cumulative).
    @Attribute(.externalStorage) var rawData: Data?

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
