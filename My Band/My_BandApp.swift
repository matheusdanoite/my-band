import SwiftUI
import SwiftData

@main
struct My_BandApp: App {

    // static: guarantees a single initialization per process.
    // SwiftUI App structs can be recreated during scene setup,
    // which would make a `var` recreate the container (and the SQLite store) every time.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            BandDevice.self,
            SleepSession.self,
            ActivityDay.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Corrupted store (e.g. watchdog kill during a write).
            // In dev: delete and recreate. In prod this would lose data — replace with a proper migration.
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-shm"))
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-wal"))
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch let secondError {
                fatalError("Could not create ModelContainer even after store reset: \(secondError)")
            }
        }
    }()

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // On platforms without the UIKit AppDelegate (native macOS) nothing else bootstraps the
        // services; do it here. Idempotent, so on iOS — where the AppDelegate already ran it before
        // the scene loaded — this is a no-op. App.init is main-actor isolated (App is @MainActor).
        #if !canImport(UIKit)
        AppServices.shared.bootstrap(container: Self.sharedModelContainer)
        #endif
    }

    var body: some Scene {
        // Managers live in AppServices, created + wired from the launch path (AppDelegate on iOS,
        // init() above elsewhere) so a headless state-restoration / BGTask launch sets them up
        // without any scene. See AppServices for why this can't live in a SwiftUI .onAppear.
        let services = AppServices.shared
        return WindowGroup {
            RootView()
                .environment(services.bandManager)
                .environment(services.bandSyncer)
                .environment(services.customization)
                .environment(services.scaleManager)
                .environment(services.rawSensorCapture)
                .onOpenURL { url in
                    // Shared file ("Abrir com → My Band") for a .bin/.rpk. Installs against the
                    // live connection; progress/result surface in CustomizeView.
                    Task { await services.customization.installFromFile(url) }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .onChange(of: scenePhase) { _, phase in
            AppLogger(category: "App").info("Scene phase → \(String(describing: phase))")
            switch phase {
            case .background:
                // Ensures a sync request is scheduled.
                BackgroundSyncManager.shared.scheduleNext()
            case .active:
                // Returning to the foreground after time in the background: resume the connection. BLE
                // auto-reconnect normally keeps the link alive already, but a drop while the app was
                // suspended may have left nothing pending — this nudge avoids a dead "disconnected"
                // state with no way to reconnect.
                AppServices.shared.reconnectIfNeeded()
            default:
                break
            }
        }
    }
}
