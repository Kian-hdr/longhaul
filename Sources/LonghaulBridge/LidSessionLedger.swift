import Foundation
import Darwin

public enum LidSessionLedgerError: Error { case unsafePath, busy, io, invalidRecord, admissionBlocked, invalidTransition }

/// A durable admission interlock, not ownership of the shared macOS bit. No
/// method here calls IOKit. Callers still qualify sensors/co-owners before writes.
public final class LidSessionLedger {
    public enum Stage: String, Codable, Sendable {
        case enableIntent, enabled, enableFailed, cleanupAttempted, cleanupAccepted, cleanupFailed, unresolved
    }
    public struct Record: Codable, Sendable, Equatable {
        public let version: Int
        public let identity: LidSessionIdentity
        public var stage: Stage
        public let enabledIntentAt: Double
        public var updatedAt: Double
        public var enableResult: LidMutationResult?
        public var cleanupAttemptedAt: Double?
        public var cleanupResult: LidMutationResult?
        public var reason: String?
    }
    public enum Admission: Equatable, Sendable {
        case available
        case blocked(Record)
        case previousBoot(Record)
    }
    private let directory: Int32
    private static let recordName = "lid-current-session.json"
    private static let lockName = ".lid-session-ledger.lock"
    private static let maximumBytes = 16_384

    /// Root must already exist, be owned by this user and private (0700).
    /// All subsequent I/O is anchored to this checked directory descriptor.
    public init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw LidSessionLedgerError.unsafePath }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LidSessionLedgerError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw LidSessionLedgerError.unsafePath
        }
        directory = fd
    }
    deinit { Darwin.close(directory) }

    /// Kernel boot-session UUID. Failure must block admission, never fall back to
    /// a timestamp, app identity, or a value supplied over the policy channel.
    public static func currentBootID() throws -> String {
        var bytes = [CChar](repeating: 0, count: 128), count = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              count > 0, count <= bytes.count else { throw LidSessionLedgerError.io }
        let value = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard UUID(uuidString: value) != nil else { throw LidSessionLedgerError.invalidRecord }
        return value
    }

    /// Read the current checked record without changing admission or reconciling it.
    public func currentRecord() throws -> Record? { try locked { try readRecord() } }

    public func admission(currentBootID: String) throws -> Admission {
        guard UUID(uuidString: currentBootID) != nil else { throw LidSessionLedgerError.invalidRecord }
        return try locked {
            guard let record = try readRecord() else { return .available }
            if record.identity.bootID != currentBootID { return .previousBoot(record) }
            return record.stage == .cleanupAccepted ? .available : .blocked(record)
        }
    }

    /// Persist before authorizing the one possible enable. Even a missing enable
    /// result thereafter blocks admission. Reusing the last session UUID is refused.
    public func beginEnable(identity: LidSessionIdentity, at time: Double) throws {
        guard identity.isValid, validTime(time) else { throw LidSessionLedgerError.invalidRecord }
        try locked {
            if let current = try readRecord() {
                guard current.identity.bootID == identity.bootID, current.stage == .cleanupAccepted,
                      current.identity.sessionID != identity.sessionID else { throw LidSessionLedgerError.admissionBlocked }
            }
            try writeRecord(.init(version: 1, identity: identity, stage: .enableIntent,
                                  enabledIntentAt: time, updatedAt: time))
        }
    }
    public func recordEnableResult(identity: LidSessionIdentity, result: LidMutationResult, at time: Double) throws {
        try transition(identity, at: time, from: [.enableIntent]) {
            $0.enableResult = result; $0.stage = result.succeeded ? .enabled : .enableFailed
        }
    }
    /// Exclusive durable intent is permission for at most one qualified clear.
    /// A failed/unknown outcome can never return to a retryable state.
    public func beginCleanupAttempt(identity: LidSessionIdentity, at time: Double) throws {
        try transition(identity, at: time, from: [.enableIntent, .enabled, .enableFailed]) {
            $0.stage = .cleanupAttempted; $0.cleanupAttemptedAt = time
        }
    }
    public func recordCleanupResult(identity: LidSessionIdentity, result: LidMutationResult, at time: Double) throws {
        try transition(identity, at: time, from: [.cleanupAttempted]) {
            $0.cleanupResult = result; $0.stage = result.succeeded ? .cleanupAccepted : .cleanupFailed
        }
    }
    public func markUnresolved(identity: LidSessionIdentity, reason: String, at time: Double) throws {
        guard !reason.isEmpty, reason.utf8.count <= 1024 else { throw LidSessionLedgerError.invalidRecord }
        try transition(identity, at: time, from: [.enableIntent, .enabled, .enableFailed, .cleanupAttempted, .cleanupAccepted, .cleanupFailed, .unresolved]) {
            $0.stage = .unresolved; $0.reason = reason
        }
    }

    /// Archive a structurally valid record from a different *locally observed*
    /// boot. Reboot ends the old kernel's state; this does not clear current state
    /// or certify current admission sensors. Unknown/corrupt records stay blocked.
    @discardableResult public func reconcilePreviousBoot(currentBootID: String) throws -> Bool {
        guard UUID(uuidString: currentBootID) != nil, currentBootID == (try Self.currentBootID()) else {
            throw LidSessionLedgerError.invalidRecord
        }
        return try locked {
            guard let record = try readRecord(), record.identity.bootID != currentBootID else { return false }
            let archive = "lid-retired-" + record.identity.bootID + "-" + record.identity.sessionID + ".json"
            guard renameatx_np(directory, Self.recordName, directory, archive, UInt32(RENAME_EXCL)) == 0,
                  fsync(directory) == 0 else { throw LidSessionLedgerError.io }
            return true
        }
    }

    private func validTime(_ time: Double) -> Bool { time.isFinite && time >= 0 }
    private func transition(_ identity: LidSessionIdentity, at time: Double, from stages: [Stage],
                            change: (inout Record) -> Void) throws {
        guard identity.isValid, validTime(time) else { throw LidSessionLedgerError.invalidRecord }
        try locked {
            guard var record = try readRecord(), record.identity == identity, stages.contains(record.stage),
                  time >= record.updatedAt else { throw LidSessionLedgerError.invalidTransition }
            change(&record); record.updatedAt = time; try writeRecord(record)
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = openat(directory, Self.lockName, O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LidSessionLedgerError.unsafePath }
        defer { Darwin.close(fd) }
        guard privateFile(fd) else { throw LidSessionLedgerError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LidSessionLedgerError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func privateFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG &&
            info.st_mode & 0o077 == 0 && info.st_nlink == 1
    }
    private func readRecord() throws -> Record? {
        let fd = openat(directory, Self.recordName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw LidSessionLedgerError.unsafePath }
        defer { Darwin.close(fd) }
        var info = stat()
        guard privateFile(fd), fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= Self.maximumBytes else {
            throw LidSessionLedgerError.unsafePath
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw LidSessionLedgerError.io }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= Self.maximumBytes else { throw LidSessionLedgerError.invalidRecord }
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
              record.identity.isValid, validTime(record.enabledIntentAt), validTime(record.updatedAt),
              record.updatedAt >= record.enabledIntentAt, (record.reason?.utf8.count ?? 0) <= 1024,
              record.cleanupAttemptedAt.map({ validTime($0) && $0 >= record.enabledIntentAt && $0 <= record.updatedAt }) ?? true,
              ![.cleanupAttempted, .cleanupAccepted, .cleanupFailed].contains(record.stage) || record.cleanupAttemptedAt != nil,
              record.cleanupResult == nil || record.cleanupAttemptedAt != nil,
              record.stage != .enableIntent || record.enableResult == nil,
              ![.enableIntent, .enabled, .enableFailed].contains(record.stage) || record.cleanupAttemptedAt == nil,
              record.stage != .cleanupAttempted || record.cleanupResult == nil,
              record.stage != .cleanupAccepted || record.cleanupResult?.succeeded == true,
              record.stage != .cleanupFailed || record.cleanupResult?.succeeded == false,
              record.stage != .enabled || record.enableResult?.succeeded == true,
              record.stage != .enableFailed || record.enableResult?.succeeded == false else {
            throw LidSessionLedgerError.invalidRecord
        }
        return record
    }
    private func writeRecord(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumBytes else { throw LidSessionLedgerError.invalidRecord }
        let temporary = ".lid-ledger-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LidSessionLedgerError.io }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LidSessionLedgerError.io }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, Self.recordName) == 0,
              fsync(directory) == 0 else { throw LidSessionLedgerError.io }
    }
}
