import SwiftUI
import Observation

enum HoldConfirmAction {
    case sendRealAlert
    case resolveAlert

    var label: String {
        switch self {
        case .sendRealAlert: "REAL alert"
        case .resolveAlert: "Resolve alert"
        }
    }

    var buttonTitle: String {
        switch self {
        case .sendRealAlert: "Hold to send a REAL alert"
        case .resolveAlert: "Hold to resolve this alert"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .sendRealAlert: "Send a REAL alert?"
        case .resolveAlert: "Resolve this alert?"
        }
    }

    var confirmationDetail: String {
        switch self {
        case .sendRealAlert: "This sends an alert to your confirmed trusted person. It does not contact emergency services."
        case .resolveAlert: "SignalWord will mark this alert resolved after device owner authentication."
        }
    }

    var accessibilityHint: String {
        switch self {
        case .sendRealAlert: "Notifies your confirmed trusted person and does not contact emergency services. Use Review and confirm, or hold for one and a half seconds."
        case .resolveAlert: "Marks this alert resolved after device owner authentication. Use Review and confirm, or hold for one and a half seconds."
        }
    }

    var confirmationButton: String {
        switch self {
        case .sendRealAlert: "Send REAL alert"
        case .resolveAlert: "Resolve alert"
        }
    }
}

struct HoldConfirmControl: View {
    @Environment(\.scenePhase) private var scenePhase
    let action: HoldConfirmAction
    let isEnabled: Bool
    var identifier: String? = nil
    let perform: @Sendable () async -> Void

    @State private var isHolding = false
    @State private var holdStartedAt: Date?
    @State private var showConfirmation = false
    @State private var isRunning = false
    private let holdDuration: TimeInterval = 1.5

    var body: some View {
        VStack(spacing: 8) {
            holdSurface
            Button(action: reviewAction) {
                Text("Review and confirm")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
                .disabled(!isEnabled || isRunning)
                .accessibilityIdentifier((identifier ?? "alert.hold-confirm") + ".review")
        }
        .alert(action.confirmationTitle, isPresented: $showConfirmation) {
            Button(action.confirmationButton, role: action == .sendRealAlert ? .destructive : nil) {
                runAction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(action.confirmationDetail)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { showConfirmation = false; isHolding = false }
        }
    }

    private var holdStatus: String {
        if isRunning { return "Please wait…" }
        if isHolding { return "Keep holding to confirm…" }
        return action.buttonTitle
    }

    private var holdLabel: some View {
        HStack(spacing: 10) {
            if isRunning {
                ProgressView().tint(.white)
            } else {
                Image(systemName: action == .sendRealAlert ? "waveform.path" : "checkmark.circle")
                    .font(.system(size: 20, weight: .semibold))
            }
            Text(holdStatus)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    private var holdProgress: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: !isHolding)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(holdStartedAt ?? timeline.date)
            let progress: Double = isHolding ? min(1, max(0, elapsed / holdDuration)) : 0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.20))
                    Capsule().fill(.white).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 220)
    }

    private var holdContents: some View {
        VStack(spacing: 9) {
            holdLabel
            holdProgress
        }
    }

    private var holdAppearance: some View {
        holdContents
        .foregroundStyle(action == .sendRealAlert ? SignalWordColor.attention : SignalWordColor.primaryText)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, 14)
        .background(SignalWordColor.secondarySurface, in: RoundedRectangle(cornerRadius: SignalWordRadius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: SignalWordRadius.control).stroke(action == .sendRealAlert ? SignalWordColor.attention.opacity(0.6) : SignalWordColor.separator, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: SignalWordRadius.control, style: .continuous))
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var holdInteraction: some View {
        holdAppearance.overlay {
            ScrollCompatibleHoldSurface(
                duration: holdDuration,
                enabled: isEnabled && !isRunning && scenePhase == .active,
                pressing: { isHolding = $0 },
                confirmed: runAction
            )
            .accessibilityHidden(true)
        }
        .onChange(of: isHolding) { _, holding in
            holdStartedAt = holding ? .now : nil
        }
    }

    private var holdSurface: some View {
        // Expose the whole hold surface as one actionable accessibility element.
        holdInteraction.accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier ?? "alert.hold-confirm")
        .accessibilityLabel(action.buttonTitle)
        .accessibilityValue(isRunning ? "In progress" : "Ready")
        .accessibilityHint(action.accessibilityHint + " Releasing early cancels the hold.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { reviewAction() }
    }

    private func reviewAction() {
        guard isEnabled, !isRunning, scenePhase == .active else { return }
        showConfirmation = true
    }

    private func runAction() {
        guard isEnabled, !isRunning, scenePhase == .active else { return }
        isHolding = false
        isRunning = true
        Task { @MainActor in
            await perform()
            isRunning = false
        }
    }
}

extension HoldConfirmAction: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.sendRealAlert, .sendRealAlert), (.resolveAlert, .resolveAlert): true
        default: false
        }
    }
}

struct DeliverySummaryRow: View {
    let title: String
    let state: AlertDeliveryDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(SignalWordColor.secondaryText)
            Text(state.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state == .failed ? SignalWordColor.critical : SignalWordColor.primaryText)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(SignalWordColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AlertProgressCard: View {
    @Bindable var model: AppShellModel
    @State private var showDelayedConfirmation = false

    private var presentation: AlertPresentationModel? { model.currentAlertPresentation }

    var body: some View {
        if let presentation {
            SignalWordCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: presentation.kind == .test ? "checkmark.message" : presentation.kind == .real ? "waveform.path" : "questionmark.circle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(presentation.kind == .test ? SignalWordColor.action : presentation.kind == .real ? SignalWordColor.attention : SignalWordColor.secondaryText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(presentation.headline)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(presentation.lifecycleDetail)
                                .font(.subheadline)
                                .foregroundStyle(SignalWordColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if model.isRecovering { ProgressView().controlSize(.small) }
                    }
                    if presentation.showsInitialDelivery {
                        Label(presentation.initialDelivery.title, systemImage: "envelope")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(presentation.initialDelivery == .failed ? SignalWordColor.critical : SignalWordColor.secondaryText)
                    }
                    if let resolution = presentation.resolutionDelivery {
                        Text("Resolution email: \(resolution.title)").font(.subheadline)
                    }
                    DisclosureGroup("Delivery details") {
                        VStack(alignment: .leading, spacing: 12) {
                            if presentation.showsInitialDelivery {
                                DeliverySummaryRow(title: "Initial alert email", state: presentation.initialDelivery)
                            }
                            if let resolution = presentation.resolutionDelivery {
                                DeliverySummaryRow(title: "Resolution email", state: resolution)
                            }
                        }.padding(.top, 10)
                    }
                    if let message = model.resolveMessage { InlineMessage(message, kind: .attention) }
                    if let message = model.recoveryMessage { InlineMessage(message, kind: .attention) }
                    VStack(alignment: .leading, spacing: 8) {
                        Button(model.isRecovering ? "Checking…" : model.currentAlertEventID == nil ? "Check saved command" : "Refresh status") {
                            Task {
                                if model.currentAlertEventID == nil { await model.recover() }
                                else { await model.refreshActiveAlertStatus() }
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(model.isRecovering || presentation.lifecycle == .submitting)
                        .accessibilityHint(model.currentAlertEventID == nil ? "Reconciles this iPhone’s saved command with SignalWord" : "Checks SignalWord state and both delivery reports")
                        if model.hasDelayedCommands {
                            let delayedKind = model.delayedAlertKind
                            Button("Review delayed \(delayedKind == .test ? "TEST" : delayedKind == .real ? "REAL" : "alert")", role: .destructive) {
                                showDelayedConfirmation = true
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    if presentation.isAcknowledged {
                        Label("Acknowledged through the recipient link. This does not confirm identity or mean help is coming.", systemImage: "checkmark.message")
                            .font(.caption)
                            .foregroundStyle(SignalWordColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No recipient acknowledgement recorded yet.")
                            .font(.caption)
                            .foregroundStyle(SignalWordColor.secondaryText)
                    }
                }
            }
            .confirmationDialog("Send this delayed command now?", isPresented: $showDelayedConfirmation, titleVisibility: .visible) {
                Button("Confirm and send", role: .destructive) { Task { await model.recover(allowDelayed: true) } }
                Button("Keep waiting", role: .cancel) {}
            } message: {
                let kind = model.delayedAlertKind
                Text("SignalWord found an older saved \(kind == .test ? "TEST" : kind == .real ? "REAL" : "alert") command. Review before sending it.")
            }
            .accessibilityIdentifier("alert.progress")
        }
    }
}
