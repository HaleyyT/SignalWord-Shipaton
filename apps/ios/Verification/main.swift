import Foundation
import SignalWordCore

@main
struct SignalWordCoreVerification {
    static func main() async {
        do {
            try await verifiesFirstTriggerPersistsBeforeNetworkAndCreatesOneAlert()
            try await verifiesConcurrentInvocationsUseOneCanonicalCommand()
            try await verifiesOfflineRelaunchReusesTheSameIdempotencyKey()
            try await verifiesTestCommandCannotSuppressARealTrigger()
            try await verifiesClockRollbackCannotMintADuplicate()
            try await verifiesNonRetryableFailureIsInspectableAndRejected()
            try await verifiesFreshCachedLocationEnrichesWithoutOwningAlertOutcome()
            try await verifiesLocalDeletionClearsDurableAlertState()
            try verifiesRequestBodyExcludesIdempotencyKey()
            try verifiesOnlyFreshValidLocationIsAttached()
            try verifiesServerTimeLocationFreshness()
            try verifiesIllegalAlertTransitionsAreRejected()
            print("SignalWord core verification passed.")
        } catch {
            fputs("SignalWord core verification failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verifiesFirstTriggerPersistsBeforeNetworkAndCreatesOneAlert() async throws {
        try await withTemporaryStore { store in
            let eventID = UUID()
            let api = RecordingAlertAPI(result: .success(createdAlert(eventID)))
            let coordinator = coordinator(api: api, store: store, now: referenceDate)

            let outcome = await coordinator.trigger(kind: .test, method: .vocalShortcut)

            try require(outcome == .created(eventID: eventID), "first trigger should create its event")
            try require(await api.requestCount() == 1, "first trigger should issue one request")
            let record = await store.latestTriggerRecord()
            try require(record?.phase == .created, "created outcome must be inspectable")
            try require(record?.canonicalEventID == eventID, "canonical event must be persisted")
        }
    }

    private static func verifiesConcurrentInvocationsUseOneCanonicalCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = RecordingAlertAPI(
            result: .success(createdAlert(UUID())),
            delayNanoseconds: 100_000_000
        )

        let outcomes = await withTaskGroup(of: TriggerOutcome.self, returning: [TriggerOutcome].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let store = try! FileLockedAlertCommandStore(directoryURL: directory)
                    return await coordinator(api: api, store: store, now: referenceDate)
                        .trigger(kind: .real, method: .vocalShortcut)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        try require(await api.requestCount() == 1, "20 concurrent invocations must lease one request")
        try require(Set(await api.idempotencyKeys()).count == 1, "concurrent invocations must share one key")
        try require(outcomes.filter(isCreated).count == 1, "exactly one invocation should report creation")
        try require(outcomes.filter { $0 == .queuedOffline }.count == 19, "other invocations should observe pending work")
    }

    private static func verifiesOfflineRelaunchReusesTheSameIdempotencyKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let offlineAPI = RecordingAlertAPI(result: .failure(RetryableStubError.offline))
        let firstStore = try FileLockedAlertCommandStore(directoryURL: directory)

        let firstOutcome = await coordinator(api: offlineAPI, store: firstStore, now: referenceDate)
            .trigger(kind: .real, method: .vocalShortcut)
        let queuedRecord = await firstStore.latestTriggerRecord()
        try require(firstOutcome == .queuedOffline, "offline trigger must be durably queued")
        try require(queuedRecord?.phase == .queuedOffline, "queued state must survive the caller")

        let eventID = UUID()
        let recoveredAPI = RecordingAlertAPI(result: .success(createdAlert(eventID)))
        let relaunchedStore = try FileLockedAlertCommandStore(directoryURL: directory)
        let recoveredOutcome = await coordinator(
            api: recoveredAPI,
            store: relaunchedStore,
            now: referenceDate.addingTimeInterval(61)
        ).trigger(kind: .real, method: .vocalShortcut)

        try require(recoveredOutcome == .created(eventID: eventID), "due command should recover after relaunch")
        try require(
            await offlineAPI.idempotencyKeys().first == recoveredAPI.idempotencyKeys().first,
            "offline retry must reuse the original idempotency key"
        )
    }

    private static func verifiesClockRollbackCannotMintADuplicate() async throws {
        try await withTemporaryStore { store in
            let eventID = UUID()
            let api = RecordingAlertAPI(result: .success(createdAlert(eventID)))
            let first = await coordinator(api: api, store: store, now: referenceDate)
                .trigger(kind: .real, method: .manual)
            let rolledBack = await coordinator(
                api: api,
                store: store,
                now: referenceDate.addingTimeInterval(-86_400)
            ).trigger(kind: .real, method: .manual)

            try require(first == .created(eventID: eventID), "initial trigger should create")
            try require(rolledBack == .reused(eventID: eventID), "clock rollback should reuse canonical event")
            try require(await api.requestCount() == 1, "clock rollback must not issue another request")
        }
    }

    private static func verifiesTestCommandCannotSuppressARealTrigger() async throws {
        try await withTemporaryStore { store in
            let api = RecordingAlertAPI(result: .failure(RetryableStubError.offline))
            let coordinator = coordinator(api: api, store: store, now: referenceDate)

            let testOutcome = await coordinator.trigger(kind: .test, method: .manual)
            let testKey = await api.idempotencyKeys().first
            let realOutcome = await coordinator.trigger(kind: .real, method: .vocalShortcut)
            let keys = await api.idempotencyKeys()

            try require(testOutcome == .queuedOffline, "offline TEST should be queued")
            try require(realOutcome == .queuedOffline, "REAL must attempt even while TEST is queued")
            try require(keys.count == 2, "REAL must not reuse a queued TEST request")
            try require(keys.last != testKey, "REAL must receive a distinct idempotency key")
            try require(
                await store.latestTriggerRecord()?.command.kind == .real,
                "durable outbox must retain the higher-priority REAL command"
            )
        }
    }

    private static func verifiesNonRetryableFailureIsInspectableAndRejected() async throws {
        try await withTemporaryStore { store in
            let api = RecordingAlertAPI(result: .failure(StubError.unauthorized))
            let outcome = await coordinator(api: api, store: store, now: referenceDate)
                .trigger(kind: .real, method: .vocalShortcut)

            try require(outcome == .rejected, "non-retryable failure must not enter the outbox")
            try require(await store.latestTriggerRecord()?.phase == .rejected, "rejection must be inspectable")
        }
    }

    private static func verifiesFreshCachedLocationEnrichesWithoutOwningAlertOutcome() async throws {
        try await withTemporaryStore { store in
            let eventID = UUID()
            let api = RecordingAlertAPI(result: .success(createdAlert(eventID)))
            let sample = AlertLocationSnapshot(
                latitude: -33.8688, longitude: 151.2093,
                horizontalAccuracyM: 12, capturedAt: referenceDate.addingTimeInterval(-10)
            )
            let coordinator = AlertTriggerCoordinator(
                alertAPI: api,
                commandStore: store,
                locationProvider: StubLocationProvider(snapshot: sample),
                now: { referenceDate }
            )

            let outcome = await coordinator.trigger(kind: .real, method: .vocalShortcut)

            try require(outcome == .created(eventID: eventID), "location enrichment must not change alert success")
            try require(await api.locations() == [sample], "fresh cached location should reach the alert API")
        }
    }

    private static func verifiesLocalDeletionClearsDurableAlertState() async throws {
        try await withTemporaryStore { store in
            let api = RecordingAlertAPI(result: .failure(RetryableStubError.offline))
            _ = await coordinator(api: api, store: store, now: referenceDate)
                .trigger(kind: .real, method: .manual)
            try require(await store.latestTriggerRecord() != nil, "queued alert must exist before deletion")
            try await store.clearAll()
            try require(await store.latestTriggerRecord() == nil, "delete-data cleanup must remove durable alert state")
        }
    }

    private static func verifiesRequestBodyExcludesIdempotencyKey() throws {
        let command = AlertCommand(
            idempotencyKey: UUID(), kind: .test,
            triggerMethod: .vocalShortcut, clientTriggeredAt: referenceDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(command.request())) as? [String: Any]
        try require(object?["idempotencyKey"] == nil, "idempotency key belongs only in the HTTP header")
    }

    private static func verifiesOnlyFreshValidLocationIsAttached() throws {
        let fresh = AlertLocationSnapshot(
            latitude: -33.8688, longitude: 151.2093,
            horizontalAccuracyM: 12, capturedAt: referenceDate.addingTimeInterval(-30)
        )
        let stale = AlertLocationSnapshot(
            latitude: -33.8688, longitude: 151.2093,
            horizontalAccuracyM: 12, capturedAt: referenceDate.addingTimeInterval(-121)
        )
        try require(fresh.isUsable(at: referenceDate), "fresh valid location should be usable")
        try require(!stale.isUsable(at: referenceDate), "stale location must not be attached")
        try require(
            !AlertLocationSnapshot(latitude: 91, longitude: 0, horizontalAccuracyM: 1, capturedAt: referenceDate)
                .isUsable(at: referenceDate),
            "invalid coordinates must not be attached"
        )
    }

    private static func verifiesServerTimeLocationFreshness() throws {
        try require(LocationFreshness.classify(lastReceivedAt: referenceDate.addingTimeInterval(-30), serverNow: referenceDate) == .live, "30 seconds is live")
        try require(LocationFreshness.classify(lastReceivedAt: referenceDate.addingTimeInterval(-31), serverNow: referenceDate) == .recent, "31 seconds is recent")
        try require(LocationFreshness.classify(lastReceivedAt: referenceDate.addingTimeInterval(-121), serverNow: referenceDate) == .stale, "older samples are stale")
        try require(LocationFreshness.classify(lastReceivedAt: nil, serverNow: referenceDate) == .unavailable, "missing samples are unavailable")
    }

    private static func verifiesIllegalAlertTransitionsAreRejected() throws {
        try require(AlertLifecycleState.ready.canTransition(to: .triggering), "ready can trigger")
        try require(!AlertLifecycleState.resolved.canTransition(to: .active), "resolved event cannot reactivate")
    }
}

private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

private func createdAlert(_ eventID: UUID) -> CreatedAlert {
    CreatedAlert(eventID: eventID, serverTriggeredAt: referenceDate)
}

private func coordinator(
    api: RecordingAlertAPI,
    store: FileLockedAlertCommandStore,
    now: Date
) -> AlertTriggerCoordinator {
    AlertTriggerCoordinator(alertAPI: api, commandStore: store, now: { now })
}

private func isCreated(_ outcome: TriggerOutcome) -> Bool {
    if case .created = outcome { return true }
    return false
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("signalword-verification-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func withTemporaryStore(
    _ body: (FileLockedAlertCommandStore) async throws -> Void
) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(FileLockedAlertCommandStore(directoryURL: directory))
}

private enum StubError: RetryClassifiableError {
    var isRetryable: Bool { false }
    case unauthorized
}
private enum RetryableStubError: RetryClassifiableError {
    case offline
    var isRetryable: Bool { true }
}
private enum VerificationError: Error { case assertion(String) }

private struct StubLocationProvider: AlertLocationProviding {
    let snapshot: AlertLocationSnapshot?
    func cachedSnapshot(at now: Date) async -> AlertLocationSnapshot? {
        guard let snapshot, snapshot.isUsable(at: now) else { return nil }
        return snapshot
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationError.assertion(message) }
}

private actor RecordingAlertAPI: AlertCreating {
    private let result: Result<CreatedAlert, Error>
    private let delayNanoseconds: UInt64
    private var commands: [AlertCommand] = []
    private var capturedLocations: [AlertLocationSnapshot?] = []

    init(result: Result<CreatedAlert, Error>, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func createAlert(_ command: AlertCommand, location: AlertLocationSnapshot?) async throws -> CreatedAlert {
        commands.append(command)
        capturedLocations.append(location)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try result.get()
    }

    func requestCount() -> Int { commands.count }
    func idempotencyKeys() -> [UUID] { commands.map(\.idempotencyKey) }
    func locations() -> [AlertLocationSnapshot?] { capturedLocations }
}
