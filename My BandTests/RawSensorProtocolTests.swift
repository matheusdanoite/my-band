import Foundation
import Testing
@testable import My_Band

struct RawSensorProtocolTests {

    @Test
    func decodesAccelerometerAndGyroscopeSamples() {
        let command = command(
            batch: axisField(number: 5, timestamp: 1_000, x: 1.25, y: -2.5, z: 9.81)
                + axisField(number: 6, timestamp: 1_010, x: 0.1, y: 0.2, z: 0.3)
        )

        let receivedAt = Date(timeIntervalSince1970: 123)
        let samples = XiaomiRawSensorProtocol.parseSamples(from: command, receivedAt: receivedAt)

        #expect(samples.count == 2)
        #expect(samples[0].kind == .accelerometer)
        #expect(samples[0].timestamp == 1_000)
        #expect(abs(samples[0].x - 1.25) < 0.0001)
        #expect(abs(samples[0].y + 2.5) < 0.0001)
        #expect(abs(samples[0].z - 9.81) < 0.0001)
        #expect(samples[1].kind == .gyroscope)
        #expect(samples[1].timestamp == 1_010)
        #expect(samples[1].receivedAt == receivedAt)
    }

    @Test
    func ignoresCommandsWithoutRawSensorBatch() {
        let unrelatedCommand = Data([0x08, 0x2F])
        #expect(XiaomiRawSensorProtocol.parseSamples(from: unrelatedCommand).isEmpty)
    }

    @Test
    func ackCarriesCounterAndZeroReservedFields() {
        let ack = XiaomiRawSensorProtocol.ackCommand(counter: 7)
        #expect(ack == Data([0x08, 0x08, 0x10, 0x31, 0x52, 0x09, 0xCA, 0x02, 0x06, 0x08, 0x07, 0x10, 0x00, 0x18, 0x00]))
    }

    @Test
    func syntheticWorkoutUsesHealthStatusCommand() {
        let start = XiaomiRawSensorProtocol.startCommand(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Array(start.prefix(4)) == [0x08, 0x08, 0x10, 0x1A])
        #expect(start.contains(0xAA))
        #expect(start.contains(0x06))
    }

    private func command(batch: Data) -> Data {
        let health = field(15, batch)
        return Data([0x08, 0x35]) + field(10, health)
    }

    private func axisField(number: UInt8, timestamp: UInt64, x: Float, y: Float, z: Float) -> Data {
        let axis = varintField(1, timestamp)
            + fixed32Field(2, x.bitPattern)
            + fixed32Field(3, y.bitPattern)
            + fixed32Field(4, z.bitPattern)
        return field(Int(number), axis)
    }

    private func field(_ number: Int, _ value: Data) -> Data {
        var result = varint(UInt64((number << 3) | 2))
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    private func varintField(_ number: Int, _ value: UInt64) -> Data {
        var result = varint(UInt64(number << 3))
        result.append(varint(value))
        return result
    }

    private func fixed32Field(_ number: Int, _ value: UInt32) -> Data {
        var result = varint(UInt64((number << 3) | 5))
        result.append(UInt8(value & 0xFF))
        result.append(UInt8((value >> 8) & 0xFF))
        result.append(UInt8((value >> 16) & 0xFF))
        result.append(UInt8((value >> 24) & 0xFF))
        return result
    }

    private func varint(_ value: UInt64) -> Data {
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
