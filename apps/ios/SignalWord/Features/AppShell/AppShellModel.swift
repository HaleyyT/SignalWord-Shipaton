import Foundation
import Observation

enum OnboardingStage: Int, CaseIterable, Identifiable {
    case understand, contact, rehearse

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .understand: "Understand"
        case .contact: "Trusted contact"
        case .rehearse: "Rehearse"
        }
    }
}

enum LocationPermissionState: Equatable, Sendable {
    case notRequested, allowedApproximate, allowedPrecise, denied

    var summary: String {
        switch self {
        case .notRequested: "Not requested. Alerts still work without location."
        case .allowedApproximate: "Approximate location may be attached when available."
        case .allowedPrecise: "A trigger-time location snapshot may be attached."
        case .denied: "Unavailable. The alert can still be created."
        }
    }
}

enum AlertDisplayState: Equatable {
    case idle
    case submitting(kind: AlertKind)
    case waitingForConnection(kind: AlertKind?)
    case confirmationRequired(kind: AlertKind?)
    case accepted(eventID: UUID, kind: AlertKind?, reused: Bool)
    case resolved(eventID: UUID, kind: AlertKind?)
    case expired(eventID: UUID, kind: AlertKind?)
    case rejected(kind: AlertKind?)
}

@MainActor
@Observable
final class AppShellModel {
    typealias Trigger = @Sendable (AlertKind, TriggerMethod) async -> TriggerOutcome
    struct LifecycleActions: Sendable {
        let prepare: @Sendable (String?) async throws -> Void
        let profile: @Sendable (String?) async throws -> String
        let recover: @Sendable (Bool) async throws -> AppRecovery
        let saveContact: @Sendable (String, String) async throws -> TrustedContactProjection
        let getContact: @Sendable () async throws -> TrustedContactProjection?
        let disableContact: @Sendable (UUID) async throws -> Bool
        let getAlertStatus: @Sendable (UUID) async throws -> AlertStatusProjection
        let authenticateResolution: @Sendable () async -> Bool
        let resolve: @Sendable (UUID) async throws -> ResolvedAlertProjection
        let locationAuthorization: @Sendable () async -> DeviceLocationAuthorization
        let requestLocationAccess: @Sendable () async -> DeviceLocationAuthorization
        let deleteAccount: @Sendable () async throws -> Void

        var identityID: @Sendable () async throws -> String? = { nil }
        var beginReauthentication: @Sendable () async throws -> Void = { throw SessionError.configuration }
        var requestRegistrationCode: @Sendable (String, String) async throws -> Void = { _, _ in throw SessionError.configuration }
        var requestInvitedCode: @Sendable (String, String) async throws -> Void = { _, _ in throw SessionError.configuration }
        var verifyInvitedCode: @Sendable (String, String) async throws -> Void = { _, _ in throw SessionError.configuration }

        var signOut: @Sendable () async throws -> Void = { throw SessionError.configuration }

        var signInWithPassword: @Sendable (String, String, String) async throws -> Void = { _, _, _ in throw SessionError.configuration }

        static let unconfigured = LifecycleActions(
            prepare: { _ in throw SessionError.configuration },
            profile: { _ in throw SessionError.configuration },
            recover: { _ in throw SessionError.configuration },
            saveContact: { _, _ in throw SessionError.configuration },
            getContact: { throw SessionError.configuration },
            disableContact: { _ in throw SessionError.configuration },
            getAlertStatus: { _ in throw SessionError.configuration },
            authenticateResolution: { false },
            resolve: { _ in throw SessionError.configuration },
            locationAuthorization: { .notRequested },
            requestLocationAccess: { .notRequested },
            deleteAccount: { throw SessionError.configuration }
        )
    }

    private let preferences: UserDefaults
    var displayName = ""
    var stage: OnboardingStage = .understand
    var hasEnteredDashboard = false { didSet { preferences.set(hasEnteredDashboard, forKey: "onboardingComplete") } }
    var contactName = ""
    var contactEmail = ""
    private(set) var hasContactDraft = false
    private(set) var isEditingContactDraft = false
    private var savedContactName = ""
    private(set) var contactStatus = "not configured"
    private var contactID: UUID?
    private(set) var needsIdentityVerification = false
    private(set) var identityReady = false
    enum AccountLoadState { case unknown, loading, available, unavailable }
    private(set) var accountLoadState: AccountLoadState = .unknown
    private(set) var requiresSessionRecovery = false
    private var isPreparing = false
    private var readinessIdentityID: String?
    private struct SavedReadiness: Codable {
        let contactID: String?; let startedAt: Date; let lockedReports: [String]; let shortcutConfigured: Bool
    }
    private func restoreReadiness(for identity: String?) {
        guard let identity, readinessIdentityID != identity else { return }
        readinessIdentityID = identity
        if preferences.string(forKey: "readinessIdentityID") == identity { return }
        guard let data = preferences.data(forKey: "accountReadiness." + identity),
              let saved = try? JSONDecoder().decode(SavedReadiness.self, from: data) else { return }
        preferences.set(saved.contactID, forKey: "rehearsalContactID")
        rehearsalStartedAt = saved.startedAt; lockedTestReports = Set(saved.lockedReports)
        shortcutConfigured = saved.shortcutConfigured
    }
    private func saveReadiness() {
        guard let identity = readinessIdentityID else { return }
        preferences.set(identity, forKey: "readinessIdentityID")
        let value = SavedReadiness(contactID: preferences.string(forKey: "rehearsalContactID"),
            startedAt: rehearsalStartedAt, lockedReports: Array(lockedTestReports), shortcutConfigured: shortcutConfigured)
        if let data = try? JSONEncoder().encode(value) { preferences.set(data, forKey: "accountReadiness." + identity) }
    }
    var isCreatingAccount = false
    var canEditContact: Bool { identityReady && accountLoadState == .available }
    private(set) var isSavingContact = false
    private(set) var shortcutConfigured = false { didSet { preferences.set(shortcutConfigured, forKey: "shortcutConfigured") } }
    private var lockedTestReports: Set<String> = []
    private var currentAcknowledgedTestID: UUID?
    private var rehearsalStartedAt: Date
    private(set) var acknowledgedMessage: String?
    private(set) var isRecovering = false
    private(set) var hasDelayedCommands = false
    private(set) var delayedAlertKind: AlertKind?
    private(set) var availableAlerts: [AlertStatusProjection] = []
    private(set) var selectedAlertStatus: AlertStatusProjection?
    private(set) var canReportLockedTestForCurrentEvent = false
    private(set) var alertState: AlertDisplayState = .idle
    private(set) var deliveryStatus: String?
    private(set) var resolveMessage: String?
    private(set) var recoveryMessage: String?
    private(set) var accountMessage: String?
    private(set) var contactMessage: String?
    var locationState: LocationPermissionState = .notRequested
    let backendConfigured: Bool

    private let trigger: Trigger
    private let lifecycle: LifecycleActions

    init(backendConfigured: Bool, trigger: @escaping Trigger, lifecycle: LifecycleActions = .unconfigured, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.backendConfigured = backendConfigured
        self.trigger = trigger
        self.lifecycle = lifecycle
        hasEnteredDashboard = preferences.bool(forKey: "onboardingComplete")
        shortcutConfigured = preferences.bool(forKey: "shortcutConfigured")
        lockedTestReports = Set(preferences.stringArray(forKey: "lockedTestReports") ?? preferences.stringArray(forKey: "verifiedRehearsals") ?? [])
        rehearsalStartedAt = preferences.object(forKey: "rehearsalStartedAt") as? Date ?? .now
    }

    #if !SWIFT_PACKAGE
    static func live() -> AppShellModel {
        AppShellModel(
            backendConfigured: AppCompositionRoot.isConfigured,
            trigger: AppCompositionRoot.makeTrigger(),
            lifecycle: AppCompositionRoot.makeLifecycleActions()
        )
    }

    #endif

    var contactValidationMessage: String? {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.count > 80 {
            return "Enter your name so your contact knows who sent the alert."
        }
        if contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the name your alert recipient will recognise."
        }
        if !Self.looksLikeEmail(contactEmail) {
            return "Enter a valid email address."
        }
        return nil
    }

    var acknowledgedTestEvents: [AlertStatusProjection] {
        availableAlerts.filter { alert in
            alert.kind.lowercased() == "test"
                && alert.acknowledgedAt != nil
                && alert.triggeredAt >= rehearsalStartedAt
        }
    }

    var acknowledgedTestEventIDs: Set<UUID> { Set(acknowledgedTestEvents.map(\.eventID)) }

    var acknowledgedTestCount: Int {
        ReadinessPresentationModel.distinctAcknowledgedTestCount(eventIDs: Array(acknowledgedTestEventIDs))
    }
    var lockedTestReportCount: Int { lockedTestReports.count }
    var canTriggerManually: Bool { identityReady && contactStatus == "confirmed" }
    var manualAlertReadiness: ReadinessPresentationModel {
        .manualAlert(identityReady: identityReady, recipientConfirmed: contactStatus == "confirmed")
    }
    var recipientConsentReadiness: ReadinessPresentationModel {
        .recipientConsent(isConfirmed: contactStatus == "confirmed")
    }
    var rehearsalReadiness: ReadinessPresentationModel {
        .acknowledgedTests(count: acknowledgedTestCount)
    }
    var lockedTestReadiness: ReadinessPresentationModel {
        .lockedTestReport(count: lockedTestReportCount)
    }
    var shortcutReadiness: ReadinessPresentationModel {
        .shortcutReport(isConfigured: shortcutConfigured)
    }
    var locationReadiness: ReadinessPresentationModel {
        .optionalLocation(detail: locationState.summary)
    }
    var canResolveCurrentAlert: Bool { currentAlertPresentation?.lifecycle == .active }
    var canStartNewRealAlert: Bool {
        guard let lifecycle = currentAlertPresentation?.lifecycle else { return true }
        return [.resolved, .expired, .rejected].contains(lifecycle)
    }

    var currentAlertPresentation: AlertPresentationModel? {
        switch alertState {
        case .idle: return nil
        case .submitting(let kind):
            return .init(kind: kind, lifecycle: .submitting)
        case .waitingForConnection(let kind):
            return .init(kind: kind, lifecycle: .savedLocally)
        case .confirmationRequired(let kind):
            return .init(kind: kind, lifecycle: .delayedConfirmation)
        case .rejected(let kind):
            return .init(kind: kind, lifecycle: .rejected)
        case .accepted(let eventID, let kind, _):
            if let status = selectedAlertStatus, status.eventID == eventID { return presentation(for: status) }
            return .init(eventID: eventID, kind: kind, lifecycle: .accepted)
        case .resolved(let eventID, let kind):
            if let status = selectedAlertStatus, status.eventID == eventID {
                return presentation(for: status, lifecycleOverride: .resolved)
            }
            return .init(eventID: eventID, kind: kind, lifecycle: .resolved)
        case .expired(let eventID, let kind):
            if let status = selectedAlertStatus, status.eventID == eventID { return presentation(for: status) }
            return .init(eventID: eventID, kind: kind, lifecycle: .expired)
        }
    }

    var currentAlertEventID: UUID? {
        switch alertState {
        case .accepted(let id, _, _), .resolved(let id, _), .expired(let id, _): id
        default: selectedAlertStatus?.eventID
        }
    }

    var currentAlertKind: AlertKind? {
        if let presentation = currentAlertPresentation { return presentation.kind }
        return nil
    }

    private func presentation(
        for status: AlertStatusProjection,
        lifecycleOverride: AlertLifecycleDisplayState? = nil
    ) -> AlertPresentationModel {
        AlertPresentationModel(
            eventID: status.eventID,
            kind: status.kind,
            eventState: lifecycleOverride.map { _ in "resolved" } ?? status.state,
            initialDelivery: status.delivery,
            resolutionDelivery: status.resolutionDelivery,
            isAcknowledged: status.acknowledgedAt != nil
        )
    }

    func advanceFromUnderstanding() {
        stage = .contact
        beginContactEdit()
    }

    var invitedEmail = ""
    var invitedCode = ""
    private(set) var invitedCodeRequested = false
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    var canSignOut: Bool { !isSigningOut && !isSigningIn && !isRecovering && !isSavingContact && !isSubmitting }

    func changeInvitedEmail() {
        guard !isSigningIn else { return }
        invitedCodeRequested = false
        invitedCode = ""
        accountMessage = nil
    }

    private var deletionBlocksSignIn: Bool {
        preferences.bool(forKey: "serverDeletionConfirmed") || preferences.string(forKey: "deletionReceiptToken") != nil
    }

    func requestInvitedCode(captchaToken: String) async {
        guard !isSigningIn, !deletionBlocksSignIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            invitedEmail = try InvitedSignIn.normalizedEmail(invitedEmail)
            if isCreatingAccount { try await lifecycle.requestRegistrationCode(invitedEmail, captchaToken) }
            else { try await lifecycle.requestInvitedCode(invitedEmail, captchaToken) }
            invitedCodeRequested = true
            accountMessage = "Check your inbox for an email verification code. If it does not arrive, check the address and spam folder."
        } catch {
            accountMessage = (error as? SessionError)?.message ?? "Could not request a code. Check your email and connection, then complete verification again."
        }
    }

    func verifyInvitedCode() async {
        guard !isSigningIn, !deletionBlocksSignIn else { return }
        isSigningIn = true
        defer { isSigningIn = false; invitedCode = "" }
        do {
            try await lifecycle.verifyInvitedCode(invitedEmail, invitedCode)
            invitedEmail = ""
            invitedCodeRequested = false
            await prepare()
        } catch {
            accountMessage = "Code not accepted. It may be incorrect, expired or already used. Try again or request a new code."
        }
    }

    func signInWithPassword(password: String, captchaToken: String) async {
        guard !isSigningIn, !deletionBlocksSignIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await lifecycle.signInWithPassword(invitedEmail, password, captchaToken)
            invitedEmail = ""
            invitedCode = ""
            invitedCodeRequested = false
            await prepare()
        } catch {
            accountMessage = (error as? SessionError)?.message ?? "Sign-in could not be completed. Check your connection and retry."
        }
    }

    func signInAgain() async {
        guard !isSigningIn, !isPreparing else { return }
        do {
            try await lifecycle.beginReauthentication()
            identityReady = false
            needsIdentityVerification = true
            requiresSessionRecovery = false
            isCreatingAccount = false
            accountMessage = SessionError.sessionExpired.message
        } catch { accountMessage = "Could not prepare account recovery. Unlock your device and retry. Your account data is kept." }
    }

    func prepare(captchaToken: String? = nil) async {
        guard !isSigningOut, !isPreparing, !requiresSessionRecovery else { return }
        isPreparing = true
        defer { isPreparing = false }
        // Preserve the result of an explicit sign-in attempt until the next attempt.
        guard !needsIdentityVerification || isSigningIn || deletionBlocksSignIn else { return }
        apply(await lifecycle.locationAuthorization())
        if preferences.bool(forKey: "serverDeletionConfirmed") ||
            preferences.string(forKey: "deletionReceiptToken") != nil {
            identityReady = false
            await deleteAccount()
            return
        }
        guard backendConfigured else { return }
        let needsAccountLoad = !identityReady || accountLoadState != .available
        do {
            // Keep a confirmed snapshot visible during background reads. Replacing
            // it with loading content moves controls and interrupts open dialogs.
            if needsAccountLoad { accountLoadState = .loading }
            try await lifecycle.prepare(captchaToken)
            let profileName = displayName.isEmpty ? try await lifecycle.profile(nil) : displayName
            let contact = try await lifecycle.getContact()
            let identity = try await lifecycle.identityID()
            guard !Task.isCancelled, !isSigningOut else { return }
            displayName = profileName
            restoreReadiness(for: identity)
            applyContact(contact)
            saveReadiness()
            accountLoadState = .available
            identityReady = true
            // A returning configured account does not need to reinvite its recipient.
            if contact != nil && stage == .understand { hasEnteredDashboard = true }
            // Clear preparation failures after a confirmed retry, while retaining
            // feedback from explicit account actions during a healthy refresh.
            if needsAccountLoad { accountMessage = nil }
            needsIdentityVerification = false
        } catch is CancellationError {
            // Scene changes cancel foreground recovery; cancellation is not an auth failure.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch SessionError.verificationRequired {
            identityReady = false
            accountLoadState = .unknown
            needsIdentityVerification = true
            accountMessage = "Sign in to your existing account, or choose Create account if you are new."
        } catch SessionError.sessionExpired {
            identityReady = false
            accountLoadState = .unavailable
            requiresSessionRecovery = true
            accountMessage = SessionError.sessionExpired.message
        } catch is KeychainError {
            identityReady = false
            accountLoadState = .unavailable
            accountMessage = "Your saved identity is unavailable. Unlock the device and retry. Your account has not been replaced."
        } catch {
            guard !Task.isCancelled else { return }
            identityReady = false
            accountLoadState = .unavailable
            accountMessage = "Your account data could not be loaded. Check the connection and retry. Your saved contact has not been replaced."
        }
    }

    func recover(allowDelayed: Bool = false) async {
        guard !isRecovering, !isSigningOut else { return }
        isRecovering = true
        defer { isRecovering = false }
        recoveryMessage = nil
        await prepare()
        guard identityReady else { return }
        do {
            let recovery = try await lifecycle.recover(allowDelayed)
            availableAlerts = recovery.alerts.sorted { $0.triggeredAt > $1.triggeredAt }
            hasDelayedCommands = recovery.needsConfirmation
            delayedAlertKind = recovery.needsConfirmation ? recovery.pendingKind : nil
            if recovery.needsConfirmation {
                selectedAlertStatus = nil
                alertState = .confirmationRequired(kind: recovery.pendingKind)
            } else if recovery.pending {
                selectedAlertStatus = nil
                alertState = .waitingForConnection(kind: recovery.pendingKind)
            } else if let active = availableAlerts.first(where: { $0.kind.lowercased() == "real" && ["active", "pending"].contains($0.state.lowercased()) })
                ?? availableAlerts.first(where: { ["active", "pending"].contains($0.state.lowercased()) }) {
                selectAlert(active)
            } else if let current = availableAlerts.first(where: { status in
                switch alertState {
                case .accepted(let id, _, _), .resolved(let id, _), .expired(let id, _): return id == status.eventID
                default: return false
                }
            }) { selectAlert(current) }
            else if let latest = availableAlerts.first {
                selectAlert(latest)
            } else {
                selectedAlertStatus = nil
                alertState = .idle
            }
            await refreshContact()
        } catch SessionError.sessionExpired {
            identityReady = false
            accountLoadState = .unavailable
            requiresSessionRecovery = true
            accountMessage = SessionError.sessionExpired.message
        } catch {
            recoveryMessage = "Recovery could not finish. Saved commands remain on this device. Retry when connected."
        }
    }

    func selectAlert(_ status: AlertStatusProjection) {
        selectedAlertStatus = status
        let kind = AlertKind(rawValue: status.kind.lowercased())
        switch status.state.lowercased() {
        case "resolved": alertState = .resolved(eventID: status.eventID, kind: kind)
        case "expired": alertState = .expired(eventID: status.eventID, kind: kind)
        default: alertState = .accepted(eventID: status.eventID, kind: kind, reused: true)
        }
        applyStatus(status)
    }

    func editContact() {
        stage = .contact
        contactMessage = nil
        beginContactEdit()
    }

    func beginContactEdit() {
        if !isEditingContactDraft { savedContactName = contactName }
        isEditingContactDraft = true
    }

    func cancelContactEdit() {
        contactName = savedContactName
        contactEmail = ""
        isEditingContactDraft = false
        contactMessage = nil
    }

    func openRehearsal() { stage = .rehearse }

    func requestLocationAccess() async {
        apply(await lifecycle.requestLocationAccess())
    }

    func saveContact() async {
        guard contactValidationMessage == nil, identityReady, !isSavingContact else { return }
        isSavingContact = true
        contactMessage = nil
        defer { isSavingContact = false }
        do {
            displayName = try await lifecycle.profile(displayName)
            let contact = try await lifecycle.saveContact(
                contactName.trimmingCharacters(in: .whitespacesAndNewlines),
                contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
            // The service create-or-replace operation always resets consent and
            // invitation-scoped TEST evidence, including when the address is reused.
            clearRehearsalEvidence(startingAt: .now)
            isEditingContactDraft = false
            apply(contact)
            stage = .rehearse
            accountMessage = nil
            contactMessage = nil
        } catch {
            do {
                applyContact(try await lifecycle.getContact())
                contactMessage = "We couldn't confirm the new invitation outcome. Your entries remain here; check the recipient status before retrying."
            } catch {
                contactStatus = "unknown"
                contactMessage = "We couldn't confirm the invitation or consent status. Alerts stay unavailable until you refresh. Your entries remain here."
            }
        }
    }

    func checkInvitationStatus() async {
        do {
            let contact = try await lifecycle.getContact()
            applyContact(contact)
            if let contact {
                contactMessage = "Saved contact: \(contact.name). Server status: \(contact.status). Checking status does not send another invitation."
            } else {
                contactMessage = "No contact invitation is saved for this account. Your entries are still here."
            }
        } catch {
            contactMessage = "Invitation status could not be checked. Keep your entries and try checking again when connected; do not assume an email was sent."
        }
    }

    func refreshContact() async {
        do {
            applyContact(try await lifecycle.getContact())
            contactMessage = nil
        } catch {
            contactMessage = "We couldn't refresh confirmation status. Your entries are still here; try again."
        }
    }

    func withdrawContact() async {
        guard let contactID else { return }
        do {
            guard try await lifecycle.disableContact(contactID) else { throw UserAPIError.invalidResponse }
            contactStatus = "disabled"
            clearRehearsalEvidence(startingAt: .now)
            accountMessage = "Contact consent is withdrawn. Unclaimed and future sends are stopped; messages already submitted to the provider cannot be retracted."
        } catch {
            accountMessage = "Could not confirm contact withdrawal. Check the connection and retry."
        }
    }

    func setShortcutConfigured(_ value: Bool) { shortcutConfigured = value }

    func enterDashboard() { hasEnteredDashboard = true }

    func runRehearsal() async {
        guard identityReady, contactStatus == "confirmed", canStartNewRealAlert else { return }
        await submit(kind: .test, method: .manual)
    }

    func recordLockedTestReport() {
        guard canReportLockedTestForCurrentEvent else { return }
        guard let id = currentAcknowledgedTestID else { return }
        lockedTestReports.insert(id.uuidString)
        preferences.set(Array(lockedTestReports), forKey: "lockedTestReports")
        canReportLockedTestForCurrentEvent = false
    }

    func triggerRealAlert() async {
        guard canTriggerManually, canStartNewRealAlert else { return }
        await submit(kind: .real, method: .manual)
    }

    func requestResolution() async {
        guard case .accepted(let eventID, let kind, _) = alertState else { return }
        guard canResolveCurrentAlert else {
            resolveMessage = "SignalWord has not confirmed that this alert is active. Refresh its status before resolving."
            return
        }
        guard await lifecycle.authenticateResolution() else {
            resolveMessage = "The alert remains active because device authentication was not completed."
            return
        }
        do {
            _ = try await lifecycle.resolve(eventID)
            alertState = .resolved(eventID: eventID, kind: kind)
            resolveMessage = nil
            recoveryMessage = nil
            await refreshActiveAlertStatus()
        } catch {
            resolveMessage = "Resolution was not accepted. This alert remains active; check the connection and try again."
        }
    }

    func refreshActiveAlertStatus() async {
        guard let eventID = currentAlertEventID else { return }
        do {
            let status = try await lifecycle.getAlertStatus(eventID)
            applyStatus(status)
            applyAlertState(status)
            resolveMessage = nil
        } catch {
            resolveMessage = "Current delivery status could not be refreshed."
        }
    }

    func signOut(statusUpdateInProgress: Bool = false) async {
        guard !statusUpdateInProgress else {
            accountMessage = "A status update is still running. Wait for it to finish, then try signing out again."
            return
        }
        guard canSignOut, !deletionBlocksSignIn else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await lifecycle.signOut()
            saveReadiness()
            clearAccountViewState()
            needsIdentityVerification = true
            accountMessage = "Signed out on this iPhone. Your account and server data have not been deleted."
        } catch {
            accountMessage = "Could not sign out safely. Connect to the internet, resolve active alerts, end any check-in timer, and refresh pending changes before trying again. Your account has not been deleted."
        }
    }

    private func clearAccountViewState() {
        identityReady = false
        accountLoadState = .unknown
        readinessIdentityID = nil
        preferences.removeObject(forKey: "readinessIdentityID")
        requiresSessionRecovery = false
        isCreatingAccount = false
        hasDelayedCommands = false
        delayedAlertKind = nil
        availableAlerts = []
        resolveMessage = nil
        shortcutConfigured = false
        lockedTestReports = []
        preferences.removeObject(forKey: "lockedTestReports")
        preferences.removeObject(forKey: "verifiedRehearsals")
        preferences.removeObject(forKey: "rehearsalContactID")
        preferences.removeObject(forKey: "rehearsalStartedAt")
        rehearsalStartedAt = .now
        selectedAlertStatus = nil
        deliveryStatus = nil
        acknowledgedMessage = nil
        canReportLockedTestForCurrentEvent = false
        currentAcknowledgedTestID = nil
        contactName = ""
        contactEmail = ""
        contactID = nil
        displayName = ""
        hasContactDraft = false
        contactStatus = "not configured"
        contactMessage = nil
        alertState = .idle
        hasEnteredDashboard = false
        stage = .understand
        savedContactName = ""
        isEditingContactDraft = false
        invitedEmail = ""
        invitedCode = ""
        invitedCodeRequested = false
        recoveryMessage = nil
    }

    func deleteAccount() async {
        do {
            try await lifecycle.deleteAccount()
            if let identity = readinessIdentityID { preferences.removeObject(forKey: "accountReadiness." + identity) }
            clearAccountViewState()
            accountMessage = "SignalWord data was deleted from the server and this device."
        } catch {
            if preferences.string(forKey: "deletionReceiptToken") != nil { identityReady = false }
            accountMessage = "Deletion did not finish or could not be confirmed. Retry to complete server and device cleanup."
        }
    }

    private func submit(kind: AlertKind, method: TriggerMethod) async {
        guard !isSubmitting else { return }
        if kind == .test {
            guard identityReady, contactStatus == "confirmed" else {
                alertState = .rejected(kind: kind)
                return
            }
        }
        canReportLockedTestForCurrentEvent = false
        currentAcknowledgedTestID = nil
        acknowledgedMessage = nil
        deliveryStatus = nil
        selectedAlertStatus = nil
        alertState = .submitting(kind: kind)
        await finishSubmit(kind: kind, method: method)
    }

    private func finishSubmit(kind: AlertKind, method: TriggerMethod) async {
        let outcome = await trigger(kind, method)
        switch outcome {
        case .created(let eventID):
            alertState = .accepted(eventID: eventID, kind: kind, reused: false)

        case .reused(let eventID):
            alertState = .accepted(eventID: eventID, kind: kind, reused: true)

        case .confirmationRequired: alertState = .confirmationRequired(kind: kind)
        case .queuedOffline, .failedRetryable: alertState = .waitingForConnection(kind: kind)
        case .rejected: alertState = .rejected(kind: kind)
        }
        if case .accepted = alertState { await refreshActiveAlertStatus() }
    }

    private var isSubmitting: Bool {
        if case .submitting = alertState { return true }
        return false
    }

    private func applyAlertState(_ status: AlertStatusProjection) {
        let kind = AlertKind(rawValue: status.kind.lowercased())
        switch status.state.lowercased() {
        case "resolved": alertState = .resolved(eventID: status.eventID, kind: kind)
        case "expired": alertState = .expired(eventID: status.eventID, kind: kind)
        default: alertState = .accepted(eventID: status.eventID, kind: kind, reused: false)
        }
    }

    private func applyStatus(_ status: AlertStatusProjection) {
        selectedAlertStatus = status
        if let index = availableAlerts.firstIndex(where: { $0.eventID == status.eventID }) {
            availableAlerts[index] = status
        } else {
            availableAlerts.append(status)
        }
        availableAlerts.sort { $0.triggeredAt > $1.triggeredAt }
        deliveryStatus = status.delivery
        acknowledgedMessage = status.acknowledgedAt == nil ? "No recipient acknowledgement yet." : "Acknowledged through the recipient link. This does not confirm help is coming."
        let isCurrentAcknowledgedTest = status.kind.lowercased() == "test"
            && status.acknowledgedAt != nil
            && status.triggeredAt >= rehearsalStartedAt
        currentAcknowledgedTestID = isCurrentAcknowledgedTest ? status.eventID : nil
        canReportLockedTestForCurrentEvent = isCurrentAcknowledgedTest && !lockedTestReports.contains(status.eventID.uuidString)
    }

    private func clearRehearsalEvidence(startingAt: Date = .now) {
        lockedTestReports = []
        currentAcknowledgedTestID = nil
        canReportLockedTestForCurrentEvent = false
        rehearsalStartedAt = startingAt
        preferences.set(startingAt, forKey: "rehearsalStartedAt")
        preferences.removeObject(forKey: "verifiedRehearsals")
        preferences.removeObject(forKey: "lockedTestReports")
    }

    private func applyContact(_ contact: TrustedContactProjection?) {
        guard let contact else {
            // An authoritative absence must revoke stale local readiness.
            contactID = nil
            clearRehearsalEvidence(startingAt: .now)
            preferences.removeObject(forKey: "rehearsalContactID")
            hasContactDraft = false
            contactStatus = "not configured"
            // Leave unsaved text alone: foreground polling may run while the
            // user is entering a new recipient. Readiness comes from status/ID.
            return
        }
        apply(contact)
    }

    private func apply(_ contact: TrustedContactProjection) {
        // Readiness evidence belongs to one recipient; it cannot transfer on replacement.
        if preferences.string(forKey: "rehearsalContactID") != contact.contactID.uuidString || contact.status != "confirmed" {
            clearRehearsalEvidence(startingAt: .now)
        }
        preferences.set(contact.contactID.uuidString, forKey: "rehearsalContactID")
        contactID = contact.contactID
        if !isEditingContactDraft {
            contactName = contact.name
            contactEmail = ""
        }
        savedContactName = contact.name
        hasContactDraft = true
        contactStatus = contact.status
    }

    private func apply(_ authorization: DeviceLocationAuthorization) {
        switch authorization {
        case .notRequested: locationState = .notRequested
        case .approximate: locationState = .allowedApproximate
        case .precise: locationState = .allowedPrecise
        case .denied: locationState = .denied
        }
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[0].count > 0 && pieces[1].contains(".")
    }
}

struct AppRecovery: Sendable {
    let alerts: [AlertStatusProjection]
    let needsConfirmation: Bool
    let pending: Bool
    let pendingKind: AlertKind?

    init(alerts: [AlertStatusProjection], needsConfirmation: Bool, pending: Bool, pendingKind: AlertKind? = nil) {
        self.alerts = alerts
        self.needsConfirmation = needsConfirmation
        self.pending = pending
        self.pendingKind = pendingKind
    }
}
