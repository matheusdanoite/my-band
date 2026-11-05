import Foundation
import OSLog

// MARK: - DataUploadService
//
// Chunked file-upload engine for the Mi Band 10 (GadgetBridge XiaomiDataUploadService, type=22).
// Shared by watch faces and apps — only the `type` tag differs.
//
// Flow:
//   1. App → band: CMD_UPLOAD_START { type, md5(file), size }                 (encrypted Command)
//   2. Band → app: dataUploadAck { unknown2, resumePosition, chunkSize? }
//   3. App builds the envelope and streams it as DATA-channel chunks (plaintext):
//        envelope = [0x00][type][md5:16][size:u32 LE][file bytes from resumePosition]
//        payload  = envelope + crc32(envelope):u32 LE
//        each chunk = [totalParts:u16 LE][currentPart:u16 LE][payload slice of (chunkSize-4)]
//
// The band tracks completion by part numbers; it re-verifies the md5 and crc32 on its side.

@MainActor
final class DataUploadService {

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Upload")

    private var ackContinuation: CheckedContinuation<Xiaomi_DataUploadAck, Error>?

    enum UploadError: LocalizedError {
        case notConnected, rejected, timeout, md5Failed

        var errorDescription: String? {
            switch self {
            case .notConnected: "Band not connected."
            case .rejected:     "The band rejected the upload."
            case .timeout:      "Timed out during upload."
            case .md5Failed:    "Failed to compute the file checksum."
            }
        }
    }

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onDataUploadCommand = { [weak self] cmd in
            Task { @MainActor in self?.handleCommand(cmd) }
        }
    }

    private func handleCommand(_ cmd: Xiaomi_Command) {
        guard cmd.subtype == XiaomiDataUploadCmd.uploadStart,
              cmd.hasDataUpload, cmd.dataUpload.hasDataUploadAck else { return }
        let ack = cmd.dataUpload.dataUploadAck
        if let cont = ackContinuation {
            ackContinuation = nil
            cont.resume(returning: ack)
        }
    }

    /// Uploads `bytes` tagged `type` (TYPE_WATCHFACE / TYPE_RPK). Calls `onProgress` (0...1) as
    /// parts are sent; returns when the final part is written.
    func upload(type: UInt8, bytes: Data, onProgress: (Double) -> Void) async throws {
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw UploadError.notConnected
        }

        let md5 = Checksums.md5(bytes)
        guard md5.count == 16 else { throw UploadError.md5Failed }

        log.info("Upload start — type=\(type) size=\(bytes.count)B")
        manager.sendEncryptedCommand(
            protoBytes: XiaomiProto.dataUploadRequestCommand(type: type, md5: md5, size: bytes.count)
        )

        let ack = try await waitForAck(timeout: .seconds(15))
        guard ack.unknown2 == 0 else {
            log.error("Upload rejected (unknown2=\(ack.unknown2))")
            throw UploadError.rejected
        }

        let resume = Int(ack.resumePosition)
        let chunkSize = ack.hasChunkSize ? Int(ack.chunkSize) : 2048
        log.info("Upload accepted — resume=\(resume) chunkSize=\(chunkSize)")

        // Envelope (note: declared size is the FULL file length, not the remaining bytes).
        var envelope = Data()
        envelope.append(0x00)
        envelope.append(type)
        envelope.append(md5)
        envelope.append(uint32LE(UInt32(bytes.count)))
        envelope.append(bytes.dropFirst(resume))

        var payload = envelope
        payload.append(uint32LE(Checksums.crc32(envelope)))

        let partSize = max(1, chunkSize - 4)
        let totalParts = (payload.count + partSize - 1) / partSize
        guard totalParts <= 0xFFFF else { throw UploadError.rejected }

        for i in 0..<totalParts {
            let start = payload.index(payload.startIndex, offsetBy: i * partSize)
            let end = payload.index(start, offsetBy: partSize, limitedBy: payload.endIndex) ?? payload.endIndex
            var chunk = Data()
            chunk.append(uint16LE(UInt16(totalParts)))
            chunk.append(uint16LE(UInt16(i + 1)))
            chunk.append(payload[start..<end])
            await manager.sendDataChunk(chunk)
            onProgress(Double(i + 1) / Double(totalParts))
        }
        log.info("Upload finished — \(totalParts) part(s) sent")
    }

    // MARK: - Ack wait

    private func waitForAck(timeout: Duration) async throws -> Xiaomi_DataUploadAck {
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if let cont = ackContinuation {
                ackContinuation = nil
                cont.resume(throwing: UploadError.timeout)
            }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            // Guard against a leaked continuation from a prior (aborted) upload.
            ackContinuation?.resume(throwing: UploadError.timeout)
            ackContinuation = cont
        }
    }

    // MARK: - LE helpers

    private func uint16LE(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
