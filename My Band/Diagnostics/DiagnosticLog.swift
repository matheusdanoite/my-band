import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DiagnosticLog
//
// Persistent, exportable trail of connections and syncs (exported from UI/Settings/DiagnosticsView).
// The sync most worth debugging runs with nobody watching: the band reaching the phone at night
// relaunches the app in the background, and each activity file is fetched and ACKed once. The
// unified log keeps that only as long as the system chooses, and OSLogStore on iOS reads the current
// process alone — not last night's. So every AppLogger line is also appended here.
//
// Two files rotated by size (current + one previous generation), written on a serial queue with
// completeUntilFirstUserAuthentication protection, so a sync with the phone locked can still log.
// Before the first unlock after boot the file can't be opened at all; lines wait in memory until it can.
//
// The file leaves the phone when exported: the AuthKey and session keys are never logged (CLAUDE.md),
// and `.private` interpolations are redacted before they get here.

nonisolated enum DiagnosticLevel: String, Sendable {
    case debug = "DBG", info = "INF", notice = "NTC", warning = "WRN", error = "ERR", fault = "FLT"

    var osType: OSLogType {
        switch self {
        case .debug:           .debug
        case .info:            .info
        case .notice:          .default
        case .warning, .error: .error
        case .fault:           .fault
        }
    }
}

nonisolated final class DiagnosticLog: @unchecked Sendable {

    static let shared = DiagnosticLog()

    private static let maxPendingLines = 2_000

    let currentFile: URL
    let previousFile: URL
    private let directory: URL
    private let maxFileBytes: Int
    private let queue = DispatchQueue(label: "com.myband.diagnostic-log", qos: .utility)

    // Touched only on `queue`.
    private var handle: FileHandle?
    private var currentBytes = 0
    private var pending: [Data] = []

    /// 2 MB per generation holds several nights of syncs at full verbosity, raw sleep files included.
    init(directory: URL = .applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory),
         maxFileBytes: Int = 2_000_000) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        currentFile = directory.appending(path: "my-band.log")
        previousFile = directory.appending(path: "my-band.1.log")
    }

    func append(_ level: DiagnosticLevel, category: String, _ message: String, at date: Date = Date()) {
        queue.async { [self] in
            let body = message.replacingOccurrences(of: "\n", with: "\n    ")
            write(Data("\(date.logStamp(fractionalSeconds: true)) [\(level.rawValue)] \(category): \(body)\n".utf8))
        }
    }

    /// Returns once every line appended so far has been handed to the file.
    func flush() { queue.sync {} }

    func sizeInBytes() async -> Int {
        await onQueue { [self] in Self.fileSize(previousFile) + Self.fileSize(currentFile) }
    }

    /// Header, previous generation and current file, joined into one text file for the share sheet.
    func makeExport(header: String) async -> URL? {
        await onQueue { [self] in
            try? handle?.synchronize()
            let fm = FileManager.default
            let exportDirectory = fm.temporaryDirectory.appending(path: "DiagnosticsExport", directoryHint: .isDirectory)
            try? fm.removeItem(at: exportDirectory)

            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd-HHmm"
            let url = exportDirectory.appending(path: "my-band-log-\(stamp.string(from: Date())).txt")

            var body = Data((header + "\n\n").utf8)
            for file in [previousFile, currentFile] {
                if let data = try? Data(contentsOf: file) { body.append(data) }
            }
            do {
                try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                try body.write(to: url)
                return url
            } catch {
                return nil
            }
        }
    }

    func clear() async {
        await onQueue { [self] in
            try? handle?.close()
            handle = nil
            currentBytes = 0
            pending.removeAll()
            try? FileManager.default.removeItem(at: currentFile)
            try? FileManager.default.removeItem(at: previousFile)
        }
    }

    // MARK: - Queue-confined

    private func write(_ line: Data) {
        pending.append(line)
        if pending.count > Self.maxPendingLines {
            pending.removeFirst(pending.count - Self.maxPendingLines)
        }
        guard let handle = openIfNeeded() else { return }

        let chunk = pending.reduce(into: Data()) { $0.append($1) }
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            try? handle.close()
            self.handle = nil
            return
        }
        pending.removeAll(keepingCapacity: true)
        currentBytes += chunk.count
        if currentBytes >= maxFileBytes { rotate() }
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        let path = currentFile.path(percentEncoded: false)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
            if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil, attributes: protection) {
                return nil
            }
            let opened = try FileHandle(forWritingTo: currentFile)
            currentBytes = Int(try opened.seekToEnd())
            handle = opened
            return opened
        } catch {
            return nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        currentBytes = 0
        try? FileManager.default.removeItem(at: previousFile)
        try? FileManager.default.moveItem(at: currentFile, to: previousFile)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Context helpers

nonisolated extension DiagnosticLog {

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    /// Hardware identifier (e.g. "iPhone17,1") — `UIDevice.model` only says "iPhone".
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The message plus domain and code: HealthKit's and CoreBluetooth's texts alone don't tell
    /// "phone locked" apart from "not authorized".
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let parts = start.duration(to: .now).components
        return String(format: "%.1f s", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// App state and whether protected data is readable — a background sync with the phone locked
    /// fails its Apple Health queries.
    @MainActor static func appContext() -> String {
        #if canImport(UIKit)
        let app = UIApplication.shared
        let state = switch app.applicationState {
        case .active:     "active"
        case .inactive:   "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        return "app \(state), protected data \(app.isProtectedDataAvailable ? "available" : "unavailable")"
        #else
        return "app state n/a"
        #endif
    }
}

nonisolated extension Date {

    /// Local wall-clock time with UTC offset — the log gets read against "I went to bed at 23:40".
    var logStamp: String { logStamp(fractionalSeconds: false) }

    func logStamp(fractionalSeconds: Bool) -> String {
        formatted(Date.ISO8601FormatStyle(dateTimeSeparator: .space,
                                          includingFractionalSeconds: fractionalSeconds,
                                          timeZone: .current))
    }
}
