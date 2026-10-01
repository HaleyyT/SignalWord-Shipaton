#if canImport(AppIntents)
import AppIntents

@available(iOS 18.0, *)
struct SignalWordAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .red

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TestAlertIntent(), phrases: ["Send a test with \(.applicationName)"],
                    shortTitle: "Send TEST Alert", systemImageName: "checkmark.shield")
        AppShortcut(
            intent: TriggerAlertIntent(),
            phrases: [
                "Trigger alert in \(.applicationName)",
                "Send my alert with \(.applicationName)",
            ],
            shortTitle: "Trigger Alert",
            systemImageName: "exclamationmark.shield"
        )
    }
}
#endif
