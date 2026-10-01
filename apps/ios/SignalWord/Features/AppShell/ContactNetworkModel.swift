import Foundation
import Observation

@MainActor @Observable
final class ContactNetworkModel {
    private let api: (any ContactNetworkServing)?
    private var generation = 0
    private var refreshVersion = 0
    private(set) var network: ContactNetwork?
    private(set) var recipientEventID: UUID?
    private(set) var recipients: [RecipientProgress] = []
    private(set) var busy = false
    private(set) var message: String?

    init(api: (any ContactNetworkServing)?) { self.api = api }

    func clear() {
        generation += 1
        refreshVersion += 1
        network = nil
        recipients = []
        recipientEventID = nil
        message = nil
    }

    func refresh(eventID: UUID?) async {
        guard let api, !busy else { return }
        let requestGeneration = generation
        refreshVersion += 1
        let version = refreshVersion
        do {
            let updated = try await api.contactNetwork(primary: nil, policy: nil)
            let progress: [RecipientProgress]
            if let eventID { progress = try await api.recipientProgress(eventID: eventID) } else { progress = [] }
            guard generation == requestGeneration, version == refreshVersion else { return }
            network = updated
            recipients = progress
            recipientEventID = eventID
            message = nil
        } catch {
            guard generation == requestGeneration, version == refreshVersion else { return }
            message = "Could not refresh your circle. Displayed progress may be out of date. Retry when connected."
        }
    }

    func save(contactID: UUID?, name: String, email: String) async -> Bool {
        await perform { api in _ = try await api.saveNetworkContact(contactID: contactID, name: name, email: email) }
    }

    func configure(primary: UUID? = nil, policy: ContactRoutingPolicy? = nil) async {
        _ = await perform { api in _ = try await api.contactNetwork(primary: primary, policy: policy) }
    }

    func withdraw(_ id: UUID) async {
        _ = await perform { api in _ = try await api.disableContact(contactID: id) }
    }

    private func perform(_ action: (any ContactNetworkServing) async throws -> Void) async -> Bool {
        guard let api, !busy else { return false }
        refreshVersion += 1
        busy = true
        let requestGeneration = generation
        defer { busy = false }
        do {
            try await action(api)
            let updated = try await api.contactNetwork(primary: nil, policy: nil)
            guard generation == requestGeneration else { return false }
            network = updated
            message = nil
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            message = "The change could not be confirmed. Refresh before retrying. No new consent or routing is assumed."
            return false
        }
    }
}
