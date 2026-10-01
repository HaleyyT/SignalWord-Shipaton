import Foundation

enum CheckInState: String, Codable, Sendable {
    case active, checkedIn = "checked_in", cancelled, escalated, failed
}
struct CheckInSnapshot: Codable, Sendable {
    let timerId: UUID
    let state: CheckInState
    let deadline: Date
    let graceEndsAt: Date
    let serverNow: Date
    let incidentId: UUID?
    let failureCode: String?
    let incidentState: String?
}
struct CheckInCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case start, extend, checkIn = "check_in", cancel }
    let id: UUID
    let action: Action
    let timerId: UUID?
    let minutes: Int?
}
protocol CheckInServing: Sendable {
    func recoverCheckIn(command: UUID?) async throws -> CheckInSnapshot?
    func changeCheckIn(_ command: CheckInCommand) async throws -> CheckInSnapshot
}

enum CheckInFailure: Error { case conflict }
