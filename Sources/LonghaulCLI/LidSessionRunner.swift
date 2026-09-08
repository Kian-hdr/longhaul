import Foundation
import Darwin
import LonghaulBridge
import LonghaulCore

/// One policy-admitted hold. The app is the sole lease producer; neither helper
/// renews policy from its own timer. The watchdog is the sole enable writer.
enum LidSessionRunner {
    static let watchdogCommand = "lid-session-watchdog"
    typealias IO = LidProbeRunner
    struct Wire: Codable {
        var version = 1
        var kind: String
        var token: String
        var time: Double
        var pid: Int32?
        var birth: UInt64?
        var parentPID: Int32?
        var parentBirth: UInt64?
        var directory: String?
        var lockRoot: String?
        var grant: LidSessionGrant?
        var backend: LidMutationResult?
        var cleaned: Bool?
        var reason: String?
        var priorCleanup: LidSessionLedger.Record?
    }
    static func alive(_ identity: LidSessionIdentity) -> Bool {
        ProcessIdentity.isSame(pid: identity.appPID, birth: identity.appBirth)
    }
    static func operatingSafe(_ snapshot: IO.Sample, policy: LidBatteryPolicy) -> Bool {
        snapshot.powerKnown && snapshot.ownerScanComplete && snapshot.knownOwners.isEmpty &&
            snapshot.power.supportsClosedLidWork(policy: policy)
    }
    static func safe(_ snapshot: IO.Sample, policy: LidBatteryPolicy) -> Bool {
        let registry = snapshot.inspection.snapshot
        return snapshot.fresh(at: IO.clock()) && snapshot.inspection.serviceAccessSucceeded &&
            operatingSafe(snapshot, policy: policy) && registry.policySnapshotKnown &&
            registry.sleepDisabled == false && !(registry.lidClosed == true && registry.clamshellCausesSleep == true)
    }
    /// A stale false publication can be admitted only after this process itself
    /// read the previous same-boot successful cleanup under both lifetime locks.
    /// The caller must compare the peer's baseline with its own secure ledger read.
    static func startupSafe(_ snapshot: IO.Sample, policy: LidBatteryPolicy, priorCleanup: LidSessionLedger.Record?, bootID: String) -> Bool {
        guard snapshot.fresh(at: IO.clock()) else { return false }
        if snapshot.inspection.serviceAccessSucceeded && snapshot.inspection.snapshot.normalOpenLidPolicy && operatingSafe(snapshot, policy: policy) { return true }
        let registry = snapshot.inspection.snapshot
        return snapshot.inspection.serviceAccessSucceeded && operatingSafe(snapshot, policy: policy) &&
            registry.lidClosed == false && registry.sleepDisabled == false && registry.clamshellCausesSleep == false &&
            priorCleanup?.identity.bootID == bootID && priorCleanup?.stage == .cleanupAccepted &&
            priorCleanup?.cleanupResult?.succeeded == true
    }
    static func conflict(_ snapshot: IO.Sample, journal: IO.Journal) throws -> Bool {
        if !snapshot.ownerScanComplete || !snapshot.knownOwners.isEmpty {
            try journal.markOwnerConflict(); return true
        }
        return false
    }
    static func run(arguments: [String], box: Mailbox) -> Int32 {
        guard arguments.isEmpty, IO.descriptor(0, type: S_IFIFO), IO.descriptor(1, type: S_IFIFO) else { return 2 }
        let appPID = getppid(), appBirth = ProcessIdentity.birth(getppid())
        guard appPID > 1, appBirth != 0 else { return 2 }
        var app: Channel<LidSessionGrant>?
        var peer: Channel<Wire>?
        var child: Process?
        var childBirth: UInt64 = 0
        var identity: LidSessionIdentity?
        var lease: LidSessionLease?
        var journal: IO.Journal?
        var ledger: LidSessionLedger?
        var lock: Int32 = -1
        var authorizedEnable = false
        var reportSequence: UInt64 = 0
        var token = ""
        var lastPeer = IO.clock(), lastPeerStamp: Double = 0
        var inbound: Pipe?, outbound: Pipe?
        defer {
            try? inbound?.fileHandleForWriting.close(); try? outbound?.fileHandleForReading.close()
            if lock >= 0 { Darwin.close(lock) }
        }
        func report(_ state: LidSessionStatus.State, reason: String? = nil) throws {
            guard let identity, let app else { return }
            reportSequence += 1
            try app.send(LidSessionStatus(identity: identity, sequence: reportSequence, observedAt: IO.clock(),
                                          state: state, reason: reason, leaseExpiresAt: lease?.expiresAt))
        }
        func finish(_ reason: String) -> Int32 {
            try? report(.stopping, reason: reason)
            if let peer { try? peer.send(Wire(kind: "stop", token: token, time: IO.clock(), reason: reason)) }
            // Give the watchdog its peer-lease interval to finish its one clear.
            let deadline = IO.clock() + IO.peerLease
            if let peer, let child {
                while IO.clock() < deadline && ProcessIdentity.isSame(pid: child.processIdentifier, birth: childBirth) {
                    do {
                        let messages = try peer.available()
                        if messages.contains(where: { $0.kind == "done" && $0.token == token }) { break }
                    } catch { break }
                    IO.pause(0.02)
                }
            }
            let stopped = child.map { IO.stopAndConfirm($0, birth: childBirth) } ?? true
            var cleaned: Bool
            if authorizedEnable, stopped, let journal {
                cleaned = IO.qualifiedCleanup(journal: journal, mayHaveEnabled: true, ledger: ledger, identity: identity)
            } else { cleaned = !authorizedEnable }
            let final = IO.sample()
            if authorizedEnable && (!final.fresh(at: IO.clock()) || !final.inspection.serviceAccessSucceeded ||
                !final.inspection.snapshot.policySnapshotKnown ||
                !final.ownerScanComplete || !final.knownOwners.isEmpty) { cleaned = false }
            if !cleaned, let ledger, let identity {
                try? ledger.markUnresolved(identity: identity, reason: "Session stopped without confirmed cleanup: " + reason, at: IO.clock())
            }
            try? journal?.record("session-finished", note: reason, cleanupRequired: !cleaned, sync: true)
            try? journal?.record("final-observation", sample: final, cleanupRequired: !cleaned, sync: true)
            try? report(cleaned ? .stopped : .cleanupRequired, reason: reason)
            return cleaned ? 0 : 3
        }
        do {
            let appChannel = try Channel<LidSessionGrant>(readFD: 0, writeFD: 1); app = appChannel
            let first = try appChannel.next(until: IO.clock() + IO.peerLease)
            identity = first.identity
            guard first.identity.appPID == appPID, first.identity.appBirth == appBirth,
                  first.identity.bootID == (try LidSessionLedger.currentBootID()), first.kind == .renew else { throw IO.ProbeError.protocolFailure }
            var initialLease = LidSessionLease(identity: first.identity)
            guard initialLease.accept(first, now: IO.clock(), appAlive: alive(first.identity)),
                  let initialPolicy = initialLease.batteryPolicy else { throw IO.ProbeError.protocolFailure }
            lease = initialLease
            #if LONGHAUL_LID_PROBE_TESTING
            let globalRoot = box.root
            #else
            let globalRoot = try Mailbox().root
            #endif
            lock = try IO.lockProbe(in: globalRoot)
            let otherLock = try IO.lockProbe(in: globalRoot, name: ".lid-watchdog.lock"); Darwin.close(otherLock)
            let interlock = try LidSessionLedger(root: globalRoot); ledger = interlock
            try IO.requireAdmission(interlock)
            let baseline = try interlock.currentRecord()
            let before = IO.sample()
            guard startupSafe(before, policy: initialPolicy, priorCleanup: baseline, bootID: first.identity.bootID) else { throw IO.ProbeError.refused("Startup requires open lid, normal policy, valid battery policy, nominal thermal state and no known co-owner.") }
            let directory = try IO.newDirectory(in: box.root)
            let log = try IO.Journal(directory: directory, role: "monitor"); journal = log
            try log.record("initial", sample: before, sync: true)
            try log.record("app-policy", grant: first, sync: true)
            try report(.starting)
            let input = Pipe(), output = Pipe(); inbound = input; outbound = output
            let task = Process(); child = task
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            task.arguments = [watchdogCommand]
            task.standardInput = input; task.standardOutput = output
            task.standardError = FileHandle(fileDescriptor: lock, closeOnDealloc: false)
            try task.run()
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            let channel = try Channel<Wire>(readFD: output.fileHandleForReading.fileDescriptor, writeFD: input.fileHandleForWriting.fileDescriptor); peer = channel
            childBirth = ProcessIdentity.birth(task.processIdentifier)
            let birth = ProcessIdentity.birth(getpid())
            guard childBirth != 0, birth != 0 else { throw IO.ProbeError.protocolFailure }
            token = UUID().uuidString
            try channel.send(Wire(kind: "authorize", token: token, time: IO.clock(), pid: task.processIdentifier,
                                  birth: childBirth, parentPID: getpid(), parentBirth: birth,
                                  directory: directory.path, lockRoot: globalRoot.path, grant: first, priorCleanup: baseline))
            let ready = try channel.next(until: IO.clock() + IO.peerLease)
            guard valid(ready, token: token, pid: task.processIdentifier, birth: childBirth), ready.kind == "ready",
                  lease?.isAuthorized(at: IO.clock()) == true, alive(first.identity),
                  try interlock.currentRecord() == baseline,
                  startupSafe(IO.sample(), policy: initialPolicy, priorCleanup: baseline, bootID: first.identity.bootID) else { throw IO.ProbeError.protocolFailure }
            try interlock.beginEnable(identity: first.identity, at: IO.clock())
            authorizedEnable = true
            try log.record("enable-may-be-attempted", sync: true)
            try channel.send(Wire(kind: "enable", token: token, time: IO.clock()))
            lastPeer = IO.clock(); lastPeerStamp = ready.time
            var active = false, lastReport: Double = 0, lastLog: Double = 0
            while true {
                // Read a final response before testing liveness or sending more data.
                for message in try channel.available() {
                    guard valid(message, token: token, pid: task.processIdentifier, birth: childBirth),
                          message.time >= lastPeerStamp, IO.clock() - message.time <= IO.peerLease else { throw IO.ProbeError.protocolFailure }
                    lastPeer = IO.clock(); lastPeerStamp = message.time
                    if message.kind == "done" { return finish(message.reason ?? "Watchdog stopped.") }
                    if message.kind == "enabled" {
                        guard message.backend?.succeeded == true else { return finish("Enable call failed.") }
                        active = true
                    }
                }
                for grant in try appChannel.available() {
                    guard lease?.accept(grant, now: IO.clock(), appAlive: alive(first.identity)) == true else {
                        return finish("Invalid or expired policy grant.")
                    }
                    try log.record("app-policy", grant: grant)
                    // Forward the exact app-authored timestamps and sequence.
                    try channel.send(Wire(kind: "policy", token: token, time: IO.clock(), grant: grant))
                    if grant.kind == .revoke { return finish("App policy revoked the hold.") }
                }
                guard alive(first.identity) else { return finish("Original app process ended.") }
                guard lease?.isAuthorized(at: IO.clock()) == true else { return finish("Original policy lease expired.") }
                guard ProcessIdentity.isSame(pid: task.processIdentifier, birth: childBirth), IO.clock() - lastPeer <= IO.peerLease else {
                    return finish("Watchdog unavailable.")
                }
                let snapshot = IO.sample()
                if IO.clock() - lastLog >= 5 { try log.record("heartbeat", sample: snapshot); lastLog = IO.clock() }
                if try conflict(snapshot, journal: log) { return finish("Co-owner state changed.") }
                guard let policy = lease?.batteryPolicy, safe(snapshot, policy: policy) else { return finish("Power, thermal or clamshell policy changed.") }
                try channel.send(Wire(kind: "heartbeat", token: token, time: IO.clock()))
                if active && IO.clock() - lastReport >= 1 { try report(.active); lastReport = IO.clock() }
                IO.pause(0.25)
            }
        } catch {
            if authorizedEnable { return finish("Monitor stopped: " + String(describing: error)) }
            _ = child.map { IO.stopAndConfirm($0, birth: childBirth) }
            var state: LidSessionStatus.State = .unavailable
            if let ledger, let boot = LidSessionIdentity.currentBootID(),
               case .blocked = try? ledger.admission(currentBootID: boot) { state = .cleanupRequired }
            try? report(state, reason: String(describing: error))
            return 2
        }
    }

    static func watchdog(arguments: [String]) -> Int32 {
        guard arguments.isEmpty, IO.descriptor(0, type: S_IFIFO), IO.descriptor(1, type: S_IFIFO),
              IO.descriptor(2, type: S_IFREG, privateOwned: true), flock(2, LOCK_EX | LOCK_NB) == 0 else { return 2 }
        let parent = getppid(), parentBirth = ProcessIdentity.birth(getppid()), me = getpid(), birth = ProcessIdentity.birth(getpid())
        guard parent > 1, parentBirth != 0, birth != 0 else { return 2 }
        _ = signal(SIGHUP, SIG_IGN)
        if getpgrp() == me && getsid(0) != me {
            let group = getpgid(parent)
            guard group > 0, setpgid(0, group) == 0 else { return 2 }
        }
        guard setsid() >= 0 || getsid(0) == me else { return 2 }
        guard getpgrp() != getpgid(parent), getsid(0) == me else { return 2 }
        var channel: Channel<Wire>?
        var journal: IO.Journal?
        var ledger: LidSessionLedger?
        var identity: LidSessionIdentity?
        var lease: LidSessionLease?
        var token = "", lock: Int32 = -1
        var mayHaveEnabled = false
        defer { if lock >= 0 { Darwin.close(lock) } }
        func finish(_ reason: String) -> Int32 {
            let cleaned = journal.map { IO.qualifiedCleanup(journal: $0, mayHaveEnabled: mayHaveEnabled, ledger: ledger, identity: identity) } ?? !mayHaveEnabled
            try? journal?.record("watchdog-finished", note: reason, cleanupRequired: !cleaned, sync: true)
            try? channel?.send(Wire(kind: "done", token: token, time: IO.clock(), pid: me, birth: birth, cleaned: cleaned, reason: reason))
            return cleaned ? 0 : 3
        }
        do {
            let transport = try Channel<Wire>(readFD: 0, writeFD: 1); channel = transport
            let auth = try transport.next(until: IO.clock() + IO.peerLease)
            guard auth.version == 1, auth.kind == "authorize", UUID(uuidString: auth.token) != nil,
                  auth.pid == me, auth.birth == birth, auth.parentPID == parent, auth.parentBirth == parentBirth,
                  auth.time.isFinite, auth.time <= IO.clock(), IO.clock() - auth.time <= IO.peerLease,
                  let first = auth.grant, first.kind == .renew,
                  first.identity.bootID == (try LidSessionLedger.currentBootID()), alive(first.identity),
                  let directory = auth.directory, directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4096,
                  URL(fileURLWithPath: directory).lastPathComponent.hasPrefix("lid-probe-"),
                  let root = auth.lockRoot, root.hasPrefix("/"), !root.contains("\0"), root.utf8.count <= 4096 else { throw IO.ProbeError.protocolFailure }
            token = auth.token; identity = first.identity
            var initialLease = LidSessionLease(identity: first.identity)
            guard initialLease.accept(first, now: IO.clock(), appAlive: alive(first.identity)),
                  let initialPolicy = initialLease.batteryPolicy else { throw IO.ProbeError.protocolFailure }
            lease = initialLease
            lock = try IO.lockProbe(in: URL(fileURLWithPath: root), name: ".lid-watchdog.lock")
            let interlock = try LidSessionLedger(root: URL(fileURLWithPath: root)); ledger = interlock
            let baseline = try interlock.currentRecord()
            guard baseline == auth.priorCleanup,
                  try interlock.admission(currentBootID: first.identity.bootID) == .available else { throw IO.ProbeError.protocolFailure }
            let log = try IO.Journal(directory: URL(fileURLWithPath: directory), role: "watchdog"); journal = log
            let before = IO.sample()
            guard startupSafe(before, policy: initialPolicy, priorCleanup: baseline, bootID: first.identity.bootID) else { throw IO.ProbeError.refused("Watchdog startup conditions changed.") }
            try log.record("initial", sample: before, sync: true)
            try log.record("app-policy", grant: first, sync: true)
            try transport.send(Wire(kind: "ready", token: token, time: IO.clock(), pid: me, birth: birth))
            let enable = try transport.next(until: IO.clock() + IO.peerLease)
            guard validParent(enable, token: token), enable.kind == "enable",
                  ProcessIdentity.isSame(pid: parent, birth: parentBirth), alive(first.identity),
                  lease?.isAuthorized(at: IO.clock()) == true,
                  startupSafe(IO.sample(), policy: initialPolicy, priorCleanup: baseline, bootID: first.identity.bootID),
                  case .blocked(let record) = try interlock.admission(currentBootID: first.identity.bootID),
                  record.identity == first.identity, record.stage == .enableIntent else { throw IO.ProbeError.protocolFailure }
            try log.record("enable-intent", sync: true)
            mayHaveEnabled = true
            let enabled = IO.mutate(true)
            try log.record("enable-result", backend: enabled, sync: true)
            try interlock.recordEnableResult(identity: first.identity, result: enabled, at: IO.clock())
            try transport.send(Wire(kind: "enabled", token: token, time: IO.clock(), pid: me, birth: birth, backend: enabled))
            guard enabled.succeeded else { return finish("Enable call failed.") }
            var lastParent = IO.clock(), lastStamp = enable.time, lastLog: Double = 0
            while true {
                for message in try transport.available() {
                    guard validParent(message, token: token), message.time >= lastStamp else { throw IO.ProbeError.protocolFailure }
                    lastParent = IO.clock(); lastStamp = message.time
                    switch message.kind {
                    case "stop": return finish(message.reason ?? "Monitor revoked hold.")
                    case "heartbeat": break
                    case "policy":
                        guard let grant = message.grant, lease?.accept(grant, now: IO.clock(), appAlive: alive(first.identity)) == true else {
                            return finish("Invalid or expired forwarded policy grant.")
                        }
                        try log.record("app-policy", grant: grant)
                        if grant.kind == .revoke { return finish("Original app policy revoked hold.") }
                    default: throw IO.ProbeError.protocolFailure
                    }
                }
                guard alive(first.identity) else { return finish("Original app process ended.") }
                guard lease?.isAuthorized(at: IO.clock()) == true else { return finish("Original policy lease expired.") }
                guard ProcessIdentity.isSame(pid: parent, birth: parentBirth), IO.clock() - lastParent <= IO.peerLease else {
                    return finish("Monitor unavailable.")
                }
                let snapshot = IO.sample()
                if IO.clock() - lastLog >= 5 { try log.record("heartbeat", sample: snapshot); lastLog = IO.clock() }
                if try conflict(snapshot, journal: log) { return finish("Co-owner state changed.") }
                guard let policy = lease?.batteryPolicy, safe(snapshot, policy: policy) else { return finish("Power, thermal or clamshell policy changed.") }
                try transport.send(Wire(kind: "heartbeat", token: token, time: IO.clock(), pid: me, birth: birth))
                IO.pause(0.25)
            }
        } catch { return finish("Watchdog stopped: " + String(describing: error)) }
    }
    static func valid(_ wire: Wire, token: String, pid: Int32, birth: UInt64) -> Bool {
        wire.version == 1 && wire.token == token && wire.pid == pid && wire.birth == birth &&
            wire.time.isFinite && wire.time <= IO.clock() && ["ready", "enabled", "heartbeat", "done"].contains(wire.kind)
    }
    static func validParent(_ wire: Wire, token: String) -> Bool {
        wire.version == 1 && wire.token == token && wire.time.isFinite && wire.time <= IO.clock() && IO.clock() - wire.time <= IO.peerLease
    }
    final class Channel<Incoming: Decodable> {
        let readFD: Int32, writeFD: Int32
        var buffer = Data(), queued: [Incoming] = []
        init(readFD: Int32, writeFD: Int32) throws {
            self.readFD = readFD; self.writeFD = writeFD
            guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw IO.ProbeError.io }
        }
        func send<T: Encodable>(_ value: T) throws {
            var bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 16_383 else { throw IO.ProbeError.protocolFailure }
            bytes.append(10); try IO.writeAll(writeFD, bytes)
        }
        func available() throws -> [Incoming] {
            if !queued.isEmpty { let result = queued; queued = []; return result }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            if count == 0 { throw IO.ProbeError.peerClosed }
            if count < 0 { if errno == EAGAIN || errno == EINTR { return [] }; throw IO.ProbeError.io }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 16_384 else { throw IO.ProbeError.protocolFailure }
            var values: [Incoming] = []
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                values.append(try JSONDecoder().decode(Incoming.self, from: line))
            }
            return values
        }
        func next(until deadline: Double) throws -> Incoming {
            while IO.clock() < deadline {
                let values = try available()
                if let first = values.first { queued.append(contentsOf: values.dropFirst()); return first }
                IO.pause(0.02)
            }
            throw IO.ProbeError.timeout
        }
    }
}
