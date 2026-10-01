#if canImport(AppIntents)
import AppIntents

@available(iOS 18.0, *)
struct TriggerAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Trigger Alert"
    static let description = IntentDescription("Send an alert to your confirmed trusted contact.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        _ = await IntentAlertRunner.triggerAlert()
        // Intentionally silent: locked execution must not expose private state.
        return .result()
    }
}
@available(iOS 18.0, *)
struct TestAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Send TEST Alert"
    static let description = IntentDescription("Rehearse with your confirmed contact. TEST — NO EMERGENCY.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    func perform() async throws -> some IntentResult {
        _ = await AppCompositionRoot.trigger(kind: .test, method: .vocalShortcut)
        return .result()
    }
}
#endif
