import SwiftUI
import SwiftData

@main
struct My_BandApp: App {

    // static: garantia de única inicialização por processo.
    // App structs do SwiftUI podem ser recriadas durante setup de cena,
    // o que faria um `var` recriar o container (e o store SQLite) a cada vez.
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
            // Store corrompido (ex: watchdog kill durante gravação).
            // Em dev: apaga e recria. Em prod isso perderia dados — trocar por migração adequada.
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
            switch phase {
            case .background:
                // Garante que há um pedido de sync agendado.
                BackgroundSyncManager.shared.scheduleNext()
            case .active:
                // Voltando ao foreground após tempo em background: reassume a conexão. O
                // auto-reconnect do BLE normalmente já mantém o link, mas uma queda com o app
                // suspenso pode ter deixado nada pendente — este empurrão evita um "desconectado"
                // morto sem como reconectar.
                AppServices.shared.reconnectIfNeeded()
            default:
                break
            }
        }
    }
}
