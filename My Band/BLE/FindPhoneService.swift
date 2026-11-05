import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
import AudioToolbox
import UserNotifications

// MARK: - FindPhoneService
//
// Implements the Mi Band 10 "find phone" feature. The band pushes a System command
// (type=2, subtype=17 CMD_FIND_PHONE); BandManager decodes it and calls onFindPhone(start).
//   start == true  → band's "find phone" button pressed → ring the iPhone
//   start == false → user dismissed it on the band       → stop ringing
//
// The alarm must be audible even with the ring/silent switch off and while the app is in the
// background (the BLE central wakes the app). We therefore:
//   • run an AVAudioSession in the .playback category (overrides the mute switch, plays at media
//     volume, and — with the "audio" UIBackgroundMode — keeps playing while backgrounded);
//   • loop a synthesized two-tone siren via AVAudioPlayer (no bundled asset needed);
//   • pulse the haptics on a timer;
//   • post a local notification so the alert is visible on the lock screen.

@Observable
@MainActor
final class FindPhoneService: NSObject {

    private(set) var isAlerting = false

    // Safety cap: if the band never sends the STOP command (e.g. it goes out of range mid-alert)
    // we don't want the phone ringing forever.
    private let maxAlertDuration: Duration = .seconds(45)

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "FindPhone")

    private var player: AVAudioPlayer?
    private var hapticTimer: Timer?
    private var autoStopTask: Task<Void, Never>?

    private let notificationID = "com.myband.findphone"

    // MARK: - Setup

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onFindPhone = { [weak self] start in
            Task { @MainActor in start ? self?.start() : self?.stop() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "FindPhone")
                .error("Notification authorization failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Alert control

    func start() {
        guard !isAlerting else { return }
        isAlerting = true
        log.info("Find phone alert starting")

        startAudio()
        startHaptics()
        postNotification()

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self, maxAlertDuration] in
            try? await Task.sleep(for: maxAlertDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard isAlerting else { return }
        isAlerting = false
        log.info("Find phone alert stopping")

        autoStopTask?.cancel()
        autoStopTask = nil

        player?.stop()
        player = nil

        hapticTimer?.invalidate()
        hapticTimer = nil

        #if canImport(UIKit)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        #endif

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback so the siren overrides the silent switch and survives backgrounding.
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.sirenWAV())
            player.numberOfLoops = -1   // loop until stop()
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            log.error("Find phone audio failed: \(error.localizedDescription)")
        }
    }

    private func startHaptics() {
        // AudioServicesPlaySystemSound is safe to call from the main thread and works while
        // backgrounded. Pulse it alongside the siren.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        RunLoop.main.add(timer, forMode: .common)
        hapticTimer = timer
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Find phone"
        content.body  = "Your band is sounding an alarm on this iPhone."
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Siren synthesis
    //
    // Builds a 1-second 16-bit mono PCM WAV in memory: two alternating tones (a classic
    // two-tone alarm) so AVAudioPlayer can loop it without needing a bundled sound file.

    private static func sirenWAV() -> Data {
        let sampleRate = 44_100
        let totalSamples = sampleRate            // 1 second
        let halfPeriod = sampleRate / 4          // switch tone every 0.25 s
        let freqA = 880.0
        let freqB = 1_320.0
        let amplitude = 0.85

        var pcm = Data(capacity: totalSamples * 2)
        for n in 0..<totalSamples {
            let freq = ((n / halfPeriod) % 2 == 0) ? freqA : freqB
            let theta = 2.0 * Double.pi * freq * Double(n) / Double(sampleRate)
            let sample = Int16(sin(theta) * amplitude * Double(Int16.max))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wavContainer(pcm: pcm, sampleRate: sampleRate)
    }

    private static func wavContainer(pcm: Data, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendString("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)                       // PCM fmt chunk size
        appendUInt16(1)                        // audio format = PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32(UInt32(dataSize))
        data.append(pcm)
        return data
    }
}
