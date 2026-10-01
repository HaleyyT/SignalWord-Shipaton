import Foundation

// Shared wire models used by the live API and contract fixture tests.
struct TrustedContactProjection: Decodable, Equatable, Sendable {
    let contactID: UUID
    let name: String
    let status: String
    let confirmationExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case contactID = "contactId"
        case name
        case status
        case confirmationExpiresAt
    }
}

struct AlertStatusProjection: Decodable, Equatable, Sendable {
    let eventID: UUID
    let kind: String
    let triggeredAt: Date
    let acknowledgedAt: Date?
    let resolutionDelivery: String?
    let state: String
    let delivery: String
    let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case kind, triggeredAt, acknowledgedAt, resolutionDelivery
        case state
        case delivery
        case resolvedAt
    }
}

struct ResolvedAlertProjection: Decodable, Equatable, Sendable {
    let eventID: UUID
    let state: String
    let resolvedAt: Date

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case state
        case resolvedAt
    }
}


struct ProfileProjection: Codable, Sendable { let displayName: String }

enum UserAPIError: Error, Sendable {
    case unavailable
    case rejected(statusCode: Int)
    case invalidResponse
}

enum DeviceLocationAuthorization: Sendable {
    case notRequested
    case approximate
    case precise
    case denied
}
