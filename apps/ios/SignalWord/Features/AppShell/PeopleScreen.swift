import SwiftUI
import Observation

struct PeopleScreen: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Bindable var model: AppShellModel
    let editContact: () -> Void
    @State private var showWithdrawalConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    eyebrow: "YOUR CIRCLE",
                    title: "People",
                    detail: "Choose who receives your alerts. Each person confirms by email."
                )
                if !model.canEditContact {
                    InlineMessage("Your saved contact is unavailable until account loading succeeds. Retry before making changes.", kind: .attention)
                    SecondaryButton(title: model.requiresSessionRecovery ? "Sign in again" : "Retry account loading", symbol: "arrow.clockwise") {
                        Task { if model.requiresSessionRecovery { await model.signInAgain() } else { await model.recover() } }
                    }
                } else if model.hasContactDraft && model.contactStatus != "disabled" {
                    recipientCard
                    if model.contactStatus != "confirmed" {
                        SecondaryButton(title: "Check confirmation", symbol: "arrow.clockwise") {
                            Task { await model.refreshContact() }
                        }
                    }
                    SecondaryButton(
                        title: model.contactStatus == "confirmed" ? "Replace recipient" : "Send confirmation again",
                        symbol: model.contactStatus == "confirmed" ? "person.crop.circle.badge.plus" : "arrow.clockwise",
                        action: editContact
                    )
                    Text("A new confirmation request resets consent and clears earlier TEST evidence, even if you reuse the address. A different person must confirm too.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.contactStatus == "confirmed" {
                        testPanel
                    } else {
                        InlineMessage("TEST and REAL alerts stay unavailable until the person confirms their email.", kind: .attention)
                    }
                    if model.currentAlertPresentation != nil { AlertProgressCard(model: model) }
                    Button("Withdraw this contact", role: .destructive) { showWithdrawalConfirmation = true }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                    .accessibilityIdentifier("people.withdraw")
                } else {
                    SignalWordCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "person.2.wave.2")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(SignalWordColor.action)
                                .accessibilityHidden(true)
                            Text("No trusted person yet").font(.headline)
                            Text("Add someone you trust so SignalWord knows who can receive an alert.")
                                .font(.subheadline)
                                .foregroundStyle(SignalWordColor.secondaryText)
                            PrimaryButton(title: "Add trusted person", symbol: "plus", action: editContact)
                        }
                    }
                }
                ContactNetworkPanel()
                if let message = model.contactMessage { InlineMessage(message, kind: .attention) }
                if let message = model.accountMessage { InlineMessage(message, kind: .attention) }
                Text("TEST messages are labelled TEST. Acknowledgement does not identify the reader or mean help is coming.")
                    .font(.caption)
                    .foregroundStyle(SignalWordColor.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("people.footer")
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, SignalWordSpacing.page)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(SignalWordBackground())
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Withdraw this person’s consent?", isPresented: $showWithdrawalConfirmation, titleVisibility: .visible) {
            Button("Withdraw consent", role: .destructive) { Task { await model.withdrawContact() } }
            Button("Keep contact", role: .cancel) {}
        } message: {
            Text("This stops future alerts and unclaimed sends. Messages already submitted to an email provider cannot be recalled.")
        }
    }

    private var recipientCard: some View {
        SignalWordCard {
            Group {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { recipientAvatar; Spacer(); recipientBadge }
                        recipientIdentity
                    }
                } else {
                    HStack(spacing: 14) {
                        recipientAvatar
                        recipientIdentity
                        Spacer(minLength: 0)
                        recipientBadge
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var recipientAvatar: some View {
        Text(initials)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(SignalWordColor.link)
            .frame(width: 52, height: 52)
            .background(SignalWordColor.action.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private var recipientBadge: some View {
        Image(systemName: model.contactStatus == "confirmed" ? "checkmark.shield.fill" : "envelope.badge")
            .font(.system(size: 22))
            .foregroundStyle(statusColor)
            .accessibilityHidden(true)
    }

    private var recipientIdentity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.contactName.isEmpty ? "Trusted person" : model.contactName)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Label(statusLabel, systemImage: model.contactStatus == "confirmed" ? "checkmark.circle" : "clock")
                .font(.caption.weight(.medium))
                .foregroundStyle(SignalWordColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testPanel: some View {
        SignalWordCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("TEST — NO EMERGENCY")
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(SignalWordColor.action)
                Text("Send a clearly labelled rehearsal message to see what your person receives.")
                    .font(.subheadline)
                    .foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Send TEST alert", symbol: "paperplane") {
                    Task { await model.runRehearsal() }
                }
                .disabled(!model.canStartNewRealAlert)
                if !model.canStartNewRealAlert {
                    Text("Review or resolve the current alert on Home before starting another TEST.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(model.acknowledgedTestCount) of 2 distinct TEST alerts acknowledged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SignalWordColor.primaryText)
                if model.acknowledgedTestEvents.isEmpty {
                    Text("Acknowledged TEST messages will appear here as separate rehearsal evidence.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.acknowledgedTestEvents, id: \.eventID) { event in
                            Button { model.selectAlert(event) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.message.fill")
                                        .foregroundStyle(SignalWordColor.ready)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("TEST alert acknowledged")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(SignalWordColor.primaryText)
                                        Text(event.triggeredAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(SignalWordColor.secondaryText)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(SignalWordColor.mutedText)
                                        .accessibilityHidden(true)
                                }
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("test.evidence.\(event.eventID.uuidString)")
                        }
                    }
                }
                if model.canReportLockedTestForCurrentEvent {
                    SecondaryButton(title: "I used the locked TEST shortcut", symbol: "lock.iphone") {
                        model.recordLockedTestReport()
                    }
                }
                Text("Locked TEST use is a separate user report. SignalWord cannot inspect how iOS triggered an alert.")
                    .font(.caption)
                    .foregroundStyle(SignalWordColor.mutedText)
            }
        }
    }

    private var initials: String {
        model.contactName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased().ifEmpty("SW")
    }

    private var statusLabel: String {
        switch model.contactStatus {
        case "confirmed": "Email confirmed"
        case "pending": "Waiting for email confirmation"
        case "disabled": "Consent withdrawn"
        default: "Confirmation needed"
        }
    }

    private var statusColor: Color {
        model.contactStatus == "confirmed" ? SignalWordColor.ready : SignalWordColor.attention
    }
}

struct ContactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppShellModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeading(
                        eyebrow: "CONSENT BY EMAIL",
                        title: "Trusted person",
                        detail: "They must confirm before any TEST or REAL alert can be sent."
                    )
                    SignalWordCard {
                        VStack(spacing: 0) {
                            LabeledTextField(title: "Your name", placeholder: "Name they’ll recognise", text: $model.displayName, contentType: .name)
                            FieldDivider()
                            LabeledTextField(title: "Their name", placeholder: "Trusted person", text: $model.contactName, contentType: .name)
                            FieldDivider()
                            LabeledTextField(title: "Email address", placeholder: "name@example.com", text: $model.contactEmail, contentType: .emailAddress, keyboard: .emailAddress)
                        }
                    }
                    if let message = model.contactValidationMessage {
                        Text(message).font(.footnote).foregroundStyle(SignalWordColor.secondaryText)
                    }
                if let message = model.contactMessage { InlineMessage(message, kind: .attention) }
                    Text("Sending a new confirmation request invalidates the previous confirmation and clears earlier TEST evidence. The recipient must confirm again.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryButton(title: model.isSavingContact ? "Sending confirmation…" : "Send confirmation", symbol: "arrow.right", isLoading: model.isSavingContact) {
                        Task {
                            await model.saveContact()
                            if model.contactMessage == nil { dismiss() }
                        }
                    }
                    .disabled(model.contactValidationMessage != nil || !model.identityReady || model.isSavingContact)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, SignalWordSpacing.page)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SignalWordBackground())
            .navigationTitle("Trusted person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelContactEdit()
                        dismiss()
                    }
                }
            }
        }
        .tint(SignalWordColor.link)
        .onAppear { model.beginContactEdit() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
