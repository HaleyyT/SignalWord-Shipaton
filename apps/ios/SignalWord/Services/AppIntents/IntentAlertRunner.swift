import Foundation

/// The intent's authority stops at triggering one preconfigured alert. It does
/// not return contact details, links, location, or delivery information.
enum IntentAlertRunner {
    static func triggerAlert() async -> TriggerOutcome {
        await AppCompositionRoot.trigger(kind: .real, method: .vocalShortcut)
    }
}
