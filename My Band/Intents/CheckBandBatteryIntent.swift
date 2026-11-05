import AppIntents
import Foundation
import OSLog
import UserNotifications

// MARK: - CheckBandBatteryIntent
//
// "Warn me if the band battery is low" — built for a Shortcuts Personal Automation
// ("when I connect my iPhone to the charger"): if the band is below the threshold, it fires
// a local notification reminding you to put it on the charger; above the threshold, the shortcut
// finishes silently (no dialog, no notification) so it doesn't become noise every time the
// automation runs.
//
// The battery level is only known while the link is up. The preferred source is the standard
// GATT Battery Level characteristic (0x2A19) — the same one iOS reads for the Batteries widget,
// so the shortcut and the widget show the same number; without it, the Xiaomi protocol's
// CMD_BATTERY is used. The intent runs a best-effort sync first (which connects if needed) and
// then requests a fresh reading, in case the link had been open for a while and the in-memory
// value is stale.

struct CheckBandBatteryIntent: AppIntent {

    static var title: LocalizedStringResource = "Check band battery"
    static var description = IntentDescription(
        "Checks the Mi Band 10 battery and notifies only if it is below the given percentage."
    )

    static var openAppWhenRun = false

    @Parameter(
        title: "Notify below",
        description: "Minimum percentage. Above it, the shortcut produces no output.",
        default: 30,
        inclusiveRange: (1, 100)
    )
    var threshold: Int

    /// Upper bound on waiting for the battery readings after the sync (2A19 + CMD_BATTERY). It is
    /// not a sleep: the intent proceeds as soon as both responses arrive.
    private static let batteryRefreshWait: Duration = .seconds(3)

    private static let notificationID = "com.myband.lowbattery"

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BatteryIntent"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int?> {
        let band = AppServices.shared.bandManager
        let hadLiveLink = band.connectionState.isConnected

        // The link must survive the sync: the battery request below depends on it. With the default
        // (`disconnectWhenDone: nil`) the sync tore down the connection it had opened itself before
        // CMD_BATTERY, so the intent answered with the stale in-memory level (or nil) and the link
        // dropped in the middle of the sync's final ACKs — which the band then re-offered on the
        // next connection. We only release the radio at the end, and only if we were the ones who
        // opened it.
        defer { if !hadLiveLink { band.disconnect(userInitiated: false) } }

        // Best-effort: if the band is out of range, we still answer with the last known level
        // instead of failing the shortcut (and therefore the whole automation).
        do {
            _ = try await BackgroundSyncManager.shared.syncNow(disconnectWhenDone: false)
        } catch {
            Self.log.error("Battery intent sync failed: \(error.localizedDescription)")
        }

        await band.refreshBattery(timeout: Self.batteryRefreshWait)

        guard let level = band.batteryLevel else { return .result(value: nil) }

        // Already on the charger: the reminder would serve no purpose.
        if level < threshold && !band.batteryCharging {
            await notifyLowBattery(level: level)
        }
        return .result(value: level)
    }

    private func notifyLowBattery(level: Int) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = "Band battery low"
        content.body  = "Your band is at \(level)%. Put it on the charger."
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        try? await center.add(request)
    }
}
