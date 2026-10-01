import SwiftUI

struct SignalWordHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("A phrase. A person. A way to reach them.")
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    step("1", "Choose your person", "Add someone you trust. They must confirm their email before receiving alerts.", "person.crop.circle.badge.checkmark")
                    step("2", "Connect your phrase", "Save a SignalWord action in Apple Shortcuts, then teach iOS Vocal Shortcuts your phrase. SignalWord does not detect danger itself.", "waveform")
                    step("3", "Send a TEST", "Use Send TEST Alert. Ask your person to open the email and acknowledge it. Resolve the test in SignalWord.", "checkmark.message")
                    step("4", "Use REAL when needed", "Trigger Alert sends a REAL alert. Give it a different phrase. Your person sees an alert page and any available location.", "exclamationmark.bubble")
                    DisclosureGroup("Connect Vocal Shortcuts, step by step") {
                        VocalShortcutSetupInstructions(expanded: true).padding(.top, 12)
                    }
                    DisclosureGroup("Location, acknowledgement & check-ins") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Location is optional: allow While Using the App to attach an available recent snapshot. It may be missing or approximate, especially when locked. No continuous location tracking.")
                            Text("Acknowledgement means someone used the recipient link. It does not verify who read it or mean help is coming. Delivery and acknowledgement are separate.")
                            Text("A safety check-in can send a REAL alert if you miss its deadline and grace period. Closing the app does not stop it; check in or cancel and wait for server confirmation.")
                        }.font(.subheadline).foregroundStyle(SignalWordColor.secondaryText).padding(.top, 12)
                    }
                    Text("SignalWord does not contact emergency services or guarantee delivery. Keep another way to get help.")
                        .font(.footnote).foregroundStyle(SignalWordColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("help.limitations")
                }
                .padding(SignalWordSpacing.page)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(SignalWordBackground())
            .navigationTitle("How SignalWord works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("help.done") } }
        }
        .tint(SignalWordColor.link)
        .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func step(_ number: String, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SignalWordColor.link)
                .frame(width: 32, height: 32)
                .background(SignalWordColor.action.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(SignalWordColor.secondaryText)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
