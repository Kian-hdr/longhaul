import Foundation
import CryptoKit
import LonghaulCore
import Darwin

public struct Mailbox: Sendable {
    public let root: URL
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Longhaul", isDirectory: true)
    }
    public init(root: URL = Self.defaultRoot) throws {
        self.root = root
        try Self.secureDirectory(root)
        for folder in ["events", "requests", "receipts", "recovery"] { try Self.secureDirectory(root.appendingPathComponent(folder, isDirectory: true)) }
    }
    private static func secureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw BridgeError.unsafePath }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public static func key(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public func write<T: Encodable>(_ value: T, folder: String, key: String) throws {
        guard ["events", "requests", "receipts", "recovery"].contains(folder) else { throw BridgeError.unsafePath }
        let bytes = try Self.encoder().encode(value)
        guard bytes.count <= 65_536 else { throw BridgeError.tooLarge }
        let url = root.appendingPathComponent(folder).appendingPathComponent(Self.key(key) + ".json")
        // These private lifecycle records must remain reopenable by independent
        // workers while the screen is locked. An unless-open protection class
        // denies fresh opens in that state, even to the writer's own UID.
        // Keep atomic replacement, private directory/file modes and the system's
        // ordinary filesystem protection; do not opt these records into that class.
        try bytes.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func emit(_ event: JobEvent) throws {
        try emit(event, hookStop: nil)
    }
    /// Only real hook observations use this path. A Stop hook is provisional:
    /// another hook can continue the same Codex turn. Heartbeats and generic
    /// producers cannot reopen it, and cancellation/session end remains final.
    public func emitHook(_ event: JobEvent, isStop: Bool = false) throws {
        guard !isStop || event.phase == .completed else { throw BridgeError.invalidEvent }
        try emit(event, hookStop: isStop)
    }
    private struct HookObservation: Codable {
        var session: String
        var observedSequence: Int
        var publishedSequence: Int
        var softStop: Bool
    }
    private func emit(_ event: JobEvent, hookStop: Bool?) throws {
        guard event.isValid else { throw BridgeError.invalidEvent }
        try withEventLock(event.source + ":" + event.id) {
            var accepted = event
            accepted.continuableHookStop = nil
            let hookKey = "hook-observation:" + event.source + ":" + event.id
            let hookURL = root.appendingPathComponent("recovery").appendingPathComponent(Self.key(hookKey) + ".json")
            let observation = hookStop != nil && FileManager.default.fileExists(atPath: hookURL.path)
                ? try read(HookObservation.self, at: hookURL) : nil
            let metadataKey = "incarnations:" + event.source + ":" + event.id
            let metadataURL = root.appendingPathComponent("recovery").appendingPathComponent(Self.key(metadataKey) + ".json")
            var retired = FileManager.default.fileExists(atPath: metadataURL.path) ? try read([String].self, at: metadataURL) : []
            guard !retired.contains(event.session) else { return }
            if let previous = try? read(JobEvent.self, at: eventURL(event.source + ":" + event.id)) {
              if previous.session == event.session {
                if hookStop != nil {
                    // Worker sequence increments are not lifecycle observations.
                    // Compare real hooks independently, then publish a monotonically
                    // increasing event sequence for the policy reader.
                    let lastHook = observation?.session == event.session ? observation : nil
                    guard event.sequence > (lastHook?.observedSequence ?? previous.sequence) else { return }
                    if previous.phase.isTerminal {
                        guard previous.phase == .completed, lastHook?.softStop == true,
                              lastHook?.publishedSequence == previous.sequence else { return }
                    }
                    accepted.sequence = max(previous.sequence + 1, event.sequence)
                    if !event.phase.isTerminal {
                        accepted.continuableHookStop = previous.continuableHookStop
                    }
                } else if event.phase.isTerminal && !previous.phase.isTerminal {
                    accepted.sequence = max(previous.sequence + 1, event.sequence)
                } else {
                    guard event.sequence > previous.sequence, !previous.phase.isTerminal || event.phase.isTerminal else { return }
                }
              } else {
                // Refuse further reuse instead of evicting a guard and allowing old writers to return.
                guard retired.count < 256 else { throw BridgeError.invalidEvent }
                retired.append(previous.session)
                try write(retired, folder: "recovery", key: metadataKey)
              }
            }
            if hookStop == true { accepted.continuableHookStop = accepted.sequence }
            try write(accepted, folder: "events", key: event.source + ":" + event.id)
            if let hookStop {
                // Persist only after the event. A crash between these writes leaves
                // no matching soft-stop receipt and therefore cannot reopen work.
                try write(HookObservation(session: event.session, observedSequence: event.sequence,
                                          publishedSequence: accepted.sequence, softStop: hookStop),
                          folder: "recovery", key: hookKey)
            }
        }
    }
    public func eventURL(_ key: String) -> URL { root.appendingPathComponent("events").appendingPathComponent(Self.key(key) + ".json") }
    public func heartbeat(key: String, session: String) throws -> Bool {
        try withEventLock(key) {
            var e = try read(JobEvent.self, at: eventURL(key))
            guard e.session == session, !e.phase.isTerminal else { return false }
            e.sequence += 1
            try write(e, folder: "events", key: key)
            return true
        }
    }
    private func withEventLock<T>(_ key: String, body: () throws -> T) throws -> T {
        let path = root.appendingPathComponent("events").appendingPathComponent("." + Self.key(key) + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError.unsafePath }; defer { Darwin.close(fd) }
        var s = stat(); guard fstat(fd, &s) == 0, s.st_uid == getuid(), (s.st_mode & S_IFMT) == S_IFREG else { throw BridgeError.unsafePath }
        var acquired = false
        for _ in 0..<50 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            guard errno == EWOULDBLOCK else { throw BridgeError.unsafePath }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard acquired else { throw BridgeError.lockTimeout }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public func files(in folder: String) throws -> [URL] {
        guard ["events", "requests", "receipts", "recovery"].contains(folder) else { throw BridgeError.unsafePath }
        let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(1000).map(\.0)
    }
    public func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeError.unsafePath }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 65_536 else { throw BridgeError.unsafePath }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw BridgeError.invalidEvent }
        return try Self.decoder().decode(type, from: data)
    }
    public func requests(for event: JobEvent) throws -> [CheckpointRequest] {
        try files(in: "requests").compactMap { url in
            guard let request = try? read(CheckpointRequest.self, at: url), request.jobID == event.id,
                  request.source == event.source, request.session == event.session, request.deadline > Date() else { return nil }
            return request
        }
    }
    public enum BridgeError: Error { case unsafePath, tooLarge, invalidEvent, lockTimeout }
}
