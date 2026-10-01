import Foundation

public enum ContactRoutingPolicy: String, Codable, Sendable, CaseIterable {
    case everyone
    case primaryThenOthers = "primary_then_others"

    public var title: String {
        switch self {
        case .everyone: "Everyone immediately"
        case .primaryThenOthers: "Primary now, others after 2 minutes"
        }
    }
}

public struct NetworkContact: Codable, Sendable, Identifiable {
    public let contactId: UUID
    public let name: String
    public let channel: String
    public let status: String
    public let primary: Bool
    public var id: UUID { contactId }
}

public struct ContactNetwork: Codable, Sendable {
    public let policy: ContactRoutingPolicy
    public let contacts: [NetworkContact]
}

public struct RecipientProgress: Codable, Sendable, Identifiable {
    public let contactId: UUID
    public let name: String
    public let revoked: Bool
    public let scheduledAt: Date
    public let delivery: String
    public let acknowledgedAt: Date?
    public let resolutionDelivery: String?
    public let failureCode: String?
    public var id: UUID { contactId }

    public func summary(at now: Date) -> String {
        if revoked { return "Consent withdrawn — access revoked" }
        if failureCode == "EVENT_RESOLVED" { return "Not sent — alert resolved" }
        if failureCode == "EVENT_EXPIRED" { return "Not sent — alert expired" }
        switch delivery {
        case "unknown": return "Delivery outcome unknown — under reconciliation"
        case "failed": return "Delivery failed"
        case "delivered": return "Provider reported delivery"
        case "sent": return "Accepted by provider"
        default: return scheduledAt > now ? "Scheduled for escalation" : "Queued for delivery"
        }
    }
}

protocol ContactNetworkServing: Sendable {
    func contactNetwork(primary: UUID?, policy: ContactRoutingPolicy?) async throws -> ContactNetwork
    func saveNetworkContact(contactID: UUID?, name: String, email: String) async throws -> TrustedContactProjection
    func recipientProgress(eventID: UUID) async throws -> [RecipientProgress]
    func disableContact(contactID: UUID) async throws -> Bool
}
