import Testing
import Foundation
@testable import My_Band

struct DiagnosticLogTests {

    private func makeLog(maxFileBytes: Int = 1_000_000) -> DiagnosticLog {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return DiagnosticLog(directory: directory, maxFileBytes: maxFileBytes)
    }

    @Test func linesLandInTheFileWithLevelAndCategory() throws {
        let log = makeLog()
        log.append(.warning, category: "Sync", "FETCH_TODAY → 3 file ID(s)")
        log.flush()
        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(text.contains("[WRN] Sync: FETCH_TODAY → 3 file ID(s)"))
    }

    @Test func rotatesIntoOnePreviousGenerationAndExportsBoth() async throws {
        let log = makeLog(maxFileBytes: 200)
        for i in 0 ..< 20 { log.append(.info, category: "Sync", "line \(i) padding padding") }
        log.flush()

        #expect(FileManager.default.fileExists(atPath: log.previousFile.path(percentEncoded: false)))
        let export = try #require(await log.makeExport(header: "HEADER"))
        let text = try String(contentsOf: export, encoding: .utf8)
        #expect(text.hasPrefix("HEADER\n\n"))
        #expect(text.contains("line 19 padding"))
        #expect(!text.contains("line 0 padding"))
    }

    @Test func clearRemovesBothGenerations() async {
        let log = makeLog(maxFileBytes: 200)
        for i in 0 ..< 10 { log.append(.info, category: "Sync", "line \(i) padding padding") }
        log.flush()
        #expect(await log.sizeInBytes() > 0)

        await log.clear()
        #expect(await log.sizeInBytes() == 0)
    }

    @Test func privateInterpolationsStayRedactedInTheRenderedLine() {
        let latitude = -25.39
        let message: AppLogMessage = "GPS \(latitude, privacy: .private) sent, \(3) point(s), \(latitude, privacy: .public)"
        #expect(message.text == "GPS <private> sent, 3 point(s), -25.39")
    }
}
