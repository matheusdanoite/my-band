import CoreBluetooth
import Foundation
import Observation

// MARK: - LiveHeartRateSource

enum LiveHeartRateSource: String, Sendable {
    /// Standard Bluetooth SIG GATT Heart Rate Service (`0x180D` / `0x2A37`), emitted when the user
    /// enables "Heart rate sharing" on the band itself.
    case gatt2A37 = "GATT 2A37"
    /// Encrypted Xiaomi protobuf stream (`Health` command `subtype = 47`), driven by `setRealtimeStats(enabled: true)`.
    case protobuf = "Protobuf"
}

// MARK: - GattHeartRatePacket
//
// Pure Bluetooth SIG Heart Rate Measurement (0x2A37) parser and encoder. Independent of
// CoreBluetooth so unit tests can verify 8-bit/16-bit BPM, sensor contact flags, energy expended,
// and RR-interval decoding directly.

struct GattHeartRatePacket: Equatable, Sendable {
    let bpm: Int
    let sensorContactSupported: Bool
    let sensorContactDetected: Bool
    let energyExpendedKj: Int?
    /// RR-intervals in milliseconds (converted from the spec's 1/1024 s resolution).
    let rrIntervalsMs: [Double]

    static func parse(_ data: Data) -> GattHeartRatePacket? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let flags = data[base]
        let is16Bit = (flags & 0x01) != 0
        let contactBits = (flags >> 1) & 0x03
        let contactSupported = contactBits == 0x02 || contactBits == 0x03
        let contactDetected = contactSupported ? (contactBits == 0x03) : true
        let hasEnergy = (flags & 0x08) != 0
        let hasRR = (flags & 0x10) != 0

        var cursor = base + 1
        let bpm: Int
        if is16Bit {
            guard cursor + 2 <= data.endIndex else { return nil }
            bpm = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2
        } else {
            bpm = Int(data[cursor])
            cursor += 1
        }
        guard (25...500).contains(bpm) else { return nil }

        var energyExpended: Int?
        if hasEnergy {
            guard cursor + 2 <= data.endIndex else { return nil }
            energyExpended = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2
        }

        var rrMs: [Double] = []
        if hasRR {
            while cursor + 2 <= data.endIndex {
                let raw = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
                cursor += 2
                if raw > 0 {
                    rrMs.append(Double(raw) * 1000.0 / 1024.0)
                }
            }
        }

        return GattHeartRatePacket(
            bpm: bpm,
            sensorContactSupported: contactSupported,
            sensorContactDetected: contactDetected,
            energyExpendedKj: energyExpended,
            rrIntervalsMs: rrMs
        )
    }

    /// Encodes a standard Bluetooth SIG Heart Rate Measurement (0x2A37) notification payload.
    static func encode(bpm: Int, contactDetected: Bool = true) -> Data {
        let clamped = max(0, min(65_535, bpm))
        let contactBits: UInt8 = contactDetected ? 0b0000_0110 : 0b0000_0100
        if clamped <= 255 {
            return Data([contactBits, UInt8(clamped)])
        } else {
            let flags: UInt8 = contactBits | 0x01
            return Data([flags, UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)])
        }
    }
}

// MARK: - RealtimeHeartRateService
//
// Bridges real-time heart rate from the Mi Band 10 to the rest of the ecosystem in three ways:
//   1. Subscribes to both the band's standard GATT 0x180D/0x2A37 notifications (when the user
//      enables "Heart rate sharing" on the wrist) and the encrypted Xiaomi RealTimeStats stream
//      (subtype 47, which the app can also start on demand via `startSharing()`).
//   2. Writes incoming live HR readings directly to Apple Health (`HealthKit`) every 5 seconds so
//      any iOS app observing `HKQuantityType(.heartRate)` receives live updates.
//   3. Publishes a standard BLE GATT Heart Rate Service (`0x180D` / `0x2A37`) via
//      `CBPeripheralManager` so external devices (Mac, iPad, Apple TV/Zwift, bike computers,
//      gym equipment) can pair with the iPhone as a standard BLE heart rate strap while `My Band`
//      keeps its encrypted link to the band.
//   4. Offers an "External HR app mode" that temporarily releases `My Band`'s BLE link so apps on
//      the same iPhone that only use `scanForPeripherals` (instead of `retrieveConnectedPeripherals`)
//      can discover the Mi Band 10's own `0x180D` advertisement directly.

@Observable
@MainActor
final class RealtimeHeartRateService: NSObject {

    private(set) var currentBPM: Int?
    private(set) var lastUpdatedAt: Date?
    private(set) var lastSource: LiveHeartRateSource?
    /// True when the user explicitly turned on active sharing from the app (drives `setRealtimeStats(enabled: true)`
    /// + the `CBPeripheralManager` 0x180D repeater). Passive readings from the band's wrist toggle still flow
    /// into HealthKit and the repeater even when this is false.
    private(set) var isActiveSharing = false
    /// True while `CBPeripheralManager` is actively advertising `0x180D`.
    private(set) var isBroadcastingBLE = false
    /// Number of external BLE centrals currently subscribed to our `0x2A37` repeater characteristic.
    private(set) var subscribedCentralsCount = 0
    /// Count of real-time HR samples written to Apple Health during the current session.
    private(set) var liveHealthSamplesWritten = 0

    private weak var bandManager: BandManager?
    private let log = AppLogger(category: "LiveHR")

    private var peripheralManager: CBPeripheralManager?
    private var hrMeasurementChar: CBMutableCharacteristic?
    private var hrServiceAdded = false
    private var wantsAdvertising = false

    private var lastHealthWriteDate: Date = .distantPast
    private let healthWriteMinInterval: TimeInterval = 5.0
    private var stalenessTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onLiveHeartRate = { [weak self] bpm, source in
            Task { @MainActor in self?.handleIncomingHeartRate(bpm: bpm, source: source) }
        }
    }

    // MARK: - User Controls

    /// Starts active live HR streaming from the band (`CMD_REALTIME_STATS_START`) and turns on the
    /// iPhone BLE `0x180D` peripheral repeater.
    func startSharing() {
        isActiveSharing = true
        liveHealthSamplesWritten = 0
        if bandManager?.connectionState.isConnected == true {
            bandManager?.setRealtimeStats(enabled: true)
        }
        startKeepAliveLoop()
        startBLEBroadcast()
        log.info("Live HR sharing started (protobuf stream + BLE 180D repeater + HealthKit live write)")
    }

    /// Stops active live HR streaming and turns off the iPhone BLE `0x180D` peripheral repeater.
    func stopSharing() {
        isActiveSharing = false
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if bandManager?.connectionState.isConnected == true {
            bandManager?.setRealtimeStats(enabled: false)
        }
        stopBLEBroadcast()
        log.info("Live HR sharing stopped")
    }

    // MARK: - Incoming Live HR

    private func handleIncomingHeartRate(bpm: Int, source: LiveHeartRateSource) {
        guard (30...240).contains(bpm) else { return }
        let now = Date()
        let wasIdle = (currentBPM == nil)
        currentBPM = bpm
        lastUpdatedAt = now
        lastSource = source

        // When the user turns on "Heart rate sharing" on the band's wrist (GATT 2A37), automatically
        // bring up the iPhone 0x180D repeater too so external devices can also see it.
        if wasIdle, source == .gatt2A37, !isBroadcastingBLE {
            startBLEBroadcast()
        }

        armStalenessWatchdog()
        notifySubscribedCentrals(bpm: bpm)

        if now.timeIntervalSince(lastHealthWriteDate) >= healthWriteMinInterval {
            lastHealthWriteDate = now
            Task { @MainActor in
                do {
                    let written = try await HealthKitManager.shared.writeLiveHeartRate(bpm: bpm, date: now)
                    self.liveHealthSamplesWritten += written
                } catch {
                    self.log.error("Live HR HealthKit write failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func armStalenessWatchdog() {
        stalenessTask?.cancel()
        stalenessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            self.currentBPM = nil
            self.lastSource = nil
            if !self.isActiveSharing && self.isBroadcastingBLE {
                self.stopBLEBroadcast()
            }
        }
    }

    /// The band's `CMD_REALTIME_STATS_START` stream times out on its own after ~30–60 s unless
    /// refreshed. Re-sending every 25 s while `isActiveSharing` is on keeps the stream continuous.
    private func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, self.isActiveSharing else { return }
                if self.bandManager?.connectionState.isConnected == true {
                    self.bandManager?.setRealtimeStats(enabled: true)
                }
            }
        }
    }

    // MARK: - BLE 0x180D Peripheral Repeater

    private func startBLEBroadcast() {
        wantsAdvertising = true
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        } else if peripheralManager?.state == .poweredOn {
            ensureServiceAndStartAdvertising()
        }
    }

    private func stopBLEBroadcast() {
        wantsAdvertising = false
        peripheralManager?.stopAdvertising()
        isBroadcastingBLE = false
        subscribedCentralsCount = 0
    }

    private func ensureServiceAndStartAdvertising() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        if !hrServiceAdded {
            let measurementChar = CBMutableCharacteristic(
                type: MiBandUUID.heartRateMeasurement,
                properties: [.notify],
                value: nil,
                permissions: [.readable]
            )
            // Body Sensor Location: 0x02 = Wrist (Bluetooth SIG HRS specification)
            let locationChar = CBMutableCharacteristic(
                type: MiBandUUID.bodySensorLocation,
                properties: [.read],
                value: Data([0x02]),
                permissions: [.readable]
            )
            let service = CBMutableService(type: MiBandUUID.heartRateService, primary: true)
            service.characteristics = [measurementChar, locationChar]
            hrMeasurementChar = measurementChar
            hrServiceAdded = true
            pm.add(service)
            return
        }
        beginAdvertisingIfNeeded()
    }

    private func beginAdvertisingIfNeeded() {
        guard wantsAdvertising, let pm = peripheralManager, pm.state == .poweredOn else { return }
        if !pm.isAdvertising {
            pm.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [MiBandUUID.heartRateService],
                CBAdvertisementDataLocalNameKey: "Mi Band 10 HR"
            ])
        }
        isBroadcastingBLE = true
        log.info("BLE 180D Heart Rate repeater advertising as 'Mi Band 10 HR'")
    }

    private func notifySubscribedCentrals(bpm: Int) {
        guard let pm = peripheralManager, pm.state == .poweredOn,
              let char = hrMeasurementChar, subscribedCentralsCount > 0 else { return }
        let payload = GattHeartRatePacket.encode(bpm: bpm, contactDetected: true)
        _ = pm.updateValue(payload, for: char, onSubscribedCentrals: nil)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension RealtimeHeartRateService: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn && wantsAdvertising {
            ensureServiceAndStartAdvertising()
        } else if peripheral.state != .poweredOn {
            isBroadcastingBLE = false
            subscribedCentralsCount = 0
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("Failed to add 180D GATT service: \(error.localizedDescription)")
            hrServiceAdded = false
            return
        }
        beginAdvertisingIfNeeded()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentralsCount += 1
        log.info("External BLE central subscribed to 2A37 (subscribers=\(self.subscribedCentralsCount))")
        if let bpm = currentBPM {
            notifySubscribedCentrals(bpm: bpm)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentralsCount = max(0, subscribedCentralsCount - 1)
        log.info("External BLE central unsubscribed from 2A37 (subscribers=\(self.subscribedCentralsCount))")
    }
}
