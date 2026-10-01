import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AlertCommandStoreError: Error, Sendable {
    case cannotOpenLock(Int32)
    case cannotLock(Int32)
    case corruptRecord
}

/// A minimal App-Group-compatible store. A separate lock file and `flock`
/// protect the read/decide/write transaction across app and extension processes.
public actor FileLockedAlertCommandStore: AlertCommandPersisting {
    private let recordURL: URL
    private let lockURL: URL
    private let retryDelays: [TimeInterval]

    public init(directoryURL: URL, retryDelays: [TimeInterval] = [60, 300, 900]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        recordURL = directoryURL.appendingPathComponent("pending-alert.json", isDirectory: false)
        lockURL = directoryURL.appendingPathComponent("pending-alert.lock", isDirectory: false)
        self.retryDelays = retryDelays.isEmpty ? [60] : retryDelays
    }

    public func acquireCanonicalCommand(
        kind: AlertKind,
        method: TriggerMethod,
        triggeredAt: Date,
        cooldown: TimeInterval,
        attemptLease: TimeInterval
    ) async throws -> CanonicalCommandAcquisition {
        try withExclusiveLock { record in
            if let existing = record {
                let sameKind = existing.command.kind == kind

                // Pending work is an outbox item, not merely a cooldown marker. A
                // process relaunch must retry the original command and key even
                // after the cooldown has elapsed. A REAL trigger may replace a
                // TEST command so a rehearsal can never suppress an emergency.
                if sameKind, existing.phase == .attempting || existing.phase == .queuedOffline {
                    if let nextAttemptAt = existing.nextAttemptAt, triggeredAt < nextAttemptAt {
                        return .pending(existing.command)
                    }
                    record = PersistedTriggerRecord(
                        command: existing.command,
                        phase: .attempting,
                        updatedAt: triggeredAt,
                        retryCount: existing.retryCount,
                        nextAttemptAt: triggeredAt.addingTimeInterval(attemptLease)
                    )
                    return .attempt(existing.command)
                }

                if isInsideCooldown(existing, at: triggeredAt, cooldown: cooldown) {
                    if existing.command.kind == .test, kind == .real {
                        // Fall through and mint a distinct REAL command.
                    } else {
                switch existing.phase {
                case .created:
                    guard let eventID = existing.canonicalEventID else {
                        throw AlertCommandStoreError.corruptRecord
                    }
                    return .created(existing.command, eventID: eventID)
                case .rejected:
                    return .rejected(existing.command)
                case .attempting, .queuedOffline:
                    // Same-kind unfinished records are handled above. Preserve
                    // an in-flight REAL command rather than overwriting it with
                    // a lower-priority TEST invocation.
                    return .pending(existing.command)
                        }
                    }
                }
            }

            let command = AlertCommand(
                idempotencyKey: UUID(), kind: kind,
                triggerMethod: method, clientTriggeredAt: triggeredAt
            )
            record = PersistedTriggerRecord(
                command: command, phase: .attempting, updatedAt: triggeredAt,
                nextAttemptAt: triggeredAt.addingTimeInterval(attemptLease)
            )
            return .attempt(command)
        }
    }

    public func markCreated(_ command: AlertCommand, alert: CreatedAlert, at: Date) async throws {
        try withExclusiveLock { record in
            guard let existing = record, existing.command.idempotencyKey == command.idempotencyKey else { return }
            record = PersistedTriggerRecord(
                command: command, phase: .created, updatedAt: at,
                retryCount: existing.retryCount, canonicalEventID: alert.eventID
            )
        }
    }

    public func markQueued(_ command: AlertCommand, at: Date) async throws {
        try withExclusiveLock { record in
            guard let existing = record, existing.command.idempotencyKey == command.idempotencyKey else { return }
            let retryCount = existing.retryCount + 1
            let delay = retryDelays[min(retryCount - 1, retryDelays.count - 1)]
            record = PersistedTriggerRecord(
                command: command, phase: .queuedOffline, updatedAt: at,
                retryCount: retryCount, nextAttemptAt: at.addingTimeInterval(delay)
            )
        }
    }

    public func markRejected(_ command: AlertCommand, at: Date) async throws {
        try withExclusiveLock { record in
            guard let existing = record, existing.command.idempotencyKey == command.idempotencyKey else { return }
            record = PersistedTriggerRecord(
                command: command, phase: .rejected, updatedAt: at,
                retryCount: existing.retryCount
            )
        }
    }

    public func latestTriggerRecord() async -> PersistedTriggerRecord? {
        try? withExclusiveLock { $0 }
    }

    public func clearAll() async throws {
        try withExclusiveLock { record in record = nil }
    }

    private func isInsideCooldown(
        _ record: PersistedTriggerRecord,
        at date: Date,
        cooldown: TimeInterval
    ) -> Bool {
        let elapsed = date.timeIntervalSince(record.command.clientTriggeredAt)
        // A clock rollback must fail safe by reusing the command, not minting a duplicate.
        return elapsed < 0 || elapsed < cooldown
    }

    private func withExclusiveLock<T>(
        _ operation: (inout PersistedTriggerRecord?) throws -> T
    ) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AlertCommandStoreError.cannotOpenLock(errno) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AlertCommandStoreError.cannotLock(errno) }
        defer { flock(descriptor, LOCK_UN) }

        var record = try loadRecord()
        let original = record
        let result = try operation(&record)
        if record != original { try saveRecord(record) }
        return result
    }

    private func loadRecord() throws -> PersistedTriggerRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PersistedTriggerRecord.self, from: Data(contentsOf: recordURL))
        } catch {
            throw AlertCommandStoreError.corruptRecord
        }
    }

    private func saveRecord(_ record: PersistedTriggerRecord?) throws {
        guard let record else {
            if FileManager.default.fileExists(atPath: recordURL.path) {
                try FileManager.default.removeItem(at: recordURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: [.atomic])
        _ = chmod(recordURL.path, S_IRUSR | S_IWUSR)
    }
}
