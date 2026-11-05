import AppIntents

// MARK: - BandShortcuts
//
// Exposes the app's intents to Siri and the Shortcuts app with predefined phrases. Each phrase
// must reference \(.applicationName) so the system can disambiguate which app to invoke.

struct BandShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncBandIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Sync my band in \(.applicationName)",
                "Sync the band with \(.applicationName)",
                "Sync my Mi Band in \(.applicationName)",
                "Refresh my band in \(.applicationName)",
                "Sync band data in \(.applicationName)",
                "Pull Mi Band data in \(.applicationName)",
                "Sync band with Apple Health in \(.applicationName)",
            ],
            shortTitle: "Sync band",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: GetSleepStateIntent(),
            phrases: [
                "I am sleeping in \(.applicationName)",
                "Am I asleep in \(.applicationName)",
                "Check if I am asleep in \(.applicationName)",
                "Check my sleep in \(.applicationName)",
            ],
            shortTitle: "Am I asleep",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: CheckBandBatteryIntent(),
            phrases: [
                "Check band battery in \(.applicationName)",
                "See the band battery in \(.applicationName)",
                "How much battery does my band have in \(.applicationName)",
                "Check Mi Band battery in \(.applicationName)",
            ],
            shortTitle: "Check battery",
            systemImageName: "battery.25"
        )
    }
}
