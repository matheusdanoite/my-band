import Foundation
import SwiftData

// MARK: - AppServices
//
// Process-wide owner of the long-lived managers (BLE, sync, customization, scale) and the single
// place that wires them together. Created and bootstrapped from the launch path — the AppDelegate on
// iOS, the App initializer elsewhere — NOT from a SwiftUI .onAppear.
//
// Why not .onAppear: a CoreBluetooth state-restoration relaunch (the band coming back in range) or a
// BGTask launch has no visible scene, so .onAppear never fires. The previous design wired everything
// in .onAppear, which meant that on such a headless launch BandSyncer.onAuthenticated was never set
// and BackgroundSyncManager had no dependencies — the band could reconnect but nothing ever synced.
// Bootstrapping from the launch path fixes that and guarantees the CBCentralManager (with its restore
// identifier) is instantiated early enough to receive willRestoreState.

@MainActor
final class AppServices {

    static let shared = AppServices()

    let bandManager   = BandManager()
    let bandSyncer    = BandSyncer()
    let customization = CustomizationManager()
    let scaleManager  = ScaleManager()
    let rawSensorCapture = RawSensorCaptureService()

    private var didBootstrap = false

    private init() {}

    /// Wires the managers and kicks off a reconnect to the known device. Idempotent — safe to call
    /// from both the AppDelegate and the App initializer, in any order, on any launch.
    func bootstrap(container: ModelContainer) {
        guard !didBootstrap else { return }
        didBootstrap = true

        bandSyncer.setup(manager: bandManager, context: container.mainContext)
        customization.setup(manager: bandManager)
        rawSensorCapture.setup(manager: bandManager)
        bandSyncer.loadStoredDevice()
        BackgroundSyncManager.shared.configure(manager: bandManager, syncer: bandSyncer)
        // Broadcast-only scale: a foreground listen is enough; harmless on a headless launch.
        scaleManager.start()

        // Drive the band connection from the launch path so a headless (state-restoration / BGTask)
        // relaunch re-establishes the link without waiting for any UI to appear. The foreground UI
        // (RootView) still guards its own bootstrap, so this is just the background-safe trigger.
        if AuthKeyStore.isStored, let id = bandSyncer.currentDevice?.peripheralIdentifier {
            bandManager.reconnectToKnownDevice(identifier: id)
        }
    }

    /// Foreground nudge: if a device is paired and we're not connected, (re)arm the connection. Safe
    /// to call repeatedly — a no-op when already connected, and a standing connect dedups at the
    /// CoreBluetooth level. Complements the BLE auto-reconnect for the case where a drop while the app
    /// was suspended left nothing pending, so returning to foreground never shows a dead "disconnected" state.
    func reconnectIfNeeded() {
        guard AuthKeyStore.isStored,
              let id = bandSyncer.currentDevice?.peripheralIdentifier,
              !bandManager.connectionState.isConnected else { return }
        bandManager.reconnectToKnownDevice(identifier: id)
    }
}
