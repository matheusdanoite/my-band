import Foundation

struct RawSensorSample: Sendable {
    enum Kind: String, Sendable {
        case accelerometer
        case gyroscope
    }

    let kind: Kind
    let timestamp: UInt64
    let receivedAt: Date
    let x: Float
    let y: Float
    let z: Float
}

struct RawSensorVector: Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct RawSensorMotionRow: Sendable {
    let timestamp: UInt64
    let time: Double
    let accelerometer: RawSensorVector
    let gyroscope: RawSensorVector
}

enum XiaomiRawSensorProtocol {

    static let csvHeader = [
        "time_s",
        "timestamp_us",
        "accelerometerAccelerationX(G)",
        "accelerometerAccelerationY(G)",
        "accelerometerAccelerationZ(G)",
        "gyroscopeRotationRateX(rad/s)",
        "gyroscopeRotationRateY(rad/s)",
        "gyroscopeRotationRateZ(rad/s)",
        "accelerometerMagnitude(G)",
        "gyroscopeMagnitude(rad/s)",
    ].joined(separator: ",") + "\n"

    private static let timestampScale = 1_000_000.0
    private static let sensorAlignmentTolerance: UInt64 = 20_000

    static let syntheticSport: UInt32 = 810
    private static let sportInfoType: UInt32 = 16
    private static let healthField = 10
    private static let workoutStatusField = 20
    private static let rawSensorBatchField = 15
    private static let rawSensorAckField = 41

    static func parseSamples(from command: Data, receivedAt: Date = .now) -> [RawSensorSample] {
        guard let health = field(healthField, in: command, wireType: 2),
              let batch = field(rawSensorBatchField, in: health, wireType: 2) else {
            return []
        }

        var samples: [RawSensorSample] = []
        for axis in repeatedFields(5, in: batch, wireType: 2) {
            if let sample = parseAxis(axis, kind: .accelerometer, receivedAt: receivedAt) {
                samples.append(sample)
            }
        }
        for axis in repeatedFields(6, in: batch, wireType: 2) {
            if let sample = parseAxis(axis, kind: .gyroscope, receivedAt: receivedAt) {
                samples.append(sample)
            }
        }
        return samples
    }

    static func motionRows(from samples: [RawSensorSample]) -> [RawSensorMotionRow] {
        let accelerometers = samples
            .filter { $0.kind == .accelerometer }
            .sorted { $0.timestamp < $1.timestamp }
        let gyroscopes = samples
            .filter { $0.kind == .gyroscope }
            .sorted { $0.timestamp < $1.timestamp }
        guard !accelerometers.isEmpty, !gyroscopes.isEmpty,
              let firstTimestamp = accelerometers.first?.timestamp else {
            return []
        }

        return accelerometers.compactMap { anchor in
            let counterpart = interpolatedVector(
                at: anchor.timestamp,
                in: gyroscopes
            )
            guard let counterpart else { return nil }
            return RawSensorMotionRow(
                timestamp: anchor.timestamp,
                time: Double(anchor.timestamp - firstTimestamp) / timestampScale,
                accelerometer: RawSensorVector(x: anchor.x, y: anchor.y, z: anchor.z),
                gyroscope: counterpart
            )
        }
    }

    static func csvRow(for row: RawSensorMotionRow) -> String {
        let accelerometer = row.accelerometer
        let gyroscope = row.gyroscope
        let locale = Locale(identifier: "en_US_POSIX")
        return [
            String(format: "%.6f", locale: locale, row.time),
            String(row.timestamp),
            String(format: "%.6f", locale: locale, accelerometer.x),
            String(format: "%.6f", locale: locale, accelerometer.y),
            String(format: "%.6f", locale: locale, accelerometer.z),
            String(format: "%.6f", locale: locale, gyroscope.x),
            String(format: "%.6f", locale: locale, gyroscope.y),
            String(format: "%.6f", locale: locale, gyroscope.z),
            String(format: "%.6f", locale: locale, magnitude(of: accelerometer)),
            String(format: "%.6f", locale: locale, magnitude(of: gyroscope)),
        ].joined(separator: ",") + "\n"
    }

    private static func interpolatedVector(
        at timestamp: UInt64,
        in samples: [RawSensorSample]
    ) -> RawSensorVector? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if timestamp < first.timestamp || timestamp > last.timestamp {
            let distance = timestamp < first.timestamp
                ? first.timestamp - timestamp
                : timestamp - last.timestamp
            guard distance <= sensorAlignmentTolerance else { return nil }
            let sample = timestamp < first.timestamp ? first : last
            return RawSensorVector(x: sample.x, y: sample.y, z: sample.z)
        }

        guard let upperIndex = samples.firstIndex(where: { $0.timestamp >= timestamp }) else {
            return RawSensorVector(x: last.x, y: last.y, z: last.z)
        }
        let upper = samples[upperIndex]
        guard upper.timestamp != timestamp, upperIndex > samples.startIndex else {
            return RawSensorVector(x: upper.x, y: upper.y, z: upper.z)
        }
        let lower = samples[upperIndex - 1]
        let span = Double(upper.timestamp - lower.timestamp)
        let fraction = Double(timestamp - lower.timestamp) / span
        return RawSensorVector(
            x: interpolate(lower.x, upper.x, fraction),
            y: interpolate(lower.y, upper.y, fraction),
            z: interpolate(lower.z, upper.z, fraction)
        )
    }

    private static func interpolate(_ lower: Float, _ upper: Float, _ fraction: Double) -> Float {
        lower + Float(fraction) * (upper - lower)
    }

    private static func magnitude(of vector: RawSensorVector) -> Double {
        sqrt(Double(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z))
    }

    static func startCommand(at date: Date = .now) -> Data {
        workoutStatusCommand(status: 0, timestamp: UInt32(date.timeIntervalSince1970))
    }

    static func stopCommands(at date: Date = .now) -> [Data] {
        [
            workoutStatusCommand(status: 1, timestamp: UInt32(date.timeIntervalSince1970)),
            workoutStatusCommand(status: 3, timestamp: UInt32(date.timeIntervalSince1970)),
        ]
    }

    static func ackCommand(counter: UInt32) -> Data {
        let ack = fieldVarint(1, counter)
            + fieldVarint(2, 0)
            + fieldVarint(3, 0)
        let health = fieldLengthDelimited(rawSensorAckField, ack)
        return command(subtype: 49, health: health)
    }

    private static func workoutStatusCommand(status: UInt32, timestamp: UInt32) -> Data {
        let sportInfo = fieldVarint(1, sportInfoType)
        let statusMessage = fieldVarint(1, timestamp)
            + fieldLengthDelimited(2, sportInfo)
            + fieldVarint(3, syntheticSport)
            + fieldVarint(4, status)
            + fieldVarint(6, 3)
        let health = fieldLengthDelimited(workoutStatusField, statusMessage)
        return command(subtype: 26, health: health)
    }

    private static func command(subtype: UInt32, health: Data) -> Data {
        fieldVarint(1, 8) + fieldVarint(2, subtype) + fieldLengthDelimited(healthField, health)
    }

    private static func parseAxis(
        _ data: Data,
        kind: RawSensorSample.Kind,
        receivedAt: Date
    ) -> RawSensorSample? {
        guard let timestamp = varintField(1, in: data),
              let xBits = fixed32Field(2, in: data),
              let yBits = fixed32Field(3, in: data),
              let zBits = fixed32Field(4, in: data) else {
            return nil
        }
        return RawSensorSample(
            kind: kind,
            timestamp: timestamp,
            receivedAt: receivedAt,
            x: Float(bitPattern: xBits),
            y: Float(bitPattern: yBits),
            z: Float(bitPattern: zBits)
        )
    }

    private static func field(_ number: Int, in data: Data, wireType: Int) -> Data? {
        repeatedFields(number, in: data, wireType: wireType).first
    }

    private static func repeatedFields(_ number: Int, in data: Data, wireType: Int) -> [Data] {
        var cursor = 0
        var result: [Data] = []
        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor) else { break }
            let fieldNumber = Int(key >> 3)
            let actualWireType = Int(key & 0x07)
            guard let value = readValue(data, cursor: &cursor, wireType: actualWireType) else { break }
            if fieldNumber == number, actualWireType == wireType {
                result.append(value)
            }
        }
        return result
    }

    private static func varintField(_ number: Int, in data: Data) -> UInt64? {
        var cursor = 0
        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor),
                  let value = readValue(data, cursor: &cursor, wireType: Int(key & 0x07)) else {
                return nil
            }
            if Int(key >> 3) == number {
                var nestedCursor = 0
                return readVarint(value, cursor: &nestedCursor)
            }
        }
        return nil
    }

    private static func fixed32Field(_ number: Int, in data: Data) -> UInt32? {
        var cursor = 0
        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor),
                  let value = readValue(data, cursor: &cursor, wireType: Int(key & 0x07)) else {
                return nil
            }
            if Int(key >> 3) == number, value.count == 4 {
                return UInt32(value[value.startIndex])
                    | (UInt32(value[value.startIndex + 1]) << 8)
                    | (UInt32(value[value.startIndex + 2]) << 16)
                    | (UInt32(value[value.startIndex + 3]) << 24)
            }
        }
        return nil
    }

    private static func readVarint(_ data: Data, cursor: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.count, shift < 64 {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func readValue(_ data: Data, cursor: inout Int, wireType: Int) -> Data? {
        switch wireType {
        case 0:
            let start = cursor
            guard readVarint(data, cursor: &cursor) != nil else { return nil }
            return Data(data[data.startIndex + start ..< data.startIndex + cursor])
        case 1:
            guard cursor + 8 <= data.count else { return nil }
            defer { cursor += 8 }
            return Data(data[data.startIndex + cursor ..< data.startIndex + cursor + 8])
        case 2:
            guard let length = readVarint(data, cursor: &cursor),
                  length <= UInt64(data.count - cursor),
                  let end = Int(exactly: length) else {
                return nil
            }
            let start = cursor
            cursor += end
            return Data(data[data.startIndex + start ..< data.startIndex + cursor])
        case 5:
            guard cursor + 4 <= data.count else { return nil }
            defer { cursor += 4 }
            return Data(data[data.startIndex + cursor ..< data.startIndex + cursor + 4])
        default:
            return nil
        }
    }

    private static func fieldVarint(_ number: Int, _ value: UInt32) -> Data {
        var result = varint(UInt64(number << 3))
        result.append(varint(UInt64(value)))
        return result
    }

    private static func fieldLengthDelimited(_ number: Int, _ value: Data) -> Data {
        var result = varint(UInt64((number << 3) | 2))
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var result = lhs
        result.append(rhs)
        return result
    }
}
