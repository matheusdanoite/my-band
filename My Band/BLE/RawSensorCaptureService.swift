import Foundation
import OSLog

@Observable
@MainActor
final class RawSensorCaptureService {

    private(set) var isCapturing = false
    private(set) var sampleCount = 0
    private(set) var currentCaptureURL: URL?
    private(set) var captureURLs: [URL] = []

    var onSample: ((RawSensorSample) -> Void)?

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "RawSensor")
    private var fileHandle: FileHandle?
    private var stopTask: Task<Void, Never>?
    private var ackCounter: UInt32 = 0
    private var batchesSinceAck = 0
    private var samples: [RawSensorSample] = []

    func setup(manager: BandManager) {
        bandManager = manager
        refreshCaptures()
        manager.onRawSensorWorkoutOpen = { [weak self] in
            Task { @MainActor in
                self?.handleWorkoutOpen()
            }
        }
        manager.onRawSensorCommand = { [weak self] command in
            Task { @MainActor in
                self?.handleBatch(command)
            }
        }
    }

    func startCapture(duration: Duration = .seconds(60)) throws {
        guard !isCapturing else { return }
        guard bandManager?.connectionState.isConnected == true else {
            throw RawSensorCaptureError.notConnected
        }

        let directory = try captureDirectory()
        let formatter = ISO8601DateFormatter()
        let startedAt = Date.now
        let filename = "raw-sensor-\(formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")).csv"
        let url = directory.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(XiaomiRawSensorProtocol.csvHeader.utf8))

        fileHandle = handle
        currentCaptureURL = url
        captureURLs.insert(url, at: 0)
        sampleCount = 0
        ackCounter = 0
        batchesSinceAck = 0
        samples = []
        isCapturing = true

        bandManager?.setRealtimeStats(enabled: true)
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiRawSensorProtocol.startCommand())
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stopCapture() }
        }
        log.info("Raw sensor capture started: \(url.lastPathComponent)")
    }

    func stopCapture() {
        guard isCapturing else { return }
        stopTask?.cancel()
        stopTask = nil

        bandManager?.setRealtimeStats(enabled: false)
        for command in XiaomiRawSensorProtocol.stopCommands() {
            bandManager?.sendEncryptedCommand(protoBytes: command)
        }
        writeRows()
        closeFile()
        isCapturing = false
        log.info("Raw sensor capture stopped: \(self.sampleCount) samples")
    }

    func refreshCaptures() {
        guard let directory = try? captureDirectory() else {
            captureURLs = []
            return
        }
        captureURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "csv" }
        .sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return lhsDate > rhsDate
        } ?? []
    }

    private func handleWorkoutOpen() {
        guard isCapturing else { return }
        bandManager?.sendEncryptedCommand(
            protoBytes: XiaomiProto.workoutOpenReplyCommand(gpsReady: true)
        )
    }

    private func handleBatch(_ command: Data) {
        guard isCapturing else { return }
        let samples = XiaomiRawSensorProtocol.parseSamples(from: command)
        guard !samples.isEmpty else { return }

        for sample in samples {
            self.samples.append(sample)
            sampleCount += 1
            onSample?(sample)
        }

        batchesSinceAck += 1
        if batchesSinceAck >= 10 {
            batchesSinceAck = 0
            ackCounter += 1
            bandManager?.sendEncryptedCommand(
                protoBytes: XiaomiRawSensorProtocol.ackCommand(counter: ackCounter)
            )
        }
    }

    private func writeRows() {
        let rows = XiaomiRawSensorProtocol.motionRows(from: samples)
        for row in rows {
            guard let data = XiaomiRawSensorProtocol.csvRow(for: row).data(using: .utf8) else {
                continue
            }
            do {
                try fileHandle?.write(contentsOf: data)
            } catch {
                log.error("Raw sensor write failed: \(error.localizedDescription)")
                break
            }
        }
        samples.removeAll(keepingCapacity: false)
    }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func captureDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("RawSensorCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum RawSensorCaptureError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "A pulseira precisa estar conectada para iniciar a captura."
        }
    }
}
