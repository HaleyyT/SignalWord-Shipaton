import SwiftUI
import AppIntents
import Observation
import SupporterKit

struct SettingsScreen: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Bindable var model: AppShellModel
    let supporter: SupporterModel
    let openPeople: () -> Void
    let openDeleteConfirmation: () -> Void
    var openSignOutConfirmation: () -> Void = {}

    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "YOUR SETUP", title: "Settings", detail: "Your signal, privacy and account.")

                settingsGroup(title: "Help") {
                    SettingsRow(symbol: "info.circle", title: "How SignalWord works", detail: "Setup, TEST and REAL alerts", tint: SignalWordColor.link) { showHelp = true }
                        .accessibilityIdentifier("settings.help")
                }
                settingsGroup(title: "Signal") {
                    PrivacyLine(
                        symbol: "waveform",
                        title: "Vocal Shortcuts",
                        detail: "iOS recognises the phrase you teach it and runs your chosen action. SignalWord does not detect danger or configure your phrase automatically."
                    )
                    Divider().overlay(SignalWordColor.separator)
                    VocalShortcutSetupInstructions()
                    Divider().overlay(SignalWordColor.separator)
                    Toggle(isOn: Binding(get: { model.shortcutConfigured }, set: { model.setShortcutConfigured($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("I added both shortcuts").font(.subheadline.weight(.medium))
                            Text("Self-reported. SignalWord cannot inspect iOS settings.")
                                .font(.caption).foregroundStyle(SignalWordColor.secondaryText)
                        }
                    }
                    .tint(SignalWordColor.action)
                    Divider().overlay(SignalWordColor.separator)
                    CapabilityRow(
                        title: model.rehearsalReadiness.title,
                        detail: model.rehearsalReadiness.detail,
                        isReady: model.rehearsalReadiness.isReady,
                        symbol: "checkmark.message"
                    ) { openPeople() }
                    Divider().overlay(SignalWordColor.separator)
                    CapabilityRow(
                        title: model.lockedTestReadiness.title,
                        detail: model.lockedTestReadiness.detail,
                        isReady: model.lockedTestReadiness.isReady,
                        symbol: "lock.iphone"
                    ) { openPeople() }
                }

                settingsGroup(title: "Privacy and location") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Location is optional", systemImage: "location")
                            .font(.subheadline.weight(.semibold))
                        Text(model.locationState.summary)
                            .font(.caption)
                            .foregroundStyle(SignalWordColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.locationState == .notRequested {
                            Button("Allow location while using SignalWord") { Task { await model.requestLocationAccess() } }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    }
                    DisclosureGroup("Location permissions & limitations") {
                    Text("To change permission: iPhone Settings › Privacy & Security › Location Services › SignalWord › While Using the App. For a location rehearsal, reopen SignalWord and send a new TEST after resolving any active alert. Location is best effort; it may be unavailable, especially during locked or background use.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(SignalWordColor.separator)
                    PrivacyLine(symbol: "lock.fill", title: "Private by default", detail: "A recent point-in-time location may be shared with an alert. SignalWord does not track movement.")
                    Divider().overlay(SignalWordColor.separator)
                    PrivacyLine(symbol: "waveform.slash", title: "No continuous recording", detail: "Your chosen phrase is managed by iOS Vocal Shortcuts.")
                }

                settingsGroup(title: "Make it yours") {
                    NavigationLink {
                        SupporterScreen(model: supporter)
                    } label: {
                        Label("Supporter appearance", systemImage: "heart.circle")
                            .frame(minHeight: 48)
                    }.accessibilityIdentifier("supporter.open")
                    Text("Optional appearance purchase. All safety features stay free.")
                        .font(.caption).foregroundStyle(SignalWordColor.secondaryText)
                }

                settingsGroup(title: "Account") {
                    SettingsRow(
                        symbol: "arrow.clockwise",
                        title: model.isRecovering ? "Checking…" : "Refresh alert status",
                        detail: "Reconcile saved commands and delivery reports",
                        tint: SignalWordColor.action
                    ) { Task { await model.recover() } }
                    .disabled(model.isRecovering)
                    Divider().overlay(SignalWordColor.separator)
                    SettingsRow(symbol: "rectangle.portrait.and.arrow.right", title: "Sign out",
                        detail: "Keep your account and server data", tint: SignalWordColor.link,
                        action: openSignOutConfirmation)
                        // Opening the dialog is read-only. The confirmed operation
                        // still waits for recovery and retains its safety guards.
                        .disabled(model.isSigningIn || model.isSigningOut)
                        .accessibilityIdentifier("account.signOut")
                    Divider().overlay(SignalWordColor.separator)
                    Button(action: openDeleteConfirmation) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(SignalWordColor.critical)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Delete account and data")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SignalWordColor.critical)
                                Text("Remove your device identity and server data")
                                    .font(.caption)
                                    .foregroundStyle(SignalWordColor.secondaryText)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SignalWordColor.mutedText)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account.delete")
                }

                if let message = model.accountMessage { InlineMessage(message, kind: .attention) }
                Text("SignalWord notifies your confirmed contacts. It does not contact emergency services or guarantee delivery.")
                    .font(.caption)
                    .foregroundStyle(SignalWordColor.mutedText)
                    .accessibilityIdentifier("settings.footer")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, SignalWordSpacing.page)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(SignalWordBackground())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showHelp) { SignalWordHelpSheet().environment(\.dynamicTypeSize, textSize) }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(SignalWordColor.secondaryText)
            SignalWordCard { VStack(spacing: 13, content: content) }
        }
    }
}

/// Shared by onboarding and Settings; these steps never run an alert themselves.
struct VocalShortcutSetupInstructions: View {
    var expanded = false
    var body: some View {
        if expanded { instructions } else {
            DisclosureGroup("How to connect your phrase") { instructions }
                .accessibilityIdentifier("shortcut.setup.instructions")
        }
    }
    private var instructions: some View {
            VStack(alignment: .leading, spacing: 14) {
                ShortcutsLink()
                    .accessibilityIdentifier("shortcut.openAppleShortcuts")
                Text("Open the SignalWord actions above. Save the TEST action as a shortcut before choosing it in Vocal Shortcuts. Opening this list does not send an alert.")
                Text("1. Open Apple's Shortcuts app (Phím tắt). Tap +, search actions for SignalWord, and add Send TEST Alert. Name this shortcut SignalWord TEST and save it.")
                Text("2. Open iPhone Settings › Accessibility › Vocal Shortcuts (Phím tắt giọng nói). Tap Add Action and choose your saved SignalWord TEST shortcut. If you see a blue Done checkmark, finish editing first.")
                Text("3. Choose a practice phrase and repeat it as iOS requests. Keep Vocal Shortcuts enabled. Saying that phrase runs the TEST action; no new recording is needed each time.")
                Text("4. With your contact confirmed, resolve any existing alert, then try the TEST phrase. Check the TEST email, recipient acknowledgement and resolution in SignalWord. Repeat with the phone locked before relying on that setup.")
                Text("5. For a REAL alert, create another shortcut using SignalWord's Trigger Alert action. Name it SignalWord REAL and assign a different private phrase in Vocal Shortcuts. Trigger Alert sends a REAL alert; do not run it for rehearsal.")
                Text("If SignalWord is missing, open SignalWord once, then return to Shortcuts and search its actions again. Choose the SignalWord action, not an unrelated sample shortcut or a Siri request. If it is still missing, stop and report it.")
                Text("The setup switch is only your report. It does not connect or verify either shortcut. SignalWord does not continuously record audio, infer danger, or contact emergency services. Voice recognition, network access and delivery can fail.")
            }
            .font(.subheadline)
            .foregroundStyle(SignalWordColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}
