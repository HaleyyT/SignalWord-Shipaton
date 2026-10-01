import Foundation

enum AlertLifecycleDisplayState: Equatable {
    case savedLocally
    case submitting
    case delayedConfirmation
    case accepted
    case pending
    case active
    case resolved
    case expired
    case rejected
    case unknown
}

enum LocationFreshnessState: Equatable {
    case live
    case recent
    case stale
    case unavailable
}

struct LocationFreshnessPresentationModel: Equatable {
    let state: LocationFreshnessState
    let ageDescription: String

    init(capturedAt: Date?, now: Date = .now) {
        guard let capturedAt else {
            state = .unavailable
            ageDescription = "No location snapshot"
            return
        }
        let age = max(0, now.timeIntervalSince(capturedAt))
        switch age {
        case ..<30:
            state = .live
            ageDescription = "Captured just now"
        case ..<120:
            state = .recent
            ageDescription = "Captured about a minute ago"
        default:
            state = .stale
            ageDescription = "Captured more than two minutes ago"
        }
    }
}

enum AlertDeliveryDisplayState: Equatable {
    case queued
    case providerAccepted
    case delivered
    case failed
    case unknown

    init(_ rawValue: String?) {
        switch rawValue?.lowercased() {
        case "queued": self = .queued
        case "sent": self = .providerAccepted
        case "delivered": self = .delivered
        case "failed": self = .failed
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .queued: "Queued to send"
        case .providerAccepted: "Provider accepted"
        case .delivered: "Provider reported delivered"
        case .failed: "Delivery failed"
        case .unknown: "Delivery status unavailable"
        }
    }

    var detail: String {
        switch self {
        case .queued: "The email is waiting to send. Delivery is not confirmed."
        case .providerAccepted: "The email provider accepted the request. Recipient delivery is not confirmed yet."
        case .delivered: "The provider reported delivery to the recipient’s mail system. This does not confirm a person read it."
        case .failed: "The provider reported that delivery failed. Check the connection and refresh the status."
        case .unknown: "SignalWord could not confirm the provider status. Refresh to check again."
        }
    }
}

/// A single display projection keeps event kind, server lifecycle, and each
/// delivery channel distinct. Unknown wire values never become success copy.
struct AlertPresentationModel: Equatable {
    let eventID: UUID?
    let kind: AlertKind?
    let lifecycle: AlertLifecycleDisplayState
    let initialDelivery: AlertDeliveryDisplayState
    let resolutionDelivery: AlertDeliveryDisplayState?
    let isAcknowledged: Bool
    let locationFreshness: LocationFreshnessPresentationModel?

    var showsInitialDelivery: Bool {
        ![.savedLocally, .submitting, .delayedConfirmation, .rejected].contains(lifecycle)
    }

    init(
        eventID: UUID? = nil,
        kind: AlertKind? = nil,
        lifecycle: AlertLifecycleDisplayState,
        initialDelivery: AlertDeliveryDisplayState = .unknown,
        resolutionDelivery: AlertDeliveryDisplayState? = nil,
        isAcknowledged: Bool = false,
        locationFreshness: LocationFreshnessPresentationModel? = nil
    ) {
        self.eventID = eventID
        self.kind = kind
        self.lifecycle = lifecycle
        self.initialDelivery = initialDelivery
        self.resolutionDelivery = resolutionDelivery ?? (lifecycle == .resolved ? .unknown : nil)
        self.isAcknowledged = isAcknowledged
        self.locationFreshness = locationFreshness
    }

    init(
        eventID: UUID,
        kind: String,
        eventState: String,
        initialDelivery: String?,
        resolutionDelivery: String?,
        isAcknowledged: Bool,
        locationFreshness: LocationFreshnessPresentationModel? = nil
    ) {
        self.eventID = eventID
        self.kind = AlertKind(rawValue: kind.lowercased())
        switch eventState.lowercased() {
        case "accepted", "created": lifecycle = .accepted
        case "pending": lifecycle = .pending
        case "active": lifecycle = .active
        case "resolved": lifecycle = .resolved
        case "expired": lifecycle = .expired
        default: lifecycle = .unknown
        }
        self.initialDelivery = AlertDeliveryDisplayState(initialDelivery)
        self.resolutionDelivery = resolutionDelivery.map(AlertDeliveryDisplayState.init)
            ?? (lifecycle == .resolved ? .unknown : nil)
        self.isAcknowledged = isAcknowledged
        self.locationFreshness = locationFreshness
    }

    var headline: String {
        let subject: String
        switch kind {
        case .test: subject = "TEST alert"
        case .real: subject = "REAL alert"
        case nil: subject = "Alert"
        }
        switch lifecycle {
        case .savedLocally: return "\(subject) saved on this iPhone"
        case .submitting: return "Sending \(subject.lowercased())…"
        case .delayedConfirmation: return "Confirm delayed \(subject.lowercased())"
        case .accepted: return "\(subject) accepted by SignalWord"
        case .pending: return "\(subject) pending"
        case .active: return "\(subject) active"
        case .resolved: return "\(subject) resolved"
        case .expired: return "\(subject) expired"
        case .rejected: return "\(subject) not accepted"
        case .unknown: return "\(subject) status unavailable"
        }
    }

    var lifecycleDetail: String {
        switch lifecycle {
        case .savedLocally: "The command is saved on this iPhone. SignalWord has not confirmed it yet. Open the app when connected to reconcile it."
        case .submitting: "SignalWord is checking the command. Do not send it again while this is in progress."
        case .delayedConfirmation: "SignalWord checked for an existing alert. Confirm before sending this older command."
        case .accepted: "SignalWord accepted the alert. Email delivery has its own status below."
        case .pending: "SignalWord has the alert, but it is not active yet. Check the status again shortly."
        case .active: "The alert is active. Contact delivery and acknowledgement are shown separately."
        case .resolved: "The sender resolved this alert. The resolution message has its own delivery status."
        case .expired: "This alert expired. Create a new alert if you still need to notify your contact."
        case .rejected: "SignalWord did not accept this command. Review setup and retry when appropriate."
        case .unknown: "The current alert state is not recognized. Refresh to check again; no success is assumed."
        }
    }
}

enum ReadinessCapability: String, CaseIterable, Identifiable {
    case manualAlert
    case recipientConsent
    case acknowledgedTests
    case lockedTestReport
    case shortcutReport
    case optionalLocation

    var id: String { rawValue }
}

struct ReadinessPresentationModel: Equatable, Identifiable {
    let id: ReadinessCapability
    let title: String
    let detail: String
    let isReady: Bool

    static func manualAlert(identityReady: Bool, recipientConfirmed: Bool) -> Self {
        let ready = identityReady && recipientConfirmed
        return Self(
            id: .manualAlert,
            title: "Manual alert",
            detail: ready ? "Available for your confirmed recipient" : "Needs a prepared iPhone and a confirmed recipient",
            isReady: ready
        )
    }

    static func acknowledgedTests(count: Int) -> Self {
        let ready = count >= 2
        return Self(
            id: .acknowledgedTests,
            title: "TEST rehearsal evidence",
            detail: "\(count) of 2 distinct TEST alerts acknowledged",
            isReady: ready
        )
    }

    static func distinctAcknowledgedTestCount(eventIDs: [UUID]) -> Int {
        Set(eventIDs).count
    }

    static func recipientConsent(isConfirmed: Bool) -> Self {
        Self(
            id: .recipientConsent,
            title: "Recipient consent",
            detail: isConfirmed ? "Email confirmation received" : "The recipient must confirm before alerts can be sent",
            isReady: isConfirmed
        )
    }

    static func lockedTestReport(count: Int) -> Self {
        Self(
            id: .lockedTestReport,
            title: "Locked TEST report",
            detail: count == 0 ? "User-reported; not verified by SignalWord" : "\(count) distinct locked TESTs marked by you · not verified by SignalWord",
            isReady: false
        )
    }

    static func shortcutReport(isConfigured: Bool) -> Self {
        Self(
            id: .shortcutReport,
            title: "Shortcut setup report",
            detail: isConfigured ? "Reported by you; iOS setup is not inspected" : "Optional self-report about Vocal Shortcuts",
            isReady: false
        )
    }

    static func optionalLocation(detail: String) -> Self {
        Self(
            id: .optionalLocation,
            title: "Location",
            detail: detail,
            isReady: false
        )
    }
}
