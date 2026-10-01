import Foundation
import XCTest
@testable import SignalWordCore

@MainActor final class CheckInTests: XCTestCase {
    func testSharedTimerFixtureUsesServerOwnedDates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let timer = try decoder.decode(CheckInSnapshot.self, from: Data(contentsOf: root.appending(path: "contracts/v2/check-in.response.json")))
        XCTAssertEqual(timer.deadline.timeIntervalSince(timer.serverNow), 900)
        XCTAssertEqual(timer.graceEndsAt.timeIntervalSince(timer.deadline), 60)
        XCTAssertEqual(timer.state, .active)
    }

    func testUnconfirmedStartSurvivesRelaunchWithoutPretendingActive() async throws {
        let name = "SignalWord.TimerTests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let api = TimerFixture()
        let model = CheckInModel(api: api, preferences: preferences, remindersEnabled: false)
        await model.change(.start, minutes: 15)
        XCTAssertNil(model.snapshot)
        let key = try XCTUnwrap(model.pending?.id)
        let relaunched = CheckInModel(api: api, preferences: preferences, remindersEnabled: false)
        XCTAssertEqual(relaunched.pending?.id, key)
        await api.allow()
        await relaunched.retry()
        XCTAssertEqual(relaunched.snapshot?.state, .active)
        XCTAssertNil(relaunched.pending)
        let requests = await api.requests
        XCTAssertEqual(requests.map(\.id), [key, key])
    }
    func testLostResponseReconcilesWithoutRepeatingTheChange() async throws {
        let name = "SignalWord.TimerTests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let api = TimerFixture()
        let model = CheckInModel(api: api, preferences: preferences, remindersEnabled: false)
        await model.change(.start, minutes: 30)
        await api.commit()
        await model.refresh()
        XCTAssertEqual(model.snapshot?.state, .active)
        XCTAssertNil(model.pending)
        let count = await api.requests.count
        XCTAssertEqual(count, 1)
    }
    func testLateResponseAfterDeletionCannotRestoreTimerState() async {
        let name = "SignalWord.TimerTests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let api = SuspendedTimerFixture()
        let model = CheckInModel(api: api, preferences: preferences, remindersEnabled: false)
        let request = Task { await model.change(.start, minutes: 15) }
        await api.waitUntilStarted()
        model.clear()
        await api.finish()
        await request.value
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.pending)
        XCTAssertNil(preferences.data(forKey: CheckInModel.pendingKey))
    }

    func testDeletionClearsPendingRequestAndRecoveredState() async {
        let name = "SignalWord.TimerTests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = CheckInModel(api: TimerFixture(), preferences: preferences, remindersEnabled: false)
        await model.change(.start, minutes: 60)
        model.clear()
        XCTAssertNil(model.pending)
        XCTAssertNil(preferences.data(forKey: CheckInModel.pendingKey))
        XCTAssertNil(model.snapshot)
    }
}
private actor TimerFixture: CheckInServing {
    var requests: [CheckInCommand] = []
    var unavailable = true
    var snapshot: CheckInSnapshot?
    func allow() { unavailable = false }
    func commit() {
        snapshot = .init(timerId: UUID(), state: .active, deadline: Date().addingTimeInterval(1800),
            graceEndsAt: Date().addingTimeInterval(1860), serverNow: Date(), incidentId: nil, failureCode: nil, incidentState: nil)
    }
    func recoverCheckIn(command: UUID?) async throws -> CheckInSnapshot? { snapshot }
    func changeCheckIn(_ command: CheckInCommand) async throws -> CheckInSnapshot {
        requests.append(command)
        if unavailable { throw URLError(.notConnectedToInternet) }
        commit()
        return snapshot!
    }
}

private actor SuspendedTimerFixture: CheckInServing {
    private var response: CheckedContinuation<CheckInSnapshot, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func recoverCheckIn(command: UUID?) async throws -> CheckInSnapshot? { nil }
    func changeCheckIn(_ command: CheckInCommand) async throws -> CheckInSnapshot {
        await withCheckedContinuation { continuation in
            response = continuation
            waiting?.resume(); waiting = nil
        }
    }
    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() {
        response?.resume(returning: .init(timerId: UUID(), state: .active, deadline: Date(), graceEndsAt: Date(), serverNow: Date(), incidentId: nil, failureCode: nil, incidentState: nil))
        response = nil
    }
}
