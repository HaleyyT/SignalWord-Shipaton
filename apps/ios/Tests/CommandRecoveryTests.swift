import XCTest
@testable import SignalWordCore

final class CommandRecoveryTests: XCTestCase {
    func testSharedAlertContractExamplesDecodeInSwift() throws {
        let contracts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../contracts/v1").standardizedFileURL
        let request = try WireDate.decoder().decode(AlertCreateRequest.self,
            from: Data(contentsOf: contracts.appendingPathComponent("create-alert.request.json")))
        XCTAssertEqual(request.kind, .test)
        XCTAssertEqual(request.triggerMethod, .vocalShortcut)
        XCTAssertNotNil(request.location)

        let response = try WireDate.decoder().decode(AlertCreationWireResponse.self,
            from: Data(contentsOf: contracts.appendingPathComponent("create-alert.response.json")))
        XCTAssertEqual(response.state, "active")
        XCTAssertEqual(response.delivery, "queued")
        XCTAssertFalse(response.reused)
    }

    func testLifecycleContractsDecodeInLiveClientModels() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../contracts/v1").standardizedFileURL
        func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            try WireDate.decoder().decode(type, from: Data(contentsOf: directory.appendingPathComponent(name + ".response.json")))
        }
        XCTAssertEqual(try decode("profile", as: ProfileProjection.self).displayName, "Alex")
        XCTAssertEqual(try decode("contact", as: TrustedContactProjection.self).status, "confirmed")
        let status = try decode("alert-status", as: AlertStatusProjection.self)
        XCTAssertEqual(status.delivery, "unknown")
        XCTAssertNotNil(status.acknowledgedAt)
        XCTAssertEqual(try decode("recovery", as: [AlertStatusProjection].self), [status])
        XCTAssertEqual(try decode("resolve-alert", as: ResolvedAlertProjection.self).state, "resolved")
    }

    func testServerTimestampsWithAndWithoutFractionalSeconds() throws {
        struct Payload: Decodable { let date: Date }
        for timestamp in ["2026-09-26T08:00:00.123456+00:00", "2026-09-26T08:00:00Z"] {
            let data = Data("{\"date\":\"\(timestamp)\"}".utf8)
            XCTAssertNoThrow(try WireDate.decoder().decode(Payload.self, from: data))
        }
    }

    func testTestCannotOverwritePendingRealAfterCooldown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteAlertCommandStore(directoryURL: directory)
        let now = Date()
        guard case .attempt(let real) = try await store.acquireCanonicalCommand(kind: .real, method: .vocalShortcut, triggeredAt: now, cooldown: 60, attemptLease: 45) else { return XCTFail() }
        try await store.markQueued(real, at: now)
        _ = try await store.acquireCanonicalCommand(kind: .test, method: .manual, triggeredAt: now.addingTimeInterval(61), cooldown: 60, attemptLease: 45)
        let reopened = try SQLiteAlertCommandStore(directoryURL: directory)
        let records = try await reopened.allRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.command.kind == .real })?.command.idempotencyKey, real.idempotencyKey)
    }

    func testDelayedRecoveryRequiresConfirmationAndKeepsKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteAlertCommandStore(directoryURL: directory)
        let now = Date()
        guard case .attempt(let command) = try await store.acquireCanonicalCommand(kind: .real, method: .manual, triggeredAt: now, cooldown: 60, attemptLease: 45) else { return XCTFail() }
        try await store.markQueued(command, at: now)
        let delayed = try await store.acquirePending(kind: .real, at: now.addingTimeInterval(601), attemptLease: 45, allowDelayed: false)
        XCTAssertEqual(delayed, .confirmationRequired(command))
        let confirmed = try await store.acquirePending(kind: .real, at: now.addingTimeInterval(601), attemptLease: 45, allowDelayed: true)
        XCTAssertEqual(confirmed, .attempt(command))
    }

    func testRecoveryDoesNotCreateCommandsAndMigratesLegacy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try FileLockedAlertCommandStore(directoryURL: directory)
        let now = Date()
        guard case .attempt(let command) = try await legacy.acquireCanonicalCommand(kind: .real, method: .manual, triggeredAt: now, cooldown: 60, attemptLease: 45) else { return XCTFail() }
        let migrated = try SQLiteAlertCommandStore(directoryURL: directory)
        let records = try await migrated.allRecords()
        XCTAssertEqual(records.first?.command.idempotencyKey, command.idempotencyKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending-alert.json").path))
        let empty = try await migrated.acquirePending(kind: .test, at: now, attemptLease: 45, allowDelayed: false)
        XCTAssertNil(empty)
        try await migrated.clearAll()
        let cleared = try await migrated.allRecords()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testConcurrentConnectionsLeaseExactlyOneCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try (0..<20).map { _ in try SQLiteAlertCommandStore(directoryURL: directory) }
        let now = Date()
        let attempts = try await withThrowingTaskGroup(of: Int.self) { group in
            for store in stores {
                group.addTask {
                    let result = try await store.acquireCanonicalCommand(kind: .real, method: .vocalShortcut, triggeredAt: now, cooldown: 60, attemptLease: 45)
                    if case .attempt = result { return 1 }; return 0
                }
            }
            var count = 0
            for try await result in group { count += result }
            return count
        }
        XCTAssertEqual(attempts, 1)
    }
}
