#if DEBUG && targetEnvironment(simulator)
import Foundation

@MainActor final class UITestCheckInService: CheckInServing {
    private let preferences = UserDefaults(suiteName: "SignalWord.UIJourney")!
    func recoverCheckIn(command: UUID?) async throws -> CheckInSnapshot? {
        if ProcessInfo.processInfo.arguments.contains("--timer-escalated") {
            let event = UUID(uuidString: "b1000000-0000-4000-8000-000000000001")!
            if preferences.string(forKey: "fixture.event") == nil {
                preferences.set(event.uuidString, forKey: "fixture.event")
                preferences.set("real", forKey: "fixture.kind")
                preferences.set("active", forKey: "fixture.state")
            }
            return .init(timerId: UUID(uuidString: "b2000000-0000-4000-8000-000000000001")!, state: .escalated,
                deadline: Date().addingTimeInterval(-120), graceEndsAt: Date().addingTimeInterval(-60), serverNow: Date(),
                incidentId: event, failureCode: nil, incidentState: preferences.string(forKey: "fixture.state") ?? "active")
        }
        guard let data = preferences.data(forKey: "timer.snapshot") else { return nil }
        return try JSONDecoder().decode(CheckInSnapshot.self, from: data)
    }
    func changeCheckIn(_ command: CheckInCommand) async throws -> CheckInSnapshot {
        let previous = try await recoverCheckIn(command: nil)
        let state: CheckInState = command.action == .checkIn ? .checkedIn : command.action == .cancel ? .cancelled : .active
        let deadline = (command.action == .extend ? previous?.deadline ?? Date() : Date()).addingTimeInterval(Double(command.minutes ?? 15) * 60)
        let result = CheckInSnapshot(timerId: previous?.timerId ?? UUID(), state: state, deadline: deadline,
            graceEndsAt: deadline.addingTimeInterval(60), serverNow: Date(), incidentId: nil, failureCode: nil, incidentState: nil)
        preferences.set(try JSONEncoder().encode(result), forKey: "timer.snapshot")
        return result
    }
}
#endif
