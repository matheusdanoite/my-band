import Foundation
import OSLog

// MARK: - CustomizationManager
//
// Front door for installing watch faces and quick apps. Owns the shared upload engine and the two
// install services, parses an incoming file (from the document picker, a shared file, or a URL),
// and routes it to the right channel by detected type.

@Observable
@MainActor
final class CustomizationManager {

    let upload = DataUploadService()
    let watchfaces: WatchfaceService
    let apps: AppInstallService

    struct InstallResult { let message: String; let isError: Bool }

    /// Result of the last install attempt (nil = none yet). Surfaced by CustomizeView.
    private(set) var lastResult: InstallResult?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Customize")

    init() {
        watchfaces = WatchfaceService(upload: upload)
        apps = AppInstallService(upload: upload)
    }

    /// True while a face or app is uploading.
    var isInstalling: Bool { watchfaces.installProgress != nil || apps.installProgress != nil }
    /// Combined 0...1 progress of whichever install is running.
    var progress: Double? { watchfaces.installProgress ?? apps.installProgress }

    func setup(manager: BandManager) {
        upload.setup(manager: manager)
        watchfaces.setup(manager: manager)
        apps.setup(manager: manager)
    }

    /// Asks the band for its current face/app lists (call when the screen appears).
    func refresh() {
        watchfaces.requestList()
        apps.requestList()
    }

    // MARK: - Import entry points

    /// Reads a file picked from Files / shared into the app, then installs it.
    func installFromFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            await install(data: data, sourceName: url.lastPathComponent)
        } catch {
            fail("Failed to read the file: \(error.localizedDescription)")
        }
    }

    /// Downloads a file from a URL, then installs it.
    func installFromURL(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            await install(data: data, sourceName: url.lastPathComponent)
        } catch {
            fail("Failed to download: \(error.localizedDescription)")
        }
    }

    // MARK: - Install

    private func install(data: Data, sourceName: String) async {
        guard let file = InstallableFile.parse(data) else {
            fail("Unrecognized file. Expected a watch face (.bin) or app (.rpk).")
            return
        }
        log.info("Parsed \(sourceName) → \(String(describing: file.kind)) id=\(file.id)")
        do {
            switch file.kind {
            case .watchface:
                try await watchfaces.install(file)
                lastResult = InstallResult(message: "Watch face \"\(file.name)\" instalada.", isError: false)
            case .app:
                try await apps.install(file)
                lastResult = InstallResult(message: "App \"\(file.name)\" sent to the band.", isError: false)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        log.error("Install failed: \(message)")
        lastResult = InstallResult(message: message, isError: true)
    }
}
