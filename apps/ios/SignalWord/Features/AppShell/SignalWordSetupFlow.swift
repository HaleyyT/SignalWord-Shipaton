import SwiftUI
import Observation

struct SignalWordSetupFlow: View {
    @Bindable var model: AppShellModel
    @State private var showVerification = false
    @State private var usePassword = false
    @State private var showSignOut = false
    @State private var password = ""
    @State private var verificationPassword = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    progress
                    if let message = model.accountMessage { InlineMessage(message, kind: .attention) }
                    if model.needsIdentityVerification {
                        if SignalWordConfiguration.verificationURL != nil {
                            Text(model.isCreatingAccount ? "Create account" : "Sign in").font(.title2.weight(.semibold))
                            TextField("Email address", text: $model.invitedEmail)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(model.isSigningIn || model.invitedCodeRequested)
                                .accessibilityIdentifier("onboarding.invitedEmail")
                            if usePassword && !model.isCreatingAccount {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                                    .accessibilityIdentifier("onboarding.password")
                                Text("Use the password for your existing account.")
                                    .font(.footnote)
                            } else if model.invitedCodeRequested {
                                SecureField("Email sign-in code", text: $model.invitedCode)
                                    .textContentType(.oneTimeCode)
                                    .keyboardType(.numberPad)
                                    .accessibilityIdentifier("onboarding.invitedCode")
                                Button("Change email address") { model.changeInvitedEmail() }
                                    .disabled(model.isSigningIn)
                                Button("Sign in") { Task { await model.verifyInvitedCode() } }
                                    .disabled(model.isSigningIn || model.invitedCode.isEmpty)
                                    .accessibilityIdentifier("onboarding.signIn")
                            }
                            Button(usePassword ? "Verify and sign in" : (model.invitedCodeRequested ? "Request another code" : "Verify and request code")) { verificationPassword = password; showVerification = true }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("onboarding.verifyIdentity")
                                .disabled(model.isSigningIn || model.invitedEmail.isEmpty || (usePassword && !model.isCreatingAccount && password.isEmpty))
                            if !model.isCreatingAccount {
                            Link("Forgot password", destination: URL(string: "https://www.signalword.app/auth/recovery")!)
                            Button(usePassword ? "Use an email code" : "Use an existing password") {
                                model.changeInvitedEmail()
                                password = ""
                                usePassword.toggle()
                            }
                            .disabled(model.isSigningIn)
                            }
                            if !model.requiresSessionRecovery && !model.hasEnteredDashboard {
                                Button(model.isCreatingAccount ? "Already have an account? Sign in" : "New to SignalWord? Create account") {
                                    model.changeInvitedEmail(); password = ""; usePassword = false
                                    model.isCreatingAccount.toggle()
                                }.disabled(model.isSigningIn)
                            }
                        } else {
                            Text("Account verification is not configured in this build. Contact support before continuing.")
                                .font(.footnote)
                        }
                    }
                    if !model.needsIdentityVerification {
                        if model.requiresSessionRecovery {
                            Button("Sign in again") { Task { await model.signInAgain() } }
                        } else if model.accountLoadState == .unavailable {
                            Button("Retry account loading") { Task { await model.recover() } }
                        } else {
                            switch model.stage {
                            case .understand: introduction
                            case .contact: contactSetup
                            case .rehearse: rehearsalSetup
                            }
                        }
                    }
                    if model.identityReady {
                        Button("Sign out") { showSignOut = true }
                            .disabled(!model.canSignOut)
                            .accessibilityIdentifier("account.signOut")
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, SignalWordSpacing.page)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("onboarding.scroll")
            // Each setup step starts at its heading, including at accessibility text sizes.
            .id(model.stage)
            .background(SignalWordBackground())
            .navigationTitle(model.stage.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { password = ""; verificationPassword = ""; showVerification = false }
        }
        .onDisappear { password = ""; if !showVerification { verificationPassword = "" } }
        .confirmationDialog("Sign out of SignalWord?", isPresented: $showSignOut, titleVisibility: .visible) {
            Button("Sign out") { Task { await model.signOut() } }
                .accessibilityIdentifier("account.confirmSignOut")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account and server data are kept. Finish active alerts and check-in timers first. Vocal Shortcuts cannot send alerts until you sign in again.")
        }
        .sheet(isPresented: $showVerification) {
            NavigationStack {
                if let url = SignalWordConfiguration.verificationURL {
                    SignupVerificationView(url: url) { token in
                        showVerification = false
                        if usePassword && !model.isCreatingAccount {
                            let submittedPassword = verificationPassword
                            verificationPassword = ""
                            password = ""
                            Task { await model.signInWithPassword(password: submittedPassword, captchaToken: token) }
                        } else {
                            Task { await model.requestInvitedCode(captchaToken: token) }
                        }
                    }
                    .navigationTitle("Verify account access")
                    .toolbar { Button("Cancel") { verificationPassword = ""; showVerification = false } }
                }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.stage != .understand {
                    Button {
                        switch model.stage {
                        case .understand: break
                        case .contact: model.stage = .understand
                        case .rehearse: model.stage = .contact
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                }
                Text("Set up your signal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SignalWordColor.secondaryText)
                Spacer()
                Text("\(model.stage.rawValue + 1) / \(OnboardingStage.allCases.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(SignalWordColor.secondaryText)
            }
            HStack(spacing: 6) {
                ForEach(OnboardingStage.allCases) { stage in
                    Capsule()
                        .fill(stage.rawValue <= model.stage.rawValue ? SignalWordColor.action : SignalWordColor.track)
                        .frame(height: 4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Setup step \(model.stage.rawValue + 1) of \(OnboardingStage.allCases.count)")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            SignalOrb(state: .ready, size: 72)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text("A quiet way to reach someone you trust.")
                    .font(.title.weight(.semibold))
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Send a private alert to your confirmed contacts with a phrase you configure in iOS, or a manual action.")
                    .font(.body)
                    .foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SignalWordCard {
                VStack(alignment: .leading, spacing: 14) {
                    PrivacyLine(symbol: "waveform.slash", title: "No ambient audio is stored", detail: "Vocal Shortcuts is configured and managed by iOS.")
                    Divider().overlay(SignalWordColor.separator)
                    PrivacyLine(symbol: "person.crop.circle.badge.checkmark", title: "Your confirmed contacts", detail: "SignalWord does not contact police or emergency services.")
                }
            }
            PrimaryButton(title: "Set up SignalWord", symbol: "arrow.right") {
                model.advanceFromUnderstanding()
            }
        }
    }

    private var contactSetup: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(
                eyebrow: "YOUR PEOPLE",
                title: "Choose one trusted contact.",
                detail: "They confirm by email before TEST or REAL alerts can be sent."
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
            if let message = model.contactMessage {
                InlineMessage(message, kind: .attention)
                SecondaryButton(title: "Check invitation status", symbol: "arrow.clockwise") {
                    Task { await model.checkInvitationStatus() }
                }.disabled(model.isSavingContact)
            }
            if !model.identityReady {
                InlineMessage("Prepare this iPhone before sending an invitation. Your entries stay here while the device connects.", kind: .attention)
                SecondaryButton(title: "Prepare this iPhone", symbol: "arrow.clockwise") { Task { await model.recover() } }
            }
            Text("Every new confirmation request resets consent and clears earlier TEST evidence, including when you reuse this address. A different person must confirm too.")
                .font(.footnote)
                .foregroundStyle(SignalWordColor.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: model.isSavingContact ? "Sending confirmation…" : "Send confirmation", symbol: "arrow.right", isLoading: model.isSavingContact) {
                Task { await model.saveContact() }
            }
            .disabled(model.contactValidationMessage != nil || !model.identityReady || model.isSavingContact)
        }
    }

    private var rehearsalSetup: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(
                eyebrow: "MAKE IT FAMILIAR",
                title: "Try it before you need it.",
                detail: "A TEST is clearly labelled and does not imply an emergency. Rehearsal evidence is useful, but it does not block a manual REAL alert."
            )
            SignalWordCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Set up your Vocal Shortcuts", systemImage: "waveform")
                        .font(.headline)
                    Text("First save SignalWord actions in Apple’s Shortcuts app, then assign your phrases in iOS Vocal Shortcuts. SignalWord does not detect danger automatically.")
                        .font(.subheadline)
                        .foregroundStyle(SignalWordColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    VocalShortcutSetupInstructions()
                    Toggle("I added both Vocal Shortcuts", isOn: Binding(
                        get: { model.shortcutConfigured },
                        set: { model.setShortcutConfigured($0) }
                    ))
                    .tint(SignalWordColor.action)
                    Text("This is your report. SignalWord cannot inspect iOS Shortcut settings.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.mutedText)
                }
            }
            SignalWordCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Location is optional", systemImage: "location.circle")
                        .font(.headline)
                    Text(model.locationState.summary)
                        .font(.subheadline)
                        .foregroundStyle(SignalWordColor.secondaryText)
                    if model.locationState == .notRequested {
                        Button("Allow location while using SignalWord") { Task { await model.requestLocationAccess() } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            if model.contactStatus != "confirmed" {
                InlineMessage("Waiting for your trusted person to confirm their email. Alerts cannot be sent until consent is confirmed.", kind: .attention)
                SecondaryButton(title: "Check confirmation", symbol: "arrow.clockwise") { Task { await model.refreshContact() } }
            } else {
                SignalWordCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TEST — NO EMERGENCY")
                            .font(.caption.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(SignalWordColor.action)
                        Text("Send a clearly labelled rehearsal email to your confirmed person.")
                            .font(.subheadline)
                            .foregroundStyle(SignalWordColor.secondaryText)
                        PrimaryButton(title: "Send a safe TEST alert", symbol: "paperplane") {
                            Task { await model.runRehearsal() }
                        }
                        .disabled(!model.canStartNewRealAlert)
                    }
                }
            }
            if let presentation = model.currentAlertPresentation, presentation.kind == .test {
                Text("\(model.acknowledgedTestCount) of 2 distinct TEST alerts acknowledged")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SignalWordColor.primaryText)
                AlertProgressCard(model: model)
                if model.canReportLockedTestForCurrentEvent {
                    SecondaryButton(title: "I used the locked TEST shortcut", symbol: "lock.iphone") {
                        model.recordLockedTestReport()
                    }
                    Text("User-reported. SignalWord cannot verify how this TEST was triggered.")
                        .font(.caption)
                        .foregroundStyle(SignalWordColor.mutedText)
                }
            }
            PrimaryButton(title: "Continue to home", symbol: "arrow.right") {
                model.enterDashboard()
            }
            .padding(.top, 2)
        }
    }
}
