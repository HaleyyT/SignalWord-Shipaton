import SwiftUI
import Observation

struct HomeScreen: View {
    @Environment(\.signalWordAccent) private var accent
    @Environment(\.dynamicTypeSize) private var textSize
    @Bindable var model: AppShellModel
    let openPeople: () -> Void
    let openSettings: () -> Void
    let openRehearsal: () -> Void

    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SignalWordSpacing.section) {
                header
                if let message = model.accountMessage { InlineMessage(message, kind: .attention) }
                if hasCurrentAlert {
                    AlertProgressCard(model: model)
                }
                primaryAction
                if !canStartManualAlert { helpButton }
                if hasCurrentAlert { RecipientProgressPanel(eventID: model.currentAlertEventID) }
                DisclosureGroup("Setup & readiness") { setupSummary.padding(.top, 12) }
                    .accessibilityIdentifier("home.readiness")
                CheckInPanel()
                if !hasCurrentAlert, model.currentAlertPresentation != nil {
                    DisclosureGroup("Last alert details") {
                        AlertProgressCard(model: model).padding(.top, 12)
                        RecipientProgressPanel(eventID: model.currentAlertEventID)
                    }
                }
                recentActivity
                safetyNote
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, SignalWordSpacing.page)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(SignalWordBackground())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.recover() }
        .sheet(isPresented: $showHelp) { SignalWordHelpSheet().environment(\.dynamicTypeSize, textSize) }
        .accessibilityIdentifier("home.screen")
    }

    private var helpButton: some View {
        Button { showHelp = true } label: {
            Label("How SignalWord works", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("home.help")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("SignalWord")
                } icon: {
                    Image("SignalWordMark").resizable().scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.link)
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            Text(hasCurrentAlert ? "Your alert" : canStartManualAlert ? "Ready to send" : "Finish your setup")
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if canStartManualAlert || hasCurrentAlert {
                Label("Primary contact: \(model.contactName.ifEmpty("your trusted person"))", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Send a private alert to someone you trust. Confirm your person to get started.")
                    .font(.subheadline).foregroundStyle(SignalWordColor.secondaryText)
            }
            if canStartManualAlert {
                Text(model.shortcutConfigured ? "Voice setup reported. Rehearse before relying on it." : "Manual alerts are available. Connect your phrase for voice activation.")
                    .font(.caption).foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasCurrentAlert: Bool {
        model.currentAlertPresentation != nil && !model.canStartNewRealAlert
    }

    private var canStartManualAlert: Bool {
        model.canTriggerManually && model.canStartNewRealAlert
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.requiresSessionRecovery {
            PrimaryButton(title: "Sign in again", symbol: "person.crop.circle") { Task { await model.signInAgain() } }
        } else if isActiveAlert {
            HoldConfirmControl(action: .resolveAlert, isEnabled: true, identifier: "alert.resolve") {
                await model.requestResolution()
            }
        } else if model.canStartNewRealAlert && model.canTriggerManually {
            PrimaryButton(title: "Send TEST alert", symbol: "checkmark.message") {
                Task { await model.runRehearsal() }
            }
            .accessibilityIdentifier("home.test")
            Text("Practice only · sends a labelled TEST email")
                .font(.caption).foregroundStyle(SignalWordColor.secondaryText)
            helpButton
            HoldConfirmControl(action: .sendRealAlert, isEnabled: true, identifier: "alert.trigger") {
                await model.triggerRealAlert()
            }
        } else if model.currentAlertPresentation != nil {
            Text("Check the status above before sending another alert.")
                .font(.caption)
                .foregroundStyle(SignalWordColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if !model.identityReady {
            PrimaryButton(title: "Retry account loading", symbol: "arrow.clockwise") {
                Task { await model.recover() }
            }
            .accessibilityIdentifier("home.prepare")
        } else {
            PrimaryButton(title: "Confirm your trusted person", symbol: "person.badge.plus", action: openPeople)
        }

    }

    private var isActiveAlert: Bool {
        model.canResolveCurrentAlert
    }

    private var setupSummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            SignalWordCard {
                VStack(spacing: 0) {
                    CapabilityRow(
                        title: model.manualAlertReadiness.title,
                        detail: model.manualAlertReadiness.detail,
                        isReady: model.manualAlertReadiness.isReady,
                        symbol: model.manualAlertReadiness.isReady ? "checkmark.circle.fill" : "circle.dashed"
                    ) {
                        if model.manualAlertReadiness.isReady { openPeople() }
                        else if model.identityReady { openPeople() }
                        else { Task { await model.recover() } }
                    }
                    Divider().overlay(SignalWordColor.separator).padding(.leading, 44)
                    CapabilityRow(
                        title: model.recipientConsentReadiness.title,
                        detail: model.recipientConsentReadiness.detail,
                        isReady: model.recipientConsentReadiness.isReady,
                        symbol: model.recipientConsentReadiness.isReady ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark"
                    ) { openPeople() }
                    Divider().overlay(SignalWordColor.separator).padding(.leading, 44)
                    CapabilityRow(
                        title: model.rehearsalReadiness.title,
                        detail: model.rehearsalReadiness.detail,
                        isReady: model.rehearsalReadiness.isReady,
                        symbol: model.rehearsalReadiness.isReady ? "checkmark.circle.fill" : "checkmark.message"
                    ) { openRehearsal() }
                    Divider().overlay(SignalWordColor.separator).padding(.leading, 44)
                    CapabilityRow(
                        title: model.lockedTestReadiness.title,
                        detail: model.lockedTestReadiness.detail,
                        isReady: model.lockedTestReadiness.isReady,
                        symbol: "lock.iphone"
                    ) { openSettings() }
                    Divider().overlay(SignalWordColor.separator).padding(.leading, 44)
                    CapabilityRow(
                        title: model.shortcutReadiness.title,
                        detail: model.shortcutReadiness.detail,
                        isReady: model.shortcutReadiness.isReady,
                        symbol: "waveform"
                    ) { openSettings() }
                    Divider().overlay(SignalWordColor.separator).padding(.leading, 44)
                    CapabilityRow(
                        title: "Location",
                        detail: model.locationState.summary,
                        isReady: false,
                        symbol: "location"
                    ) { openSettings() }
                }
            }
            Text("Location and rehearsal do not block a manual alert. Shortcut setup and locked-test use are self-reported.")
                .font(.caption)
                .foregroundStyle(SignalWordColor.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activity")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Refresh") { Task { await model.recover() } }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .disabled(model.isRecovering)
            }
            if model.availableAlerts.isEmpty {
                Button(action: openRehearsal) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.message")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(SignalWordColor.action)
                            .frame(width: 44, height: 44)
                            .background(SignalWordColor.action.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No recent alerts").font(.subheadline.weight(.semibold)).foregroundStyle(SignalWordColor.primaryText)
                            Text("Run a safe TEST before you need it.")
                                .font(.caption)
                                .foregroundStyle(SignalWordColor.secondaryText)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(SignalWordColor.mutedText)
                    }
                    .padding(14)
                    .background(SignalWordColor.surface, in: RoundedRectangle(cornerRadius: SignalWordRadius.row, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.availableAlerts.prefix(3), id: \.eventID) { alert in
                        Button {
                            model.selectAlert(alert)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: alertKind(alert) == .test ? "checkmark.message" : alertKind(alert) == .real ? "waveform.path" : "questionmark.circle")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(alertKind(alert) == .test ? SignalWordColor.action : alertKind(alert) == .real ? SignalWordColor.attention : SignalWordColor.secondaryText)
                                    .frame(width: 38, height: 38)
                                    .background(SignalWordColor.canvas, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(alertKind(alert).map { $0 == .test ? "TEST alert" : "REAL alert" } ?? "Alert kind unavailable")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(SignalWordColor.primaryText)
                                    Text(activitySubtitle(alert))
                                        .font(.caption)
                                        .foregroundStyle(SignalWordColor.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(SignalWordColor.mutedText)
                            }
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.\(alert.kind).\(alert.eventID.uuidString)")
                        if alert.eventID != model.availableAlerts.prefix(3).last?.eventID {
                            Divider().overlay(SignalWordColor.separator).padding(.leading, 50)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(SignalWordColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func activitySubtitle(_ alert: AlertStatusProjection) -> String {
        let eventState = AlertPresentationModel(
            eventID: alert.eventID,
            kind: alert.kind,
            eventState: alert.state,
            initialDelivery: alert.delivery,
            resolutionDelivery: alert.resolutionDelivery,
            isAcknowledged: alert.acknowledgedAt != nil
        )
        let lifecycle: String
        switch eventState.lifecycle {
        case .pending: lifecycle = "Pending"
        case .active: lifecycle = "Active"
        case .resolved: lifecycle = "Resolved"
        case .expired: lifecycle = "Expired"
        case .accepted: lifecycle = "Accepted by SignalWord"
        case .savedLocally: lifecycle = "Saved on this iPhone"
        case .submitting: lifecycle = "Sending"
        case .delayedConfirmation: lifecycle = "Confirmation needed"
        case .rejected: lifecycle = "Not accepted"
        case .unknown: lifecycle = "Status unavailable"
        }
        return "\(lifecycle) · \(eventState.initialDelivery.title)"
    }

    private func alertKind(_ alert: AlertStatusProjection) -> AlertKind? {
        AlertKind(rawValue: alert.kind.lowercased())
    }

    private var safetyNote: some View {
        Text("SignalWord alerts your confirmed contacts. It does not call emergency services or guarantee delivery.")
            .font(.caption)
            .foregroundStyle(SignalWordColor.mutedText)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("home.footer")
    }
}
