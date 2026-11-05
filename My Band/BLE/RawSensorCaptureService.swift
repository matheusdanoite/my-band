import Foundation
import OSLog

@Observable
@MainActor
final class RawSensorCaptureService {

    private(set) var isCapturing = false
    private(set) var sampleCount = 0
    private(set) var currentCaptureURL: URL?

    var onSample: ((RawSensorSample) -> Void)?

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "RawSensor")
    private var fileHandle: FileHandle?
    private var stopTask: Task<Void, Never>?
    private var ackCounter: UInt32 = 0
    private var batchesSinceAck = 0

    func setup(manager: BandManager) {
        bandManager = manager
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
        let filename = "raw-sensor-\(formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")).csv"
        let url = directory.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("sensor,timestamp,received_at,x,y,z\n".utf8))

        fileHandle = handle
        currentCaptureURL = url
        sampleCount = 0
        ackCounter = 0
        batchesSinceAck = 0
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
        closeFile()
        isCapturing = false
        log.info("Raw sensor capture stopped: \(self.sampleCount) samples")
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
            let line = "\(sample.kind.rawValue),\(sample.timestamp),\(sample.receivedAt.timeIntervalSince1970),\(sample.x),\(sample.y),\(sample.z)\n"
            guard let data = line.data(using: .utf8) else { continue }
            do {
                try fileHandle?.write(contentsOf: data)
            } catch {
                log.error("Raw sensor write failed: \(error.localizedDescription)")
                stopCapture()
                return
            }
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
