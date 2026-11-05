#if canImport(UIKit)
import UIKit

/// Minimal app delegate that sets up the background-capable services before the app finishes
/// launching. Two things MUST happen here, in the one moment iOS guarantees before the scene loads:
/// BGTaskScheduler.register (only allowed pre-launch), and creating + wiring the BLE/sync managers —
/// a CoreBluetooth state-restoration relaunch has no scene, so a SwiftUI .onAppear would never run.
/// didFinishLaunching is main-actor isolated (UIApplicationDelegate is @MainActor), so the
/// @MainActor managers can be touched directly.
final class AppDelegate: NSObject, UIApplicationDelegate {

    private let log = AppLogger(category: "App")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Opens every process in the diagnostic log. What launched it shows in the next lines: the
        // "State restored" line says whether the band was already connected (a CoreBluetooth
        // relaunch), a BGTask or intent logs its own start. launchOptions can't tell — under the
        // SwiftUI lifecycle `.bluetoothCentrals` came back nil on every BLE relaunch in the hardware
        // log of 2026-10-11, so the old "BLE state restoration=false" was wrong each time.
        log.notice("Launch \(DiagnosticLog.appVersion) — \(DiagnosticLog.appContext())")
        BackgroundSyncManager.shared.register()
        AppServices.shared.bootstrap(container: My_BandApp.sharedModelContainer)
        return true
    }

    // Lock state next to the sync lines: Apple Health can't be queried while the phone is locked,
    // which is when the band usually reaches us.
    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        log.info("Phone locked — protected data unavailable")
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        log.info("Phone unlocked — protected data available")
        BackgroundSyncManager.shared.protectedDataBecameAvailable()
    }

    // Only reached when iOS terminates the app while it runs (not when it kills a suspended one) —
    // still, it tells a gap in the log after it apart from one where the process just vanished.
    func applicationWillTerminate(_ application: UIApplication) {
        log.notice("App terminating")
        DiagnosticLog.shared.flush()
    }
}
#endif
