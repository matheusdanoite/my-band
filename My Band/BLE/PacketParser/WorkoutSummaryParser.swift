import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "WorkoutParser")

// MARK: - WorkoutKind
//
// The sport types Mi Band 10 records, mapped 1:1 to GadgetBridge's ActivityKind subset that
// the Xiaomi summary parsers emit. HealthKit mapping lives in HealthKitManager.

enum WorkoutKind {
    case running, walking, hiking, trekking, trailRun, treadmill
    case outdoorCycling, indoorCycling
    case freeTraining, hiit, yoga
    case strengthTraining                               // Strength Training (code 17 / subtype 0x11)
    case poolSwim, openWaterSwim
    case elliptical, rowing, rowingMachine, jumpRoping
    case other

    /// Whether a phone GPS stream is useful for this sport. Indoor / stationary sports (strength,
    /// yoga, treadmill, pool, machines…) gain nothing from it — the app replies "GPS disabled" so
    /// the band starts them immediately instead of waiting for, and recording, a fix it won't use.
    var usesGps: Bool {
        switch self {
        case .running, .trailRun, .walking, .hiking, .trekking, .outdoorCycling, .openWaterSwim:
            return true
        case .treadmill, .indoorCycling, .freeTraining, .hiit, .yoga, .strengthTraining,
             .poolSwim, .elliptical, .rowing, .rowingMachine, .jumpRoping, .other:
            return false
        }
    }
}

// MARK: - WorkoutSummary
//
// A parsed workout. `fields` holds every decoded numeric field keyed by WorkoutKey; typed
// accessors expose the ones HealthKit consumes. Time/HR-zone fields stay in `fields` for
// future UI without bloating this struct.

struct WorkoutSummary {
    var kind: WorkoutKind
    var startDate: Date
    var endDate: Date
    var swimStyle: String?
    var fields: [String: Double] = [:]
    let rawDataHash: Int

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    var activeSeconds: Double?  { fields[WorkoutKey.activeSeconds] }
    var caloriesKcal: Double?   { positive(WorkoutKey.calories) }
    var distanceMeters: Double? { positive(WorkoutKey.distance) }
    var steps: Double?          { positive(WorkoutKey.steps) }
    var strokes: Double?        { positive(WorkoutKey.strokes) }
    var vo2Max: Double?         { positive(WorkoutKey.vo2max) }
    var hrAvg: Double?          { positive(WorkoutKey.hrAvg) }
    var hrMax: Double?          { positive(WorkoutKey.hrMax) }
    var hrMin: Double?          { positive(WorkoutKey.hrMin) }

    private func positive(_ key: String) -> Double? {
        guard let v = fields[key], v > 0 else { return nil }
        return v
    }
}

enum WorkoutKey {
    static let timeStart     = "startTime"
    static let timeEnd       = "endTime"
    static let activeSeconds = "activeSeconds"
    static let calories      = "calories"
    static let caloriesTotal = "caloriesTotal"
    static let distance      = "distanceMeters"
    static let steps         = "steps"
    static let strokes       = "strokes"
    static let laps          = "laps"
    static let jumps         = "jumps"
    static let vo2max        = "vo2max"
    static let hrAvg         = "hrAvg"
    static let hrMax         = "hrMax"
    static let hrMin         = "hrMin"
    static let speedAvg      = "speedAvg"
    static let speedMax      = "speedMax"
    static let swimStyle     = "swimStyle"
    static let workoutType   = "xiaomiWorkoutType"
}

// MARK: - WorkoutSummaryParser
//
// Port of GadgetBridge WorkoutSummaryParser.java + XiaomiSimpleActivityParser.java. The
// summary file is a flat little-endian record whose field layout depends on (subtype,
// version). Each per-sport builder describes that layout; `addUnknown` skips padding.
//
// Note (matching GadgetBridge): the header's per-field validity bits are NOT used to gate
// reads — the unknown-field lengths aren't fully identified, so honouring the header would
// desync the cursor. We read every field positionally and let `fields` hold whatever decodes.

enum WorkoutSummaryParser {

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> WorkoutSummary? {
        // Trailing CRC-32 is left in place — fields are read positionally and stop well before it.
        let r = LEReader(data)
        r.skip(7)                              // fileId
        guard r.u8() == 0 else { return nil }  // padding

        guard let blueprint = blueprint(subtype: meta.subtype, version: meta.version) else {
            log.warning("WorkoutSummaryParser: no blueprint for subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version) — skipped")
            return nil
        }

        var kind = blueprint.defaultKind
        r.skip(blueprint.headerSize)

        var fields: [String: Double] = [:]
        var endEpoch: Double?
        var swimStyle: String?

        for field in blueprint.fields {
            guard let value = field.read(r) else { continue }   // unknown/skip field
            guard let key = field.key else { continue }
            switch key {
            case WorkoutKey.timeStart:
                break                                            // ignored — start comes from the file id
            case WorkoutKey.timeEnd:
                endEpoch = value
            case WorkoutKey.swimStyle:
                swimStyle = Self.swimStyleName(Int(value))
            case WorkoutKey.workoutType:
                let code = Int(value)
                log.debug("WorkoutSummaryParser: workoutType code=\(code) subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version)")
                if let mapped = workoutKind(fromCode: code) { kind = mapped }
                fields[key] = value
            default:
                fields[key] = value
            }
        }

        let start = meta.timestamp
        let end = endEpoch.map { Date(timeIntervalSince1970: $0) } ?? start
        log.info("WorkoutSummaryParser: subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version) → kind=\(String(describing: kind)) workoutTypeField=\(fields[WorkoutKey.workoutType].map { String(Int($0)) } ?? "absent")")
        return WorkoutSummary(kind: kind, startDate: start,
                              endDate: end > start ? end : start,
                              swimStyle: swimStyle, fields: fields,
                              rawDataHash: hashOf(data))
    }

    // MARK: - Builder

    private struct Field {
        let key: String?
        let read: (LEReader) -> Double?
    }

    private final class Blueprint {
        var headerSize = 0
        var defaultKind: WorkoutKind = .other
        var fields: [Field] = []

        @discardableResult func header(_ n: Int) -> Blueprint { headerSize = n; return self }
        @discardableResult func kind(_ k: WorkoutKind) -> Blueprint { defaultKind = k; return self }
        @discardableResult func byte(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.u8()) }); return self }
        @discardableResult func short(_ k: String, _ mult: Double = 1) -> Blueprint { fields.append(Field(key: k) { Double($0.i16()) * mult }); return self }
        @discardableResult func int(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.i32()) }); return self }
        @discardableResult func float(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.f32()) }); return self }
        @discardableResult func skip(_ n: Int) -> Blueprint { fields.append(Field(key: nil) { $0.skip(n); return nil }); return self }
    }

    // Shared tail: the five HR-zone durations every workout ends with.
    private static func hrZones(_ b: Blueprint) {
        b.int("hrZoneExtreme").int("hrZoneAnaerobic").int("hrZoneAerobic")
         .int("hrZoneFatBurn").int("hrZoneWarmUp")
    }

    private static func hrTriple(_ b: Blueprint) {
        b.byte(WorkoutKey.hrAvg).byte(WorkoutKey.hrMax).byte(WorkoutKey.hrMin)
    }

    // MARK: - Per-(subtype, version) blueprints

    private static func blueprint(subtype: Int, version: Int) -> Blueprint? {
        switch subtype {
        case 0x01: return outdoorWalkingV1(version, kind: .running)   // SPORTS_OUTDOOR_RUNNING
        case 0x02: return outdoorWalkingV1(version, kind: .walking)   // SPORTS_OUTDOOR_WALKING_V1
        case 0x03: return treadmill(version)
        case 0x06: return outdoorCyclingV2(version)
        case 0x07: return indoorCycling(version)
        case 0x08: return freestyle(version)
        case 0x09: return poolSwimming(version)
        case 0x10: return hiit(version)
        case 0x0B: return elliptical(version)
        case 0x0D: return rowing(version)
        case 0x0E: return jumpRoping(version)
        case 0x16: return outdoorWalkingV2(version)
        case 0x17: return outdoorCycling(version)
        default:   return nil
        }
    }

    private static func freestyle(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 5:           headerSize = 3
        case 7:           headerSize = 5
        case 8, 9, 10:    headerSize = 6
        default:          return nil
        }
        let b = Blueprint().header(headerSize).kind(.freeTraining)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        if version > 5 { b.skip(6) }
        b.float("trainingEffectAerobic")
        if version > 6 { b.skip(1) }
        b.skip(1).short("recoveryTime")
        hrZones(b)
        if version == 5 {
            b.skip(10).short(WorkoutKey.workoutType).skip(2).int("configuredTimeGoal").short("configuredCaloriesGoal")
        } else {
            b.skip(2).skip(4).float("trainingEffectAnaerobic").skip(1)
             .short(WorkoutKey.workoutType).skip(2).int("configuredTimeGoal").short("configuredCaloriesGoal")
             .short("workoutLoad").skip(1)
            if version > 7 { b.byte("vitalityGain") }
        }
        return b
    }

    private static func indoorCycling(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 8: headerSize = 7
        case 9: headerSize = 8
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.indoorCycling)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).short(WorkoutKey.calories).skip(4)
        hrTriple(b)
        b.float("trainingEffectAerobic").skip(1).skip(1).short("recoveryTime")
        hrZones(b)
        b.skip(2).skip(4).float("trainingEffectAnaerobic").skip(3)
         .int("configuredTimeGoal").short("configuredCaloriesGoal").short("maximumCaloriesGoal")
         .skip(28).short("workoutLoad").skip(24).byte("configuredSets").skip(13)
        return b
    }

    private static func outdoorWalkingV1(_ version: Int, kind: WorkoutKind) -> Blueprint? {
        guard version == 4 else { return nil }
        let b = Blueprint().header(4).kind(kind)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).int(WorkoutKey.calories)
         .int("paceMax").int("paceMin").skip(4).int(WorkoutKey.steps).skip(2)
        hrTriple(b)
        b.skip(20).float("recoveryValue").skip(9).byte("recoveryTime").skip(2)
        hrZones(b)
        b.int("configuredTimeGoal")
        return b
    }

    private static func outdoorWalkingV2(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 1:    headerSize = 5
        case 4:    headerSize = 7
        case 5, 6: headerSize = 9
        case 9:    headerSize = 13
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.walking)
        b.short(WorkoutKey.workoutType)
         .int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).int(WorkoutKey.distance).short(WorkoutKey.caloriesTotal).short(WorkoutKey.calories)
        if version >= 5 { b.int("paceAvgSecKm") }
        b.int("paceMax").int("paceMin")
        if version >= 5 { b.float(WorkoutKey.speedAvg) }
        b.float(WorkoutKey.speedMax).int(WorkoutKey.steps)
        if version >= 5 { b.short("stepLengthAvg").short("stepRateAvg") }
        b.short("stepRateMax")
        hrTriple(b)
        if version == 1 {
            b.skip(33)
        } else {
            b.skip(20).float("trainingEffectAerobic").skip(1).float("trainingEffectAnaerobic")
            if version >= 9 { b.skip(6).byte(WorkoutKey.vo2max).skip(2) } else { b.skip(4) }
            b.short("recoveryTime").skip(1)
        }
        hrZones(b)
        if version >= 9 {
            b.skip(46).short("workoutLoad").skip(15).short("activeScore").skip(17)
             .short("avgGroundContactTime").short("minGroundContactTime").skip(6)
             .short("avgVerticalRatio", 0.1).short("minVerticalRatio", 0.1)
             .short("maxVerticalOscillation").short("avgVerticalOscillation").short("minVerticalOscillation")
        }
        return b
    }

    private static func outdoorCycling(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 4, 5: headerSize = 6
        case 6:    headerSize = 7
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.outdoorCycling)
        b.short(WorkoutKey.workoutType)
         .int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).int(WorkoutKey.distance).skip(2).short(WorkoutKey.calories).skip(4).skip(4)
        if version >= 5 { b.float(WorkoutKey.speedAvg) }
        b.float(WorkoutKey.speedMax)
        hrTriple(b)
        b.float("elevationGain").float("elevationLoss").float("altitudeAvg").float("altitudeMax").float("altitudeMin")
         .float("trainingEffectAerobic").skip(1).float("trainingEffectAnaerobic").skip(1)
         .byte(WorkoutKey.vo2max).skip(1).skip(1).short("recoveryTime").skip(1)
        hrZones(b)
        return b
    }

    private static func outdoorCyclingV2(_ version: Int) -> Blueprint? {
        guard version == 4 else { return nil }
        let b = Blueprint().header(5).kind(.outdoorCycling)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories).skip(8).float(WorkoutKey.speedMax)
        hrTriple(b)
        b.skip(28)
        hrZones(b)
        b.skip(18).skip(2).skip(6)
        return b
    }

    private static func hiit(_ version: Int) -> Blueprint? {
        guard version == 5 else { return nil }
        let b = Blueprint().header(4).kind(.hiit)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.float("trainingEffectAerobic").skip(1).skip(1).short("recoveryTime")
        hrZones(b)
        return b
    }

    private static func poolSwimming(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 6: headerSize = 4
        case 7: headerSize = 5
        case 8: headerSize = 8
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.poolSwim)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories)
        if version >= 7 { b.skip(4) }
        b.skip(11).short(WorkoutKey.strokes).byte(WorkoutKey.swimStyle)
        if version >= 7 { b.skip(1) }
        b.skip(1).short(WorkoutKey.laps).short("swolfAvg").short("minSwolf").byte("configuredLaneLength").skip(6)
         .int("configuredTimeGoal").short("configuredCaloriesGoal").skip(8).short("configuredLengthsGoal").skip(13)
         .byte("vitalityGain")
        return b
    }

    private static func elliptical(_ version: Int) -> Blueprint? {
        guard (3...6).contains(version) else { return nil }
        let b = Blueprint().header(4).kind(.elliptical)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories).int(WorkoutKey.steps)
        if version >= 6 { b.short("cadenceAvg") }
        b.short("cadenceMax")
        hrTriple(b)
        b.skip(7)
        if version >= 4 { b.skip(1) }
        hrZones(b)
        return b
    }

    private static func rowing(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 4:    headerSize = 4
        case 6, 7: headerSize = 5
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.rowingMachine)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.skip(7)
        if version > 4 { b.skip(1) }
        hrZones(b)
        b.skip(2).int(WorkoutKey.strokes).int("strokeRateAvg").skip(4)
        return b
    }

    private static func treadmill(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 5:  headerSize = 4
        case 10: headerSize = 8
        case 11: headerSize = 9
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.treadmill)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories)
        if version >= 10 { b.int("paceAvgSecKm") }
        b.int("paceMax").int("paceMin").int(WorkoutKey.steps)
        if version >= 10 { b.skip(2).short("cadenceAvg") }
        b.short("cadenceMax")
        hrTriple(b)
        b.float("trainingEffectAerobic")
        if version >= 10 { b.skip(1) }
        b.byte(WorkoutKey.vo2max)
        if version >= 10 { b.skip(1) }
        b.skip(1).short("recoveryTime")
        hrZones(b)
        return b
    }

    private static func jumpRoping(_ version: Int) -> Blueprint? {
        guard version == 3 || version == 5 else { return nil }
        let b = Blueprint().header(5).kind(.jumpRoping)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.float("trainingEffectAerobic")
        if version == 3 { b.skip(3) } else { b.skip(2).short("recoveryTime") }
        hrZones(b)
        b.skip(2).int(WorkoutKey.jumps).short("jumpRateAvg").skip(2).short("jumpRateMax")
        if version == 3 {
            b.skip(43).skip(2).skip(2)
        } else {
            b.skip(27).skip(4).float("trainingEffectAnaerobic").skip(3)
             .int("configuredTimeGoal").short("configuredCaloriesGoal").int("configuredJumpsGoal")
             .short("workoutLoad").skip(1).byte("vitalityGain")
        }
        return b
    }

    // MARK: - Helpers

    private static func swimStyleName(_ code: Int) -> String {
        switch code {
        case 0: "medley"
        case 1: "breaststroke"
        case 2: "freestyle"
        case 3: "backstroke"
        case 4: "butterfly"
        default: "unknown"
        }
    }

    /// Subset of XiaomiWorkoutType.fromCode used by the V2 walking/cycling files whose kind
    /// comes from a payload field rather than the file-id subtype.
    static func workoutKind(fromCode code: Int) -> WorkoutKind? {
        switch code {
        case 1:  .running
        case 2:  .walking
        case 3:  .hiking
        case 4:  .trekking
        case 5:  .trailRun
        case 6:  .outdoorCycling
        case 7:  .indoorCycling
        case 8:  .freeTraining
        case 9:  .poolSwim
        case 10: .openWaterSwim
        case 11: .elliptical
        case 12: .yoga
        case 13: .rowingMachine
        case 14: .jumpRoping
        case 15: .walking
        case 16:  .hiit
        // Strength training uses subtype 0x08 (freestyle layout), version 10, with workoutType=308.
        // Confirmed from hardware log: subtype=0x8 version=10 workoutType code=308.
        case 308: .strengthTraining
        case 107: .rowing
        default: nil
        }
    }

    private static func hashOf(_ data: Data) -> Int {
        data.prefix(64).reduce(into: 0) { $0 ^= Int($1) }
    }
}
