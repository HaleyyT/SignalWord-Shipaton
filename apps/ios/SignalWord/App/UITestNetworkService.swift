#if DEBUG && targetEnvironment(simulator)
import Foundation

/// This service exists only in simulator builds. Its data never leaves the device.
@MainActor final class UITestNetworkService: ContactNetworkServing {
    private let preferences = UserDefaults(suiteName: "SignalWord.UIJourney")!
    private let primaryID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!

    private var contacts: [NetworkContact] {
        get {
            if let data = preferences.data(forKey: "network.contacts"),
               let saved = try? JSONDecoder().decode([NetworkContact].self, from: data) { return saved }
            return [.init(contactId: primaryID, name: "Sam", channel: "email", status: "confirmed", primary: true)]
        }
        set { preferences.set(try? JSONEncoder().encode(newValue), forKey: "network.contacts") }
    }
    func contactNetwork(primary: UUID?, policy: ContactRoutingPolicy?) async throws -> ContactNetwork {
        if let primary {
            contacts = contacts.map { .init(contactId: $0.id, name: $0.name, channel: $0.channel, status: $0.status, primary: $0.id == primary) }
        }
        if let policy { preferences.set(policy.rawValue, forKey: "network.policy") }
        return .init(policy: ContactRoutingPolicy(rawValue: preferences.string(forKey: "network.policy") ?? "everyone") ?? .everyone, contacts: contacts)
    }
    func saveNetworkContact(contactID: UUID?, name: String, email: String) async throws -> TrustedContactProjection {
        let id = contactID ?? UUID()
        var updated = contacts.filter { $0.id != id }
        updated.append(.init(contactId: id, name: name, channel: "email", status: "pending", primary: false))
        contacts = updated
        return .init(contactID: id, name: name, status: "pending", confirmationExpiresAt: Date().addingTimeInterval(1800))
    }
    func recipientProgress(eventID: UUID) async throws -> [RecipientProgress] {
        contacts.filter { $0.status == "confirmed" }.map {
            .init(contactId: $0.id, name: $0.name, revoked: false, scheduledAt: Date(), delivery: "queued", acknowledgedAt: nil, resolutionDelivery: nil, failureCode: nil)
        }
    }
    func disableContact(contactID: UUID) async throws -> Bool {
        contacts = contacts.map { .init(contactId: $0.id, name: $0.name, channel: $0.channel, status: $0.id == contactID ? "disabled" : $0.status, primary: $0.primary) }
        return true
    }
}
#endif
