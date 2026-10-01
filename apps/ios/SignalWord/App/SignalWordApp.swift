import SwiftUI
import AppIntents

@main
struct SignalWordApp: App {
    @State private var model: AppShellModel = {
        #if DEBUG && targetEnvironment(simulator)
        if let testModel = UITestComposition.makeModel() { return testModel }
        #endif
        return AppShellModel.live()
    }()

    init() {
        CrashReporting.start()
        SignalWordAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            SignalWordRootView(model: model)
                .tint(SignalWordColor.action)
                .preferredColorScheme(.dark)
                #if DEBUG && targetEnvironment(simulator)
                .modifier(UITestAccessibilityConfiguration())
                #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Exercise the same SwiftUI accessibility sizing without changing device settings.
private struct UITestAccessibilityConfiguration: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-largest-text") {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else { content }
    }
}
#endif
