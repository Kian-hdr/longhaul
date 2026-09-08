import Foundation
import Darwin

/// The caller must prove on every poll that this exact live process incarnation
/// has the supplied rollout file open for writing. Birth is epoch microseconds,
/// matching ProcessIdentity.birth; an open Codex app alone is insufficient.
public struct CodexRolloutWriter: Sendable, Equatable {
    public let pid: Int32
    public let birth: UInt64
    public init(pid: Int32, birth: UInt64) { self.pid = pid; self.birth = birth }
}

public struct CodexRolloutActivity: Sendable, Equatable {
    public enum State: String, Sendable { case running, completed, cancelled, unknown, catchingUp }
    public enum Reason: String, Sendable {
        case invalidWriter, invalidLimits, unsafeFile, fileTooLarge, fileChanged, readFailed
        case malformedRecord, oversizedRecord, unsupportedFormat, unsupportedOrigin, missingMetadata
        case invalidMetadata, invalidLifecycle, invalidTimestamp, predatesWriter, noTask, partialRecord, tooManyTurns
    }
    public let state: State
    public let threadID: String?
    public let turnID: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let reason: Reason?
    public let bytesRead: Int
    public let inspectedDevice: UInt64?
    public let inspectedInode: UInt64?
}

/// Incremental, metadata-only reader for the explicitly qualified rollout format.
/// No message text, role, prompt, arbitrary JSON, or raw partial line survives a
/// poll. Only bounded JSON grammar state and selected metadata are retained. One scanner belongs to one URL.
/// File replacement/truncation or malformed data latches unknown until reset;
/// reset is appropriate only after the caller revalidates the writer and file.
public struct CodexRolloutActivityScanner: Sendable {
    public static let supportedCLIVersion = "0.153.4"
    public static let defaultMaximumLineBytes = 1_048_576
    public static let defaultReadBudgetBytes = 4_194_304
    public static let defaultMaximumFileBytes = 268_435_456
    private let maximumLineBytes: Int
    private let readBudgetBytes: Int
    private let maximumFileBytes: Int
    private var stream: CodexRolloutJSONStream
    var retainedMetadataBytes: Int { stream.retainedMetadataBytes }
    private var writer: CodexRolloutWriter?
    private var file: FileIdentity?
    private var offset = 0
    private var observedSize = 0
    private var threadID: String?
    private var turnID: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var taskState: CodexRolloutActivity.State = .unknown
    private var taskReason: CodexRolloutActivity.Reason? = .noTask
    private var terminal = false
    private var seenTurns: Set<String> = []
    private var terminalTurns: Set<String> = []
    private var failure: CodexRolloutActivity.Reason?
    public var hasLatchedFailure: Bool { failure != nil }
    /// Call only after a successful current file/writer observation. This keeps
    /// a terminal followed by a new start in one poll from losing its evidence.
    public func hasObservedTerminal(turnID: String) -> Bool {
        failure == nil && terminalTurns.contains(turnID)
    }

    /// `maximumLineBytes` is retained for source compatibility and now bounds
    /// captured metadata strings (also capped at 4 KiB), not discarded payloads.
    public init(maximumLineBytes: Int = Self.defaultMaximumLineBytes,
                readBudgetBytes: Int = Self.defaultReadBudgetBytes,
                maximumFileBytes: Int = Self.defaultMaximumFileBytes) {
        self.maximumLineBytes = maximumLineBytes; self.readBudgetBytes = readBudgetBytes
        self.maximumFileBytes = maximumFileBytes
        self.stream = CodexRolloutJSONStream(maximumMetadataBytes: maximumLineBytes)
    }
    public mutating func reset() {
        writer = nil; file = nil; offset = 0; observedSize = 0; threadID = nil; turnID = nil
        startedAt = nil; updatedAt = nil; taskState = .unknown; taskReason = .noTask
        terminal = false; seenTurns = []; terminalTurns = []; failure = nil
        stream = CodexRolloutJSONStream(maximumMetadataBytes: maximumLineBytes)
    }

    public mutating func poll(url: URL, writer currentWriter: CodexRolloutWriter,
                              expectedDevice: UInt64? = nil, expectedInode: UInt64? = nil,
                              now: Date = Date()) -> CodexRolloutActivity {
        poll(url: url, writer: currentWriter, expectedDevice: expectedDevice, expectedInode: expectedInode,
             now: now, observationClock: LidQualificationIO.monotonicSeconds)
    }

    /// Synchronous clock seam for deterministic observation-window tests. The
    /// public API always measures real continuous elapsed time during this poll.
    mutating func poll(url: URL, writer currentWriter: CodexRolloutWriter,
                       expectedDevice: UInt64? = nil, expectedInode: UInt64? = nil,
                       now: Date, observationClock: () -> Double) -> CodexRolloutActivity {
        let pollStarted = observationClock()
        let epoch = now.timeIntervalSince1970
        guard pollStarted.isFinite, pollStarted >= 0, currentWriter.pid > 1, currentWriter.birth > 0, epoch.isFinite,
              epoch >= Double(currentWriter.birth) / 1_000_000 else { return fail(.invalidWriter) }
        if writer != currentWriter { reset(); writer = currentWriter }
        guard maximumLineBytes > 0, maximumLineBytes <= Self.defaultMaximumLineBytes,
              readBudgetBytes > maximumLineBytes, readBudgetBytes <= Self.defaultReadBudgetBytes,
              maximumFileBytes > 0, maximumFileBytes <= Self.defaultMaximumFileBytes else { return fail(.invalidLimits) }
        if let failure { return snapshot(.unknown, reason: failure) }
        guard url.isFileURL, url.path.hasPrefix("/") else { return fail(.unsafeFile) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return fail(.unsafeFile) }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, Self.safe(before) else { return fail(.unsafeFile) }
        guard before.st_size >= 0, before.st_size <= maximumFileBytes else { return fail(.fileTooLarge) }
        let identity = FileIdentity(before)
        guard expectedDevice.map({ $0 == identity.device }) ?? true,
              expectedInode.map({ $0 == identity.inode }) ?? true else { return fail(.fileChanged) }
        if let file, file != identity { return fail(.fileChanged) }
        guard before.st_size >= observedSize, before.st_size >= offset else { return fail(.fileChanged) }
        file = identity
        let targetSize = Int(before.st_size)
        observedSize = targetSize
        let requested = min(readBudgetBytes, targetSize - offset)
        var bytes = [UInt8](repeating: 0, count: requested)
        var count = 0
        while count < requested {
            let amount = bytes.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress!.advanced(by: count), requested - count, off_t(offset + count))
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { return fail(.readFailed, bytesRead: count) }
            count += amount
        }
        for byte in bytes {
            do {
                guard let projected = try stream.feed(byte) else { continue }
                let record = try MetadataRecord(projected)
                let elapsed = observationClock() - pollStarted
                guard elapsed.isFinite, elapsed >= 0, (epoch + elapsed).isFinite else { return fail(.invalidTimestamp, bytesRead: count) }
                if let reason = consume(record, writer: currentWriter, now: now.addingTimeInterval(elapsed)) {
                    return fail(reason, bytesRead: count)
                }
            } catch { return fail(.malformedRecord, bytesRead: count) }
        }
        offset += count
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0, Self.safe(after), Self.safe(path) else {
            return fail(.unsafeFile, bytesRead: count)
        }
        guard FileIdentity(after) == identity, FileIdentity(path) == identity,
              after.st_size >= targetSize, path.st_size >= targetSize else { return fail(.fileChanged, bytesRead: count) }
        guard after.st_size <= maximumFileBytes, path.st_size <= maximumFileBytes else { return fail(.fileTooLarge, bytesRead: count) }
        observedSize = Int(max(after.st_size, path.st_size))
        guard offset == observedSize, !stream.hasPartialRecord else {
            return snapshot(.catchingUp, reason: offset == observedSize && stream.hasPartialRecord ? .partialRecord : nil, bytesRead: count)
        }
        guard threadID != nil else { return snapshot(.unknown, reason: .missingMetadata, bytesRead: count) }
        return snapshot(taskState, reason: taskReason, bytesRead: count)
    }

    private mutating func consume(_ record: MetadataRecord, writer: CodexRolloutWriter, now: Date) -> CodexRolloutActivity.Reason? {
        switch record {
        case .header(let metadata):
            guard threadID == nil else { return .invalidMetadata }
            guard metadata.cliVersion == Self.supportedCLIVersion else { return .unsupportedFormat }
            guard metadata.originator == "Codex Desktop", metadata.source == "vscode" else { return .unsupportedOrigin }
            guard UUID(uuidString: metadata.id) != nil else { return .invalidMetadata }
            threadID = metadata.id
        case .event(let type, let id, let stamp):
            guard threadID != nil else { return .missingMetadata }
            guard ["task_started", "task_complete", "turn_aborted"].contains(type) else { return nil }
            guard let id, UUID(uuidString: id) != nil else { return .invalidLifecycle }
            guard let stamp, let date = Self.timestamp(stamp), date.timeIntervalSince1970 >= 0, date <= now else { return .invalidTimestamp }
            if type == "task_started" {
                guard !seenTurns.contains(id) else { return nil }
                guard seenTurns.count < 65_536 else { return .tooManyTurns }
                seenTurns.insert(id)
                if let updatedAt, date < updatedAt { return .invalidTimestamp }
                turnID = id; startedAt = date; updatedAt = date; terminal = false
                if date.timeIntervalSince1970 < Double(writer.birth) / 1_000_000 {
                    taskState = .unknown; taskReason = .predatesWriter
                } else { taskState = .running; taskReason = nil }
            } else {
                if !seenTurns.contains(id) {
                    guard seenTurns.count < 65_536 else { return .tooManyTurns }; seenTurns.insert(id)
                }
                guard id == turnID, !terminal else { return nil }
                guard let startedAt, date >= startedAt else { return .invalidTimestamp }
                terminalTurns.insert(id)
                taskState = type == "task_complete" ? .completed : .cancelled
                taskReason = nil; updatedAt = date; terminal = true
            }
        case .ignored:
            guard threadID != nil else { return .missingMetadata }
        }
        return nil
    }
    private mutating func fail(_ reason: CodexRolloutActivity.Reason, bytesRead: Int = 0) -> CodexRolloutActivity {
        failure = reason; return snapshot(.unknown, reason: reason, bytesRead: bytesRead)
    }
    private func snapshot(_ state: CodexRolloutActivity.State, reason: CodexRolloutActivity.Reason?, bytesRead: Int = 0) -> CodexRolloutActivity {
        .init(state: state, threadID: threadID, turnID: turnID, startedAt: startedAt, updatedAt: updatedAt,
              reason: reason, bytesRead: bytesRead, inspectedDevice: file?.device, inspectedInode: file?.inode)
    }
    private static func safe(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o022 == 0 && info.st_nlink == 1
    }
    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int
        let birthNanoseconds: Int
        init(_ info: stat) {
            device = UInt64(UInt32(bitPattern: info.st_dev)); inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
    private static func timestamp(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }
    private struct Header: Decodable {
        let id: String
        let originator: String
        let source: String
        let cliVersion: String
        enum CodingKeys: String, CodingKey { case id, originator, source; case cliVersion = "cli_version" }
    }
    private enum MetadataRecord {
        case header(Header), event(String, String?, String?), ignored
        init(_ record: CodexRolloutJSONStream.Record) throws {
            guard let type = record.string(.type) else { throw CodexRolloutJSONStream.Invalid.syntax }
            switch type {
            case "session_meta":
                guard case .object = record.values[.payload],
                      let id = record.string(.id), let originator = record.string(.originator),
                      let source = record.string(.source), let version = record.string(.cliVersion) else {
                    throw CodexRolloutJSONStream.Invalid.syntax
                }
                self = .header(Header(id: id, originator: originator, source: source, cliVersion: version))
            case "event_msg":
                guard case .object = record.values[.payload], let event = record.string(.eventType) else {
                    throw CodexRolloutJSONStream.Invalid.syntax
                }
                self = ["task_started", "task_complete", "turn_aborted"].contains(event) ?
                    .event(event, record.string(.turnID), record.string(.timestamp)) : .ignored
            default: self = .ignored
            }
        }
    }
}
