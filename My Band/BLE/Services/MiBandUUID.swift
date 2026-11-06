import CoreBluetooth

// MARK: - Mi Band 10 BLE V2 UUIDs
// Confirmed via GadgetBridge XiaomiUuids.java (BLE_V2_CHARACTERISTIC_*):
// Service FE95 carries ALL communication via only 2 characteristics in V2:
//   005F — notify (band → app): ALL SPP V2 frames — command responses AND activity data
//   005E — write  (app → band): ALL SPP V2 frames — session config, auth, health commands
//
// Activity data is NOT on a separate characteristic in V2 — it arrives on 005F
// and is differentiated by the channel byte (0x05) inside the SPP DATA packet payload.
//
// V1 (Mi Band 8) used 0051/0052/0053 — Mi Band 10 uses V2 (005E/005F only).

enum MiBandUUID {

    // MARK: - Service

    static let mainService = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")

    // MARK: - Characteristics (V2)

    /// Notify (band → app): ALL SPP V2 frames — commands, auth responses, AND activity data
    /// GadgetBridge: BLE_V2_CHARACTERISTIC_RX_UUID (phone receives on this)
    static let commandRead  = CBUUID(string: "0000005E-0000-1000-8000-00805F9B34FB")
    /// Write (app → band): SPP V2 frames — session config, auth, health commands
    /// GadgetBridge: BLE_V2_CHARACTERISTIC_TX_UUID (phone transmits on this)
    static let commandWrite = CBUUID(string: "0000005F-0000-1000-8000-00805F9B34FB")

    // MARK: - Battery Service (standard GATT)

    /// Not part of the Xiaomi protocol — it's what iOS itself reads to show the band in the
    /// Batteries widget, so reading it keeps the app's number identical to the widget's.
    static let batteryService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")
    /// Battery Level: a single UInt8, 0–100.
    static let batteryLevel   = CBUUID(string: "00002A19-0000-1000-8000-00805F9B34FB")

    // MARK: - Heart Rate Service (standard GATT)

    /// Standard Bluetooth SIG Heart Rate Service exposed by the Mi Band 10 (`Services: 180D, 180F, FE95`)
    /// when Heart Rate Sharing is enabled on the band, and also used by our CBPeripheralManager repeater.
    static let heartRateService     = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB")
    /// Heart Rate Measurement characteristic (`[flags: UInt8][bpm: UInt8 or UInt16 LE]...`, notify).
    static let heartRateMeasurement = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB")
    /// Body Sensor Location characteristic (`UInt8`: 2 = Wrist, read).
    static let bodySensorLocation   = CBUUID(string: "00002A38-0000-1000-8000-00805F9B34FB")

    // MARK: - Scan

    static let scanServices: [CBUUID] = [mainService]
}
