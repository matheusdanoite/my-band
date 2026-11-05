import SwiftUI

// MARK: - ConnectionState → UI
//
// Maps the BLE connection state to glanceable status (pill label/tone) and to the
// monospace step line shown during the connecting handshake. English, sentence case.

extension ConnectionState {

    /// Short label for a status pill, present on every screen.
    var pillLabel: String {
        switch self {
        case .connected:           "Connected"
        case .scanning:            "Searching…"
        case .connecting, .discoveringServices, .sessionConfig, .authenticating:
                                   "Connecting…"
        case .awaitingPairingConfirmation: "Confirm pairing"
        case .disconnected:        "Disconnected"
        case .bluetoothUnavailable: "Bluetooth off"
        case .error:               "Connection error"
        }
    }

    var pillTone: MBStatusPill.Tone {
        switch self {
        case .connected: .ok
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: .warn
        case .disconnected, .bluetoothUnavailable, .error: .danger
        }
    }

    /// Whether the status dot should pulse (transient/in-progress states).
    var pillPulses: Bool {
        switch self {
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    /// Detailed, technical-honest line for the connecting screen (monospace).
    var handshakeStep: String {
        switch self {
        case .scanning:            "Searching for Xiaomi Smart Band 10…"
        case .connecting:          "Connecting to device…"
        case .discoveringServices: "Discovering FE95 service…"
        case .sessionConfig:       "Negotiating session…"
        case .authenticating:      "Handshake HMAC-SHA256…"
        case .awaitingPairingConfirmation:
                                   "Waiting for your confirmation."
        case .connected:           "Connected."
        case .disconnected:        "Disconnected."
        case .bluetoothUnavailable: "Turn on Bluetooth to continue."
        case .error(let msg):      msg
        }
    }

    var isConnecting: Bool {
        switch self {
        case .scanning, .connecting, .discoveringServices, .sessionConfig, .authenticating,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        if case .bluetoothUnavailable = self { return true }
        return false
    }
}
