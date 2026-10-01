import Foundation
import SQLite3

public enum CommandDatabaseError: Error { case unavailable, corrupt }

/// Each kind has its own durable slot. Transactions coordinate the app and intents.
/// No destination, location, token, or phrase is stored here.
public actor SQLiteAlertCommandStore: AlertCommandPersisting {
    private let url: URL

    public init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directoryURL.path)
        #endif
        url = directoryURL.appendingPathComponent("alert-commands.sqlite")
        try Self.transaction(url) { db in
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS commands (kind TEXT PRIMARY KEY, record TEXT NOT NULL)")
            let legacy = directoryURL.appendingPathComponent("pending-alert.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let record = try decoder.decode(PersistedTriggerRecord.self, from: Data(contentsOf: legacy))
                if try Self.read(db, kind: record.command.kind) == nil { try Self.write(db, record) }
            }
        }
        // Only remove the legacy record after the import transaction committed.
        let legacy = directoryURL.appendingPathComponent("pending-alert.json")
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    public func acquireCanonicalCommand(kind: AlertKind, method: TriggerMethod, triggeredAt: Date,
                                        cooldown: TimeInterval, attemptLease: TimeInterval) async throws -> CanonicalCommandAcquisition {
        try Self.transaction(url) { db in
            if let existing = try Self.read(db, kind: kind) {
                if existing.phase == .attempting || existing.phase == .queuedOffline {
                    return try Self.acquire(db, existing, at: triggeredAt, lease: attemptLease, allowDelayed: false)
                }
                if triggeredAt.timeIntervalSince(existing.command.clientTriggeredAt) < cooldown {
                    if let id = existing.canonicalEventID { return .created(existing.command, eventID: id) }
                    return .rejected(existing.command)
                }
            }
            let command = AlertCommand(idempotencyKey: UUID(), kind: kind, triggerMethod: method, clientTriggeredAt: triggeredAt)
            try Self.write(db, PersistedTriggerRecord(command: command, phase: .attempting, updatedAt: triggeredAt,
                                                      nextAttemptAt: triggeredAt.addingTimeInterval(attemptLease)))
            return .attempt(command)
        }
    }

    public func acquirePending(kind: AlertKind, at: Date, attemptLease: TimeInterval, allowDelayed: Bool) async throws -> CanonicalCommandAcquisition? {
        try Self.transaction(url) { db in
            guard let record = try Self.read(db, kind: kind), record.phase == .attempting || record.phase == .queuedOffline else { return nil }
            return try Self.acquire(db, record, at: at, lease: attemptLease, allowDelayed: allowDelayed)
        }
    }

    private static func acquire(_ db: OpaquePointer, _ record: PersistedTriggerRecord, at: Date,
                                lease: TimeInterval, allowDelayed: Bool) throws -> CanonicalCommandAcquisition {
        if let due = record.nextAttemptAt, at < due { return .pending(record.command) }
        if !allowDelayed && at.timeIntervalSince(record.command.clientTriggeredAt) > 600 {
            return .confirmationRequired(record.command)
        }
        try write(db, PersistedTriggerRecord(command: record.command, phase: .attempting, updatedAt: at,
                                             retryCount: record.retryCount, nextAttemptAt: at.addingTimeInterval(lease)))
        return .attempt(record.command)
    }

    public func markCreated(_ command: AlertCommand, alert: CreatedAlert, at: Date) async throws {
        try update(command) { old in PersistedTriggerRecord(command: command, phase: .created, updatedAt: at,
            retryCount: old.retryCount, canonicalEventID: alert.eventID) }
    }
    public func markQueued(_ command: AlertCommand, at: Date) async throws {
        try update(command) { old in
            let delay: TimeInterval = [5, 15, 60][min(old.retryCount, 2)]
            return PersistedTriggerRecord(command: command, phase: .queuedOffline, updatedAt: at,
                retryCount: old.retryCount + 1, nextAttemptAt: at.addingTimeInterval(delay))
        }
    }
    public func markRejected(_ command: AlertCommand, at: Date) async throws {
        try update(command) { old in PersistedTriggerRecord(command: command, phase: .rejected, updatedAt: at, retryCount: old.retryCount) }
    }
    public func allRecords() async throws -> [PersistedTriggerRecord] {
        try Self.transaction(url) { db in try [AlertKind.real, .test].compactMap { try Self.read(db, kind: $0) } }
    }
    public func latestTriggerRecord() async -> PersistedTriggerRecord? {
        try? await allRecords().max { $0.updatedAt < $1.updatedAt }
    }
    public func clearAll() async throws { try Self.transaction(url) { try Self.execute($0, "DELETE FROM commands") } }

    private func update(_ command: AlertCommand, transform: (PersistedTriggerRecord) -> PersistedTriggerRecord) throws {
        try Self.transaction(url) { db in
            guard let old = try Self.read(db, kind: command.kind), old.command.idempotencyKey == command.idempotencyKey else { throw CommandDatabaseError.corrupt }
            try Self.write(db, transform(old))
        }
    }
    private static func transaction<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else { if let handle { sqlite3_close(handle) }; throw CommandDatabaseError.unavailable }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        try execute(db, "PRAGMA synchronous=FULL")
        try execute(db, "BEGIN IMMEDIATE")
        do { let value = try body(db); try execute(db, "COMMIT"); return value }
        catch { try? execute(db, "ROLLBACK"); throw error }
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CommandDatabaseError.unavailable }
    }
    private static func read(_ db: OpaquePointer, kind: AlertKind) throws -> PersistedTriggerRecord? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT record FROM commands WHERE kind = ?", -1, &statement, nil) == SQLITE_OK else { throw CommandDatabaseError.unavailable }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, kind.rawValue)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw CommandDatabaseError.corrupt }
        let decoder = JSONDecoder()
        return try decoder.decode(PersistedTriggerRecord.self, from: Data(String(cString: bytes).utf8))
    }
    private static func write(_ db: OpaquePointer, _ record: PersistedTriggerRecord) throws {
        let encoder = JSONEncoder()
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO commands(kind,record) VALUES(?,?) ON CONFLICT(kind) DO UPDATE SET record=excluded.record", -1, &statement, nil) == SQLITE_OK else { throw CommandDatabaseError.unavailable }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, record.command.kind.rawValue); bind(statement, 2, text)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CommandDatabaseError.unavailable }
    }
    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
}
