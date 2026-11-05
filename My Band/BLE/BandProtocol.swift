import Foundation

// MARK: - XiaomiSppPacketV2
//
// Wire format for Mi Band 10 BLE V2 (confirmed from GadgetBridge XiaomiSppPacketV2.java).
//
// Outer frame — 8-byte header:
//   [0..1]  preamble: 0xA5 0xA5
//   [2]     type & flags (lower 4 bits = packet type)
//   [3]     seqNum (UInt8, per-session sequence counter)
//   [4..5]  payloadLen (UInt16 LE)
//   [6..7]  checksum (CRC-16/ARC of payload ONLY)
//   [8+]    payload
//
// Outer packet types:
//   1 = ACK
//   2 = SESSION_CONFIG  (binary config, NOT protobuf)
//   3 = DATA            (contains channel + opCode + actual bytes)
//
// DATA packet payload layout (bytes inside the outer payload):
//   [0]   rawChannel & 0xf
//            1 = PROTOBUF (auth commands use this with PLAINTEXT;
//                          post-auth commands use this with ENCRYPTED)
//            2 = DATA
//            5 = ACTIVITY (encrypted after auth)
//   [1]   opCode
//            1 = PLAINTEXT
//            2 = ENCRYPTED (encryptV2 / decryptV2 with AES-CTR key=IV)
//   [2+]  actual content (protobuf Command bytes, or encrypted protobuf bytes)

// MARK: - Packet type constants

enum XiaomiPacketType: UInt8 {
    case ack           = 1
    case sessionConfig = 2
    case data          = 3
}

// MARK: - Data channel raw values (lower 4 bits of first payload byte in DATA packets)

enum XiaomiRawChannel {
    static let protobuf: UInt8 = 1   // auth + command (different opCodes)
    static let data:     UInt8 = 2
    static let activity: UInt8 = 5
}

// MARK: - DATA packet opCode values

enum XiaomiOpCode {
    static let plaintext: UInt8 = 1
    static let encrypted: UInt8 = 2
}

// MARK: - Parsed SPP frame

struct XiaomiParsedPacket {
    let packetType: UInt8
    let seqNum:     UInt8
    let payload:    Data

    // DATA packet conveniences — valid only when packetType == data (3)
    var rawChannel: UInt8 { payload.count >= 2 ? payload[payload.startIndex] & 0xf : 0 }
    var opCode:     UInt8 { payload.count >= 2 ? payload[payload.startIndex + 1] : 0 }
    // Data(…) forces a copy with startIndex=0 — dropFirst(2) alone returns a slice whose
    // startIndex is 2, which causes Data.subscript precondition failures in the proto parser.
    var innerData:  Data  { payload.count >= 2 ? Data(payload.dropFirst(2)) : Data() }

    var isData:         Bool { packetType == XiaomiPacketType.data.rawValue }
    var isSessionCfg:   Bool { packetType == XiaomiPacketType.sessionConfig.rawValue }
    var isAck:          Bool { packetType == XiaomiPacketType.ack.rawValue }
}

// MARK: - XiaomiSppPacket builder / parser

enum XiaomiSppPacket {

    static let headerSize = 8
    private static let preamble: [UInt8] = [0xA5, 0xA5]

    // MARK: - Outer frame builder

    /// Builds a complete SPP V2 frame: 8-byte header + payload.
    static func build(type: XiaomiPacketType, seqNum: UInt8, payload: Data) -> Data {
        let payloadLen = UInt16(payload.count)
        let checksum   = crc16arc(payload)

        var frame = Data(capacity: headerSize + payload.count)
        frame.append(contentsOf: preamble)
        frame.append(type.rawValue & 0xf)
        frame.append(seqNum)
        frame.append(UInt8(payloadLen & 0xFF))
        frame.append(UInt8(payloadLen >> 8))
        frame.append(UInt8(checksum & 0xFF))
        frame.append(UInt8(checksum >> 8))
        frame.append(payload)
        return frame
    }

    // MARK: - Specialised builders

    /// Session config START_REQUEST (binary format, from GadgetBridge packet dump of official app).
    /// GadgetBridge always uses seqNum=0 for SESSION_CONFIG via setSequenceNumber(0) — the shared
    /// DATA packet counter is NOT incremented; it stays at 0 so CMD_NONCE also gets seqNum=0.
    static func buildSessionConfig() -> Data {
        let seqNum: UInt8 = 0
        // Layout: opCode | KEY(1B) SIZE(2B LE) VALUE | KEY SIZE VALUE | ...
        // KEY_VERSION=1 → size=3 → [0x01,0x00,0x00]
        // KEY_MAX_PACKET_SIZE=2 → size=2 → [0x00,0xfc] (=64512)
        // KEY_TX_WIN=3 → size=2 → [0x20,0x00] (=32)
        // KEY_SEND_TIMEOUT=4 → (from dump: 0x02, then 0x10, 0x27) → 10000ms
        // TLV format: KEY(1B) SIZE(2B LE) VALUE(size bytes) — verified against GadgetBridge XiaomiSppPacketV2.java
        let payload: [UInt8] = [
            0x01,                                       // OPCODE_START_SESSION_REQUEST
            0x01, 0x03, 0x00, 0x01, 0x00, 0x00,        // KEY_VERSION=1, size=3, value=[1,0,0]
            0x02, 0x02, 0x00, 0x00, 0xfc,               // KEY_MAX_PACKET_SIZE=2, size=2, value=0xfc00=64512
            0x03, 0x02, 0x00, 0x20, 0x00,               // KEY_TX_WIN=3, size=2, value=32
            0x04, 0x02, 0x00, 0x10, 0x27,               // KEY_SEND_TIMEOUT=4, size=2, value=10000ms
        ]
        return build(type: .sessionConfig, seqNum: seqNum, payload: Data(payload))
    }

    /// DATA packet wrapping a protobuf Command for the auth channel (plaintext).
    static func buildAuthCommand(protoBytes: Data, seqNum: UInt8) -> Data {
        var payload = Data()
        payload.append(XiaomiRawChannel.protobuf)
        payload.append(XiaomiOpCode.plaintext)
        payload.append(protoBytes)
        return build(type: .data, seqNum: seqNum, payload: payload)
    }

    /// DATA packet wrapping an encrypted protobuf Command for the command channel.
    static func buildEncryptedCommand(encryptedBytes: Data, seqNum: UInt8) -> Data {
        var payload = Data()
        payload.append(XiaomiRawChannel.protobuf)
        payload.append(XiaomiOpCode.encrypted)
        payload.append(encryptedBytes)
        return build(type: .data, seqNum: seqNum, payload: payload)
    }

    /// DATA packet carrying a raw file-upload chunk on the DATA channel. Unlike commands, the DATA
    /// channel is sent PLAINTEXT (GadgetBridge: CHANNEL_DATA → OPCODE_SEND_PLAINTEXT) — the upload
    /// payload protects itself with an embedded MD5 + CRC-32, so it isn't AES-CTR encrypted.
    static func buildDataChunk(_ chunk: Data, seqNum: UInt8) -> Data {
        var payload = Data()
        payload.append(XiaomiRawChannel.data)
        payload.append(XiaomiOpCode.plaintext)
        payload.append(chunk)
        return build(type: .data, seqNum: seqNum, payload: payload)
    }

    /// ACK packet.
    static func buildAck(seqNum: UInt8) -> Data {
        build(type: .ack, seqNum: seqNum, payload: Data())
    }

    // MARK: - Parser

    /// Parses an incoming BLE notification into a XiaomiParsedPacket.
    /// Returns nil on malformed data or CRC mismatch.
    static func parse(_ raw: Data) -> XiaomiParsedPacket? {
        guard raw.count >= headerSize,
              raw[0] == 0xA5, raw[1] == 0xA5 else { return nil }

        let packetType  = raw[2] & 0xf
        let seqNum      = raw[3]
        let payloadLen  = Int(raw[4]) | (Int(raw[5]) << 8)
        let givenCRC    = UInt16(raw[6]) | (UInt16(raw[7]) << 8)

        guard raw.count >= headerSize + payloadLen else { return nil }

        let payload  = raw.subdata(in: headerSize ..< headerSize + payloadLen)
        let computed = crc16arc(payload)
        guard computed == givenCRC else { return nil }

        return XiaomiParsedPacket(packetType: packetType, seqNum: seqNum, payload: payload)
    }

    // MARK: - CRC-16/ARC (GadgetBridge: calculatePayloadChecksum)
    // Config: poly=0x8005, init=0, refIn=true (bits LSB-first), refOut=true, xorOut=0
    // Applied to PAYLOAD ONLY (not the full frame).

    static func crc16arc(_ data: Data) -> UInt16 {
        var crc: Int32 = 0
        for byte in data {
            for j: Int32 in 0 ..< 8 {
                crc <<= 1
                let carry = (crc >> 16) & 1
                let bit   = (Int32(byte) >> j) & 1
                if carry ^ bit == 1 {
                    crc ^= 0x8005
                }
            }
        }
        // Java Integer.reverse(crc) >>> 16 — reverse all 32 bits, take upper 16
        return UInt16(reverseBits32(UInt32(bitPattern: crc)) >> 16)
    }

    private static func reverseBits32(_ value: UInt32) -> UInt32 {
        var n = value
        var result: UInt32 = 0
        for _ in 0 ..< 32 {
            result = (result << 1) | (n & 1)
            n >>= 1
        }
        return result
    }
}

// MARK: - Auth command IDs

enum XiaomiAuthCmd {
    static let cmdType:      UInt32 = 1
    static let sendUserId:   UInt32 = 5
    static let pairingRequest: UInt32 = 16 // band-initiated first-pairing announcement (not in GadgetBridge)
    static let nonce:        UInt32 = 26   // CMD_NONCE
    static let auth:         UInt32 = 27   // CMD_AUTH
}

// MARK: - System command IDs (type=2, from GadgetBridge XiaomiSystemService)

enum XiaomiSystemCmd {
    static let cmdType:        UInt32 = 2
    static let battery:        UInt32 = 1    // CMD_BATTERY
    static let deviceInfo:     UInt32 = 2    // CMD_DEVICE_INFO
    static let clock:          UInt32 = 3    // CMD_CLOCK (set time)
    static let language:       UInt32 = 6    // CMD_LANGUAGE (system.language.code = "pt_br")
    static let findPhone:      UInt32 = 17   // CMD_FIND_PHONE (band → app: ring the phone)
    static let deviceStateGet: UInt32 = 78   // CMD_DEVICE_STATE_GET
}

// MARK: - Calendar command IDs (GadgetBridge XiaomiCalendarService)

enum XiaomiCalendarCmd {
    static let cmdType:  UInt32 = 12
    static let set:      UInt32 = 1    // CMD_CALENDAR_SET (calendar.calendarSync, ≤50 events)
}

// MARK: - Weather command IDs (GadgetBridge XiaomiWeatherService)

enum XiaomiWeatherCmd {
    static let cmdType:          UInt32 = 10
    static let setCurrent:       UInt32 = 0   // CMD_SET_CURRENT_WEATHER (weather.current)
    static let dailyForecast:    UInt32 = 1   // CMD_UPDATE_DAILY_FORECAST (weather.forecast)
    static let hourlyForecast:   UInt32 = 2   // CMD_UPDATE_HOURLY_FORECAST
    static let requestConditions: UInt32 = 3  // CMD_REQUEST_CONDITIONS_FOR_LOCATION (band → app: push weather now)
    static let getLocations:     UInt32 = 5   // CMD_GET_LOCATIONS
    static let addLocation:      UInt32 = 7   // CMD_ADD_LOCATION (weather.location)
}

// MARK: - Schedule command IDs (GadgetBridge XiaomiScheduleService — alarms, reminders, clocks)

enum XiaomiScheduleCmd {
    static let cmdType:        UInt32 = 17
    static let remindersGet:   UInt32 = 14
    static let reminderCreate: UInt32 = 15   // schedule.createReminder (ReminderDetails)
    static let reminderEdit:   UInt32 = 17   // schedule.editReminder
    static let reminderDelete: UInt32 = 18   // schedule.deleteReminder (ids)
}

// MARK: - Health command IDs

enum XiaomiHealthCmd {
    static let cmdType:          UInt32 = 8
    static let fetchToday:       UInt32 = 1   // CMD_ACTIVITY_FETCH_TODAY
    static let fetchPast:        UInt32 = 2   // CMD_ACTIVITY_FETCH_PAST
    static let fetchRequest:     UInt32 = 3   // CMD_ACTIVITY_FETCH_REQUEST (per file ID)
    static let fetchAck:         UInt32 = 5   // CMD_ACTIVITY_FETCH_ACK

    // Workout / GPS commands (GadgetBridge XiaomiHealthService)
    static let workoutStatus:    UInt32 = 26  // CMD_WORKOUT_WATCH_STATUS  (band → app)
    static let workoutOpen:      UInt32 = 30  // CMD_WORKOUT_WATCH_OPEN    (band → app request / app → band reply)
    static let workoutLocation:  UInt32 = 48  // CMD_WORKOUT_LOCATION      (app → band GPS stream)

    // Real-time stats (live HR/steps over the authenticated channel; GadgetBridge XiaomiHealthService)
    static let realtimeStart:    UInt32 = 45  // CMD_REALTIME_STATS_START  (app → band)
    static let realtimeStop:     UInt32 = 46  // CMD_REALTIME_STATS_STOP   (app → band)
    static let realtimeEvent:    UInt32 = 47  // CMD_REALTIME_STATS_EVENT  (band → app: RealTimeStats)
    static let rawSensorAck:     UInt32 = 49  // PHONE_SPORT_DATA_V2A
    static let rawSensorBatch:   UInt32 = 53  // WEAR_SENSOR_DATA
}

// MARK: - Watch face command IDs (GadgetBridge XiaomiWatchfaceService, type=4)

enum XiaomiWatchfaceCmd {
    static let cmdType: UInt32 = 4
    static let list:    UInt32 = 0   // CMD_WATCHFACE_LIST
    static let set:     UInt32 = 1   // CMD_WATCHFACE_SET
    static let delete:  UInt32 = 2   // CMD_WATCHFACE_DELETE
    static let install: UInt32 = 4   // CMD_WATCHFACE_INSTALL (band replies installStatus)
}

// MARK: - App (RPK / quick app) command IDs (GadgetBridge XiaomiRpkService, type=20)

enum XiaomiRpkCmd {
    static let cmdType:   UInt32 = 20
    static let list:      UInt32 = 0   // CMD_RPK_LIST
    static let install:   UInt32 = 1   // CMD_RPK_INSTALL (band replies rpkInstallStart.cmd)
    static let installed: UInt32 = 2   // CMD_RPK_INSTALLED (band → app: install finished)
    static let delete:    UInt32 = 3   // CMD_RPK_DELETE
}

// MARK: - Data upload command IDs (GadgetBridge XiaomiDataUploadService, type=22)

enum XiaomiDataUploadCmd {
    static let cmdType:     UInt32 = 22
    static let uploadStart: UInt32 = 0   // CMD_UPLOAD_START (request + ack share this subtype)

    // Upload payload type tags (first envelope byte after the leading 0x00).
    static let typeWatchface: UInt8 = 16
    static let typeFirmware:  UInt8 = 32   // intentionally unused — firmware flashing is out of scope
    static let typeRpk:       UInt8 = 64
}
