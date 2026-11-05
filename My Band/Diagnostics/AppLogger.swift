import Foundation
import OSLog

// MARK: - AppLogger
//
// Drop-in for os.Logger on the connection/sync path: same call sites, but every line also lands in
// DiagnosticLog's file, which is what gets exported after a night the band synced unwatched.
// Interpolations render eagerly (Logger's are lazy) — a cost only on debug lines, which the file
// wants anyway.

nonisolated enum AppLogPrivacy: Sendable {
    case auto, `public`, `private`, sensitive
}

nonisolated struct AppLogMessage: ExpressibleByStringInterpolation, Sendable {

    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    nonisolated struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) { text += literal }

        mutating func appendInterpolation<T>(_ value: T) { text += String(describing: value) }

        /// `.private` and `.sensitive` stay redacted in the file too — it leaves the phone when exported.
        mutating func appendInterpolation<T>(_ value: T, privacy: AppLogPrivacy) {
            switch privacy {
            case .auto, .public:       text += String(describing: value)
            case .private, .sensitive: text += "<private>"
            }
        }
    }
}

nonisolated struct AppLogger: Sendable {

    private let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: category)
    }

    func debug(_ message: AppLogMessage)   { emit(.debug, message) }
    func info(_ message: AppLogMessage)    { emit(.info, message) }
    func notice(_ message: AppLogMessage)  { emit(.notice, message) }
    func warning(_ message: AppLogMessage) { emit(.warning, message) }
    func error(_ message: AppLogMessage)   { emit(.error, message) }
    func fault(_ message: AppLogMessage)   { emit(.fault, message) }

    private func emit(_ level: DiagnosticLevel, _ message: AppLogMessage) {
        // Public in the unified log: private values were already redacted while rendering.
        logger.log(level: level.osType, "\(message.text, privacy: .public)")
        DiagnosticLog.shared.append(level, category: category, message.text)
    }
}
