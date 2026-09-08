import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LonghaulCore
import LonghaulBridge

/// Experimental runner. Only `run` accepts the explicit physical-probe acknowledgement.
/// The child owns the single enable; parent takeover requires confirmed child termination.
enum LidProbeRunner {
    static let acknowledgement = "--acknowledge-experimental-shared-state"
    static let watchdogCommand = "lid-watchdog"
    static let defaultDuration: Double = 30
    static let maximumDuration: Double = 60
    static let peerLease: Double = 2

    struct Sample: Codable {
        var time: Double
        var inspection: LidServiceInspection
        var power: PowerSnapshot
        var powerKnown: Bool
        var ownerScanComplete: Bool
        var knownOwners: [String]
        func fresh(at now: Double) -> Bool { now.isFinite && time.isFinite && now >= time && now - time <= 1 }
        var conditions: LidProbeConditions {
            .init(registry: inspection.snapshot, power: power,
                  batteryStage: power.warningLevel > 1 ? .prepare : .normal,
                  clientAlive: true, monitorAlive: true,
                  coOwnerScanComplete: ownerScanComplete && powerKnown, knownCoOwners: knownOwners)
        }
        var startupSafe: Bool {
            inspection.serviceAccessSucceeded && inspection.snapshot.normalOpenLidPolicy && operatingSafe
        }
        var operatingSafe: Bool {
            powerKnown && ownerScanComplete && knownOwners.isEmpty && power.onAC && !power.discharging &&
            power.percent.map { $0.isFinite && (30...100).contains($0) } == true &&
            power.thermalLevel == 0 && power.warningLevel == 1
        }
    }
    struct Wire: Codable {
        var version = 1
        var kind: String
        var token: String
        var time: Double
        var pid: Int32?
        var birth: UInt64?
        var parentPID: Int32?
        var parentBirth: UInt64?
        var started: Double?
        var deadline: Double?
        var duration: Double?
        var directory: String?
        var lockDirectory: String?
        var sample: Sample?
        var backend: LidMutationResult?
        var cleanupRequired: Bool?
        var failed: Bool?
        var note: String?
        var ledgerIdentity: LidSessionIdentity?
    }
    enum ProbeError: Error { case refused(String), io, protocolFailure, timeout, peerClosed }
    enum CleanupDecision: Equatable { case unnecessary, clearSharedBit, unresolved }

    static func requestedDuration(_ args: [String]) -> Double? {
        if args == [acknowledgement] { return defaultDuration }
        for seconds in ["30", "60"] where
            args == [acknowledgement, "--duration", seconds] ||
            args == ["--duration", seconds, acknowledgement] {
            return Double(seconds)
        }
        return nil
    }
    static func validArguments(_ args: [String]) -> Bool { requestedDuration(args) != nil }
    /// Pure validation seam used by the disposable fake-input harness.
    static func validAuthorization(_ a: Wire, parentPID: Int32, parentBirth: UInt64,
                                   childPID: Int32, childBirth: UInt64, now: Double) -> Bool {
        guard a.version == 1, a.kind == "authorize", UUID(uuidString: a.token) != nil,
              a.parentPID == parentPID, a.parentBirth == parentBirth, parentPID > 1, parentBirth != 0,
              a.pid == childPID, a.birth == childBirth, childBirth != 0,
              let started = a.started, let deadline = a.deadline, let duration = a.duration,
              now.isFinite, started.isFinite, deadline.isFinite, started >= 0,
              [defaultDuration, maximumDuration].contains(duration), duration <= maximumDuration,
              now >= started, now - started <= peerLease, deadline == started + duration,
              let path = a.directory, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("lid-probe-"),
              let lockPath = a.lockDirectory, lockPath.hasPrefix("/"), !lockPath.contains("\0"), lockPath.utf8.count <= 4096 else { return false }
        return true
    }
    static func cleanupDecision(mayHaveEnabled: Bool, registry: LidRegistrySnapshot,
                                ownerScanComplete: Bool, knownOwners: [String]) -> CleanupDecision {
        guard mayHaveEnabled else { return .unnecessary }
        guard ownerScanComplete, knownOwners.isEmpty, registry.policySnapshotKnown else { return .unresolved }
        // An accepted enable can leave the published property unchanged. Balance
        // it once even when that property still says lid closure causes sleep.
        return .clearSharedBit
    }

    static func inspect() -> Int32 {
        do { print(String(decoding: try JSONEncoder().encode(sample()), as: UTF8.self)); return 0 }
        catch { return 1 }
    }

    static func run(arguments: [String], box: Mailbox) -> Int32 {
        guard let cap = requestedDuration(arguments) else {
            print("Usage: longhaul lid-probe --acknowledge-experimental-shared-state [--duration 30|60] (default 30)")
            return 2
        }
        var child: Process?
        var childBirth: UInt64 = 0
        var mayHaveEnabled = false
        var stickyConflict = false
        var journal: Journal?
        var globalLock: Int32 = -1
        var ledger: LidSessionLedger?
        var ledgerIdentity: LidSessionIdentity?
        defer { if globalLock >= 0 { Darwin.close(globalLock) } }
        do {
            let initial = sample()
            guard initial.startupSafe, initial.fresh(at: clock()) else { throw ProbeError.refused("Open lid, normal policy, AC, non-discharging battery >=30%, nominal thermal state and no known controller are required.") }
            // Global even when --root selects a different evidence directory.
            #if LONGHAUL_LID_PROBE_TESTING
            let globalRoot = box.root
            #else
            let globalRoot = try Mailbox().root
            #endif
            globalLock = try lockProbe(in: globalRoot)
            let interlock = try LidSessionLedger(root: globalRoot); ledger = interlock
            try requireAdmission(interlock)
            // Both participants open their own independent lock, avoiding reliance
            // on an inherited descriptor's lifetime for exclusive admission.
            let watchdogCheck = try lockProbe(in: globalRoot, name: ".lid-watchdog.lock")
            Darwin.close(watchdogCheck)
            let directory = try newDirectory(in: box.root)
            let log = try Journal(directory: directory, role: "parent"); journal = log
            try log.record("initial", sample: initial)
            print("Experimental \(Int(cap))-second probe. Private evidence: \(directory.path)")
            let inbound = Pipe(), outbound = Pipe()
            let task = Process(); child = task
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            task.arguments = [watchdogCommand]
            task.standardInput = inbound; task.standardOutput = outbound
            // Descriptor 2 is an inherited launch capability, never a diagnostics stream.
            task.standardError = FileHandle(fileDescriptor: globalLock, closeOnDealloc: false)
            try task.run()
            try inbound.fileHandleForReading.close(); try outbound.fileHandleForWriting.close()
            defer { try? inbound.fileHandleForWriting.close(); try? outbound.fileHandleForReading.close() }
            let channel = try Channel(readFD: outbound.fileHandleForReading.fileDescriptor, writeFD: inbound.fileHandleForWriting.fileDescriptor)
            childBirth = ProcessIdentity.birth(task.processIdentifier)
            let parentBirth = ProcessIdentity.birth(getpid())
            guard childBirth != 0, parentBirth != 0 else { throw ProbeError.protocolFailure }
            let started = clock(), token = UUID().uuidString
            let identity = LidSessionIdentity(bootID: try LidSessionLedger.currentBootID(), sessionID: token,
                                              appPID: getpid(), appBirth: parentBirth)
            ledgerIdentity = identity
            let authorization = Wire(kind: "authorize", token: token, time: started, pid: task.processIdentifier,
                                     birth: childBirth, parentPID: getpid(), parentBirth: parentBirth,
                                     started: started, deadline: started + cap, duration: cap,
                                     directory: directory.path, lockDirectory: globalRoot.path, ledgerIdentity: identity)
            try channel.send(authorization)
            let ready = try channel.next(until: started + peerLease)
            guard validReply(ready, token: token, pid: task.processIdentifier, birth: childBirth), ready.kind == "ready",
                  ready.sample?.startupSafe == true, sample().startupSafe else { throw ProbeError.protocolFailure }
            // Durable intent precedes grant. Parent death from this point requires qualified cleanup.
            try log.record("enable-may-be-attempted", note: "One enable authorized; shared state has no ownership token.", sync: true)
            try interlock.beginEnable(identity: identity, at: clock())
            mayHaveEnabled = true
            try channel.send(.init(kind: "grant", token: token, time: clock()))
            var lastPeer = clock(), lastPeerStamp = ready.time, hadFailure = false
            while clock() < started + cap + 2 {
                // Drain a final reply before testing liveness or writing to a closed pipe.
                for reply in try channel.available() {
                    guard validReply(reply, token: token, pid: task.processIdentifier, birth: childBirth),
                          reply.time >= lastPeerStamp, reply.time <= clock() + 0.1,
                          clock() - reply.time <= peerLease else { throw ProbeError.protocolFailure }
                    lastPeer = clock(); lastPeerStamp = reply.time
                    hadFailure = hadFailure || reply.failed == true || reply.backend.map { !$0.succeeded } == true
                    try log.record("child-" + reply.kind, sample: reply.sample, backend: reply.backend,
                                   note: reply.note, cleanupRequired: reply.cleanupRequired)
                    if reply.kind == "done" {
                        guard stopAndConfirm(task, birth: childBirth) else { throw ProbeError.refused("Child termination unconfirmed; cleanup required.") }
                        // Independently observe cleanup, including an ownership recheck.
                        let final = sample()
                        let cleanupAccepted = reply.cleanupRequired == false && log.cleanupState == .accepted &&
                            final.inspection.serviceAccessSucceeded && final.inspection.snapshot.policySnapshotKnown && final.fresh(at: clock()) &&
                            final.ownerScanComplete && final.knownOwners.isEmpty
                        let success = !hadFailure && !stickyConflict && cleanupAccepted
                        try log.record("final-observation", sample: final,
                                       note: "Registry snapshots do not prove the hidden mask or physical behavior.",
                                       cleanupRequired: !cleanupAccepted, sync: true)
                        print(success ? "Probe ended; balancing clear accepted. Physical behavior needs separate review." :
                              cleanupAccepted ? "Probe failed; balancing clear accepted. Review private evidence." :
                              "Probe ended with cleanup required. Inspect private evidence before any further probe.")
                        return success ? 0 : 3
                    }
                }
                guard ProcessIdentity.isSame(pid: task.processIdentifier, birth: childBirth) else { throw ProbeError.peerClosed }
                try channel.send(.init(kind: "heartbeat", token: token, time: clock()))
                let snapshot = sample()
                try log.record("heartbeat", sample: snapshot)
                if !snapshot.ownerScanComplete || !snapshot.knownOwners.isEmpty {
                    stickyConflict = true
                    try log.markOwnerConflict()
                }
                if !snapshot.operatingSafe || !snapshot.fresh(at: clock()) {
                    try channel.send(.init(kind: "stop", token: token, time: clock(), cleanupRequired: stickyConflict))
                }
                if clock() - lastPeer > peerLease { throw ProbeError.timeout }
                pause(0.25)
            }
            throw ProbeError.timeout
        } catch {
            let stopped = child.map { stopAndConfirm($0, birth: childBirth) } ?? true
            try? journal?.record("parent-failure", note: String(describing: error), cleanupRequired: mayHaveEnabled, sync: true)
            if mayHaveEnabled, stopped, !stickyConflict, let journal {
                let cleaned = qualifiedCleanup(journal: journal, mayHaveEnabled: true, ledger: ledger, identity: ledgerIdentity)
                print(cleaned ? "Probe failed; balancing clear accepted. Review evidence." : "Probe failed; cleanup remains required. Do not start another probe.")
            } else {
                print(stickyConflict ? "Co-owner state requires review; no blind reset was attempted." :
                      mayHaveEnabled ? "Probe failed; child stop unconfirmed, cleanup required." : "Probe refused before enable: \(error)")
            }
            return mayHaveEnabled ? 3 : 2
        }
    }

    static func watchdog(arguments: [String]) -> Int32 {
        // Direct invocation without all inherited transport/lifetime descriptors is rejected.
        guard arguments.isEmpty, descriptor(0, type: S_IFIFO), descriptor(1, type: S_IFIFO),
              descriptor(2, type: S_IFREG, privateOwned: true), flock(2, LOCK_EX | LOCK_NB) == 0 else { return 2 }
        let parent = getppid(), parentBirth = ProcessIdentity.birth(parent), me = getpid(), birth = ProcessIdentity.birth(getpid())
        guard parent > 1, parentBirth != 0, birth != 0 else { return 2 }
        // A stopped group within the parent's session can receive an orphan-group
        // hangup when the parent dies. Isolate the watchdog's session as well.
        _ = signal(SIGHUP, SIG_IGN)
        if getpgrp() == me && getsid(0) != me {
            // Foundation may launch the child as a group leader, which cannot call
            // setsid. Rejoin the parent's group only while still unauthorized.
            let parentGroup = getpgid(parent)
            guard parentGroup > 0, setpgid(0, parentGroup) == 0 else { return 2 }
        }
        guard setsid() >= 0 || getsid(0) == me else { return 2 }
        guard getpgrp() != getpgid(parent), getsid(0) == me else { return 2 }
        var journal: Journal?
        var channel: Channel?
        var token = ""
        var mayHaveEnabled = false
        var stickyConflict = false
        var watchdogLock: Int32 = -1
        var ledger: LidSessionLedger?
        var ledgerIdentity: LidSessionIdentity?
        defer { if watchdogLock >= 0 { Darwin.close(watchdogLock) } }
        do {
            let transport = try Channel(readFD: 0, writeFD: 1); channel = transport
            let a = try transport.next(until: clock() + peerLease)
            guard validAuthorization(a, parentPID: parent, parentBirth: parentBirth, childPID: me, childBirth: birth, now: clock()),
                  ProcessIdentity.isSame(pid: parent, birth: parentBirth), let directory = a.directory, let lockDirectory = a.lockDirectory,
                  let started = a.started, let deadline = a.deadline, let cap = a.duration else { throw ProbeError.protocolFailure }
            guard let identity = a.ledgerIdentity, identity.isValid, identity.sessionID == a.token,
                  identity.bootID == (try LidSessionLedger.currentBootID()), identity.appPID == parent,
                  identity.appBirth == parentBirth else { throw ProbeError.protocolFailure }
            ledgerIdentity = identity
            let interlock = try LidSessionLedger(root: URL(fileURLWithPath: lockDirectory)); ledger = interlock
            token = a.token
            watchdogLock = try lockProbe(in: URL(fileURLWithPath: lockDirectory), name: ".lid-watchdog.lock")
            let log = try Journal(directory: URL(fileURLWithPath: directory), role: "watchdog"); journal = log
            let initial = sample()
            try log.record("initial", sample: initial, sync: true)
            guard initial.startupSafe, initial.fresh(at: clock()) else { throw ProbeError.refused("Native startup conditions are unsafe or unknown.") }
            try transport.send(.init(kind: "ready", token: token, time: clock(), pid: me, birth: birth, sample: initial))
            let grant = try transport.next(until: min(deadline, clock() + peerLease))
            guard grant.kind == "grant", grant.version == 1, grant.token == token,
                  grant.time.isFinite, grant.time <= clock(), clock() - grant.time <= peerLease,
                  ProcessIdentity.isSame(pid: parent, birth: parentBirth) else { throw ProbeError.protocolFailure }
            let before = sample()
            guard before.startupSafe, before.fresh(at: clock()), clock() < deadline else { throw ProbeError.refused("Startup conditions changed before enable.") }
            var session = LidQualificationSession()
            guard session.start(now: started, conditions: before.conditions, explicitlyAuthorized: true,
                                leaseSeconds: cap, sessionCapSeconds: cap) == .disableClamshellSleep else { throw ProbeError.protocolFailure }
            try log.record("enable-intent", sample: before, sync: true)
            guard clock() < deadline, before.fresh(at: clock()), ProcessIdentity.isSame(pid: parent, birth: parentBirth),
                  case .blocked(let record) = try interlock.admission(currentBootID: identity.bootID),
                  record.identity == identity, record.stage == .enableIntent else { throw ProbeError.timeout }
            mayHaveEnabled = true
            let enabled = mutate(true)
            try interlock.recordEnableResult(identity: identity, result: enabled, at: clock())
            let enabledAt = clock()
            try log.record("enable-result", backend: enabled, sync: true)
            try transport.send(.init(kind: "enabled", token: token, time: clock(), pid: me, birth: birth, backend: enabled))
            var directive = session.didEnable(enabled, now: clock())
            var lastParent = clock(), lastParentStamp = grant.time
            while clock() < deadline {
                if directive == .enableClamshellSleep { break }
                let observation = sample()
                try log.record("heartbeat", sample: observation)
                if !observation.fresh(at: clock()) { throw ProbeError.timeout }
                if !observation.ownerScanComplete || !observation.knownOwners.isEmpty {
                    stickyConflict = true; try log.markOwnerConflict(); break
                }
                if !ProcessIdentity.isSame(pid: parent, birth: parentBirth) || clock() - lastParent > peerLease {
                    var conditions = observation.conditions
                    conditions.clientAlive = ProcessIdentity.isSame(pid: parent, birth: parentBirth)
                    conditions.monitorAlive = clock() - lastParent <= peerLease
                    directive = session.poll(now: clock(), conditions: conditions)
                    break
                }
                for message in try transport.available() {
                    guard message.version == 1, message.token == token, ["heartbeat", "stop"].contains(message.kind),
                          message.time.isFinite, message.time >= lastParentStamp, message.time <= clock() + 0.1,
                          clock() - message.time <= peerLease else { throw ProbeError.protocolFailure }
                    lastParent = clock(); lastParentStamp = message.time
                    if message.kind == "stop" {
                        if message.cleanupRequired == true { stickyConflict = true; try log.markOwnerConflict() }
                        directive = session.stop()
                    }
                }
                if directive == .enableClamshellSleep { break }
                var conditions = observation.conditions
                conditions.clientAlive = ProcessIdentity.isSame(pid: parent, birth: parentBirth)
                conditions.monitorAlive = clock() - lastParent <= peerLease
                directive = session.poll(now: clock(), conditions: conditions)
                if session.phase == .cleanupRequired { stickyConflict = true; try log.markOwnerConflict(); break }
                try transport.send(.init(kind: "heartbeat", token: token, time: clock(), pid: me, birth: birth, sample: observation))
                pause(0.25)
            }
            if session.phase == .active {
                _ = session.poll(now: clock(), conditions: sample().conditions)
            }
            let elapsed = clock() - started
            let qualificationComplete = enabled.succeeded && session.failures.isEmpty &&
                session.stopReason == .sessionExpired && elapsed >= cap
            try log.record("session-ended", note: "Stop: \(session.stopReason?.rawValue ?? "none"); failures: \(session.failures.map(\.rawValue).joined(separator: ",")); elapsed: \(elapsed) seconds; accepted-call duration: \(clock() - enabledAt) seconds; full interval: \(qualificationComplete).", sync: true)
            if stickyConflict, let ledger, let ledgerIdentity {
                try? ledger.markUnresolved(identity: ledgerIdentity, reason: "Co-owner state changed.", at: clock())
            }
            let cleaned = !stickyConflict && qualifiedCleanup(journal: log, mayHaveEnabled: mayHaveEnabled, ledger: ledger, identity: ledgerIdentity)
            try log.record("done", cleanupRequired: !cleaned, sync: true)
            try? transport.send(.init(kind: "done", token: token, time: clock(), pid: me, birth: birth,
                                      cleanupRequired: !cleaned, failed: !qualificationComplete,
                                      note: stickyConflict ? "New or unknown co-owner; no blind reset." :
                                        qualificationComplete ? "Full qualification interval elapsed; physical behavior unverified." :
                                        "Qualification ended early: \(session.stopReason?.rawValue ?? "unknown")."))
            return cleaned && qualificationComplete ? 0 : 3
        } catch {
            try? journal?.record("watchdog-failure", note: String(describing: error), cleanupRequired: mayHaveEnabled, sync: true)
            let cleaned: Bool
            if let journal { cleaned = !stickyConflict && qualifiedCleanup(journal: journal, mayHaveEnabled: mayHaveEnabled, ledger: ledger, identity: ledgerIdentity) }
            else { cleaned = !mayHaveEnabled }
            try? channel?.send(.init(kind: "done", token: token, time: clock(), pid: me, birth: birth,
                                     cleanupRequired: !cleaned, failed: true, note: "Watchdog stopped after an error; review journal."))
            return mayHaveEnabled ? 3 : 2
        }
    }

    static func qualifiedCleanup(journal: Journal, mayHaveEnabled: Bool,
                                 ledger: LidSessionLedger? = nil, identity: LidSessionIdentity? = nil) -> Bool {
        func debt(_ reason: String) -> Bool {
            if let ledger, let identity { try? ledger.markUnresolved(identity: identity, reason: reason, at: clock()) }
            return false
        }
        guard !journal.hasOwnerConflict else { return debt("Co-owner state changed; no blind clear.") }
        let current = sample()
        guard current.fresh(at: clock()) else { return debt("Cleanup sample was stale.") }
        let state = journal.cleanupState
        // After confirmed child termination, the parent may trust a durable
        // successful result, but never retry an attempted clear with no result.
        if state != .notAttempted {
            let accepted = state == .accepted && current.inspection.serviceAccessSucceeded && current.inspection.snapshot.policySnapshotKnown &&
                current.ownerScanComplete && current.knownOwners.isEmpty
            try? journal.record("cleanup-no-retry", sample: current,
                                note: accepted ? "Durable balancing-clear acceptance found." : "A clear was attempted; its result is failed, unknown or unsafe. No retry.",
                                cleanupRequired: !accepted, sync: true)
            guard accepted else { return debt("Clear outcome is unknown or ownership is ambiguous.") }
            do {
                if let ledger, let identity {
                    switch try ledger.admission(currentBootID: identity.bootID) {
                    case .available: break
                    case .blocked(let record) where record.identity == identity && record.stage == .cleanupAttempted:
                        guard let result = try journal.acceptedCleanupResult() else { return debt("Clear receipt missing.") }
                        try ledger.recordCleanupResult(identity: identity, result: result, at: clock())
                    default: return debt("Clear receipt does not match the current ledger attempt.")
                    }
                }
                return true
            } catch { return debt("Unable to reconcile accepted clear receipt.") }
        }
        let decision = cleanupDecision(mayHaveEnabled: mayHaveEnabled, registry: current.inspection.snapshot,
                                       ownerScanComplete: current.ownerScanComplete, knownOwners: current.knownOwners)
        do {
            try journal.record("cleanup-assessment", sample: current, cleanupRequired: decision == .unresolved, sync: true)
            switch decision {
            case .unnecessary: return true
            case .unresolved: return debt("Cleanup ownership or policy is unknown.")
            case .clearSharedBit:
                // Durable exclusive intent precedes the only clear. Death or
                // failure after this point creates debt, not permission to retry.
                if let ledger, let identity { try ledger.beginCleanupAttempt(identity: identity, at: clock()) }
                try journal.beginCleanupAttempt()
                let result = mutate(false)
                try journal.finishCleanupAttempt(result)
                #if LONGHAUL_LID_PROBE_TESTING
                if FileManager.default.fileExists(atPath: fakeRoot.appendingPathComponent("stall-after-clear-receipt").path) {
                    while true { pause(1) }
                }
                #endif
                if let ledger, let identity { try ledger.recordCleanupResult(identity: identity, result: result, at: clock()) }
                try journal.record("cleanup-result", backend: result, sync: true)
                let after = sample()
                let accepted = result.succeeded && after.fresh(at: clock()) && after.inspection.serviceAccessSucceeded &&
                    after.inspection.snapshot.policySnapshotKnown && after.ownerScanComplete && after.knownOwners.isEmpty
                try journal.record("cleanup-observation", sample: after,
                                   note: "Clear acceptance and registry snapshot only; physical restoration unverified.",
                                   cleanupRequired: !accepted, sync: true)
                return accepted ? true : debt("Cleanup result or post-clear ownership check failed.")
            }
        } catch { return debt("Cleanup attempt failed or its outcome is unresolved.") }
    }

    static func requireAdmission(_ ledger: LidSessionLedger) throws {
        let boot = try LidSessionLedger.currentBootID()
        if case .previousBoot = try ledger.admission(currentBootID: boot) {
            _ = try ledger.reconcilePreviousBoot(currentBootID: boot)
        }
        guard try ledger.admission(currentBootID: boot) == .available else {
            throw ProbeError.refused("Unresolved previous lid session blocks another enable.")
        }
    }

    private static func validReply(_ r: Wire, token: String, pid: Int32, birth: UInt64) -> Bool {
        r.version == 1 && r.token == token && r.pid == pid && r.birth == birth && r.time.isFinite &&
        ["ready", "enabled", "heartbeat", "done"].contains(r.kind)
    }
    static func stopAndConfirm(_ task: Process, birth: UInt64) -> Bool {
        let pid = task.processIdentifier
        guard pid > 1, birth != 0 else { return !task.isRunning }
        guard ProcessIdentity.isSame(pid: pid, birth: birth) else { return true }
        // Signal only this Process object's exact incarnation, never the caller or another task.
        _ = kill(pid, SIGTERM)
        let grace = clock() + 0.3
        while clock() < grace && ProcessIdentity.isSame(pid: pid, birth: birth) { pause(0.02) }
        if ProcessIdentity.isSame(pid: pid, birth: birth) { _ = kill(pid, SIGKILL) }
        let until = clock() + 1
        while clock() < until && ProcessIdentity.isSame(pid: pid, birth: birth) { pause(0.02) }
        return !ProcessIdentity.isSame(pid: pid, birth: birth)
    }
    static func clock() -> Double {
        #if LONGHAUL_LID_PROBE_TESTING
        return LidQualificationIO.monotonicSeconds() * 4
        #else
        return LidQualificationIO.monotonicSeconds()
        #endif
    }
    static func pause(_ seconds: Double) {
        #if LONGHAUL_LID_PROBE_TESTING
        Thread.sleep(forTimeInterval: seconds / 4)
        #else
        Thread.sleep(forTimeInterval: seconds)
        #endif
    }
    static func mutate(_ disabled: Bool) -> LidMutationResult {
        #if LONGHAUL_LID_PROBE_TESTING
        return fakeMutation(disabled)
        #else
        return LidQualificationIO.setClamshellSleepDisabled(disabled)
        #endif
    }

    static func sample() -> Sample {
        #if LONGHAUL_LID_PROBE_TESTING
        return fakeSample()
        #else
        return nativeSample()
        #endif
    }
    #if !LONGHAUL_LID_PROBE_TESTING
    private static func nativeSample() -> Sample {
        let started = clock()
        var power = PowerSnapshot(percent: nil, onAC: false, discharging: true,
                                  warningLevel: Int(IOPSGetBatteryWarningLevel().rawValue),
                                  thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
        var sourceKnown = false, currentKnown = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in sources {
                guard let d = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                      let maximum = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                      maximum > 0, current.isFinite, maximum.isFinite,
                      let state = d[kIOPSPowerSourceStateKey] as? String,
                      [kIOPSACPowerValue, kIOPSBatteryPowerValue].contains(state) else { continue }
                power.percent = current / maximum * 100
                power.onAC = state == kIOPSACPowerValue; sourceKnown = true
            }
        }
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            if let current = IORegistryEntryCreateCFProperty(battery, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                power.discharging = !power.onAC || current.int64Value < 0; currentKnown = true
            }
            IOObjectRelease(battery)
        }
        let applications = NSWorkspace.shared.runningApplications
        let names = ["amphetamine", "keepingyouawake", "caffeine", "nosleep", "insomniax", "sleep control"]
        var owners = applications.compactMap { app -> String? in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return names.contains(where: { name.contains($0) || bundle.contains($0) }) ? String((app.localizedName ?? "Known sleep controller").prefix(80)) : nil
        }
        var assertions: Unmanaged<CFDictionary>?
        let assertionResult = IOPMCopyAssertionsByProcess(&assertions)
        let entries = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        if let entries {
            for (pid, records) in entries {
                for r in records where (r[kIOPMAssertionLevelKey] as? NSNumber)?.intValue != 0 {
                    let name = (r[kIOPMAssertionNameKey] as? String ?? "").lowercased()
                    let type = r[kIOPMAssertionTypeKey] as? String ?? ""
                    if name.contains("caffeinate") || ["PreventSystemSleep", "NetworkClientActive"].contains(type) {
                        owners.append("Competing power assertion, PID \(pid.int32Value)")
                    }
                }
            }
        }
        return Sample(time: started, inspection: LidQualificationIO.inspect(), power: power,
                      powerKnown: sourceKnown && currentKnown && power.warningLevel > 0,
                      ownerScanComplete: !applications.isEmpty && assertionResult == 0 && entries != nil,
                      knownOwners: Array(Set(owners)).sorted().prefix(32).map { $0 })
    }
    #endif

    #if LONGHAUL_LID_PROBE_TESTING
    // Compile-time-only dependency injection. Production contains no environment switch.
    private static var fakeRoot: URL {
        guard let path = ProcessInfo.processInfo.environment["LONGHAUL_LID_TEST_DIR"], path.hasPrefix("/") else {
            fatalError("The test-only executable requires its private fixture directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private static func fakeSample() -> Sample {
        let root = fakeRoot, fm = FileManager.default
        let held = fm.fileExists(atPath: root.appendingPathComponent("held").path)
        let owner = fm.fileExists(atPath: root.appendingPathComponent("competing-owner").path)
        let unknown = fm.fileExists(atPath: root.appendingPathComponent("unknown-owner").path)
        let badPower = fm.fileExists(atPath: root.appendingPathComponent("unsafe-power").path)
        let cleared = fm.fileExists(atPath: root.appendingPathComponent("clear-has-run").path)
        let published = held ? fm.fileExists(atPath: root.appendingPathComponent("stale-true-after-enable").path) :
            !(cleared && fm.fileExists(atPath: root.appendingPathComponent("stale-false-after-clear").path))
        let unavailable = fm.fileExists(atPath: root.appendingPathComponent("service-unavailable").path)
        let bytes = Data("{\"serviceFound\":true,\"openResult\":\(unavailable ? -1 : 0),\"closeResult\":0,\"snapshot\":{\"lidClosed\":false,\"clamshellCausesSleep\":\(published),\"sleepDisabled\":false}}".utf8)
        let inspection = try! JSONDecoder().decode(LidServiceInspection.self, from: bytes)
        let percent: Double? = fm.fileExists(atPath: root.appendingPathComponent("unknown-percent").path) ? nil :
            fm.fileExists(atPath: root.appendingPathComponent("battery-five").path) ? 5 :
            badPower ? 19 : (fm.fileExists(atPath: root.appendingPathComponent("reserve-boundary").path) ? 20 : 70)
        return Sample(time: clock(), inspection: inspection, power: .init(percent: percent,
                      onAC: !fm.fileExists(atPath: root.appendingPathComponent("ac-disconnected").path),
                      discharging: fm.fileExists(atPath: root.appendingPathComponent("ac-discharge").path),
                      warningLevel: fm.fileExists(atPath: root.appendingPathComponent("battery-warning").path) ? 2 : 1,
                      thermalLevel: fm.fileExists(atPath: root.appendingPathComponent("thermal-warning").path) ? 1 : 0),
                      powerKnown: !fm.fileExists(atPath: root.appendingPathComponent("unknown-power").path),
                      ownerScanComplete: !unknown, knownOwners: owner ? ["Fake competing controller"] : [])
    }
    private static func fakeMutation(_ disabled: Bool) -> LidMutationResult {
        let root = fakeRoot
        if !disabled, FileManager.default.fileExists(atPath: root.appendingPathComponent("stall-before-clear-write").path) {
            while true { pause(1) }
        }
        do {
            let dir = try checkedDirectory(root); defer { Darwin.close(dir) }
            let lock = openat(dir, "mutation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw ProbeError.io }; defer { Darwin.close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw ProbeError.io }
            let log = openat(dir, "mutations.jsonl", O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard log >= 0 else { throw ProbeError.io }; defer { Darwin.close(log) }
            var record = try JSONSerialization.data(withJSONObject: ["disabled": disabled, "pid": getpid(), "time": clock()])
            record.append(10); try writeAll(log, record)
            if disabled {
                let held = openat(dir, "held", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard held >= 0 else { throw ProbeError.io }; Darwin.close(held)
            } else {
                if unlinkat(dir, "held", 0) != 0 && errno != ENOENT { throw ProbeError.io }
                let marker = openat(dir, "clear-has-run", O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard marker >= 0 else { throw ProbeError.io }; Darwin.close(marker)
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("stall-after-clear-write").path) {
                    while true { pause(1) }
                }
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("clear-reports-failure").path) {
                    return .init(serviceFound: true, openResult: 0, callResult: -1, closeResult: 0)
                }
            }
            return .init(serviceFound: true, openResult: 0, callResult: 0, closeResult: 0)
        } catch { return .init(serviceFound: true, openResult: 0, callResult: -1, closeResult: 0) }
    }
    #endif

    static func descriptor(_ fd: Int32, type: mode_t, privateOwned: Bool = false) -> Bool {
        var s = stat()
        return fstat(fd, &s) == 0 && s.st_mode & S_IFMT == type && (type != S_IFIFO || s.st_nlink == 0) &&
            (!privateOwned || (s.st_uid == getuid() && s.st_mode & 0o077 == 0 && s.st_nlink == 1))
    }
    static func checkedDirectory(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProbeError.io }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { Darwin.close(fd); throw ProbeError.io }
        return fd
    }
    static func lockProbe(in root: URL, name: String = ".lid-probe.lock") throws -> Int32 {
        let directory = try checkedDirectory(root); defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeError.io }
        guard descriptor(fd, type: S_IFREG, privateOwned: true), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw ProbeError.refused("Another probe owns the lifetime lock.")
        }
        return fd
    }
    static func newDirectory(in root: URL) throws -> URL {
        let parent = try checkedDirectory(root); defer { Darwin.close(parent) }
        let name = "lid-probe-" + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { throw ProbeError.io }
        guard fsync(parent) == 0 else { throw ProbeError.io }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    final class Journal {
        let fd: Int32
        let directory: URL
        var sequence = 0
        init(directory: URL, role: String) throws {
            self.directory = directory
            let dir = try checkedDirectory(directory); defer { Darwin.close(dir) }
            fd = openat(dir, role + ".jsonl", O_CREAT | O_EXCL | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProbeError.io }
            guard fsync(dir) == 0 else { Darwin.close(fd); throw ProbeError.io }
        }
        deinit { Darwin.close(fd) }
        var hasOwnerConflict: Bool {
            var info = stat()
            if lstat(directory.appendingPathComponent("owner-conflict").path, &info) == 0 { return true }
            return errno != ENOENT
        }
        func markOwnerConflict() throws {
            let dir = try checkedDirectory(directory); defer { Darwin.close(dir) }
            let marker = openat(dir, "owner-conflict", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if marker < 0, errno == EEXIST { return }
            guard marker >= 0 else { throw ProbeError.io }; defer { Darwin.close(marker) }
            try writeAll(marker, Data("Cleanup requires ownership review.\n".utf8))
            guard fsync(marker) == 0, fsync(dir) == 0 else { throw ProbeError.io }
        }
        enum CleanupState { case notAttempted, accepted, unresolved }
        var cleanupState: CleanupState {
            do {
                let dir = try checkedDirectory(directory); defer { Darwin.close(dir) }
                func read(_ name: String) throws -> Data? {
                    let file = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    if file < 0, errno == ENOENT { return nil }
                    guard file >= 0 else { throw ProbeError.io }; defer { Darwin.close(file) }
                    var info = stat()
                    guard descriptor(file, type: S_IFREG, privateOwned: true), fstat(file, &info) == 0,
                          info.st_size >= 0, info.st_size <= 4096 else { throw ProbeError.io }
                    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
                    guard Darwin.read(file, &bytes, bytes.count) == bytes.count else { throw ProbeError.io }
                    return Data(bytes)
                }
                let attempt = try read("cleanup-attempt.json")
                let result = try read("cleanup-result.json")
                guard attempt != nil else { return result == nil ? .notAttempted : .unresolved }
                guard let result, let backend = try? JSONDecoder().decode(LidMutationResult.self, from: result),
                      backend.succeeded else { return .unresolved }
                return .accepted
            } catch { return .unresolved }
        }
        func acceptedCleanupResult() throws -> LidMutationResult? {
            guard cleanupState == .accepted else { return nil }
            let dir = try checkedDirectory(directory); defer { Darwin.close(dir) }
            let file = openat(dir, "cleanup-result.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw ProbeError.io }; defer { Darwin.close(file) }
            var info = stat()
            guard descriptor(file, type: S_IFREG, privateOwned: true), fstat(file, &info) == 0,
                  info.st_size > 0, info.st_size <= 4096 else { throw ProbeError.io }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            guard Darwin.read(file, &bytes, bytes.count) == bytes.count else { throw ProbeError.io }
            let result = try JSONDecoder().decode(LidMutationResult.self, from: Data(bytes))
            return result.succeeded ? result : nil
        }
        private func writeCleanupEvidence(_ name: String, data: Data) throws {
            let dir = try checkedDirectory(directory); defer { Darwin.close(dir) }
            let file = openat(dir, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw ProbeError.io }; defer { Darwin.close(file) }
            try writeAll(file, data)
            guard fsync(file) == 0, fsync(dir) == 0 else { throw ProbeError.io }
        }
        func beginCleanupAttempt() throws {
            let intent = ["time": clock(), "pid": Double(getpid())]
            try writeCleanupEvidence("cleanup-attempt.json", data: JSONEncoder().encode(intent))
        }
        func finishCleanupAttempt(_ result: LidMutationResult) throws {
            try writeCleanupEvidence("cleanup-result.json", data: JSONEncoder().encode(result))
        }
        struct Entry: Encodable {
            let sequence: Int; let time: Double; let event: String; let pid: Int32; let birth: UInt64
            let sample: Sample?; let backend: LidMutationResult?; let note: String?; let cleanupRequired: Bool?
            let grant: LidSessionGrant?
        }
        func record(_ event: String, sample: Sample? = nil, backend: LidMutationResult? = nil,
                    note: String? = nil, cleanupRequired: Bool? = nil, grant: LidSessionGrant? = nil, sync: Bool = false) throws {
            sequence += 1
            var data = try JSONEncoder().encode(Entry(sequence: sequence, time: clock(), event: event, pid: getpid(), birth: ProcessIdentity.birth(getpid()),
                                                     sample: sample, backend: backend, note: note, cleanupRequired: cleanupRequired, grant: grant))
            guard data.count <= 16_384 else { throw ProbeError.protocolFailure }; data.append(10)
            try writeAll(fd, data)
            if sync, fsync(fd) != 0 { throw ProbeError.io }
        }
    }
    final class Channel {
        let readFD: Int32, writeFD: Int32
        var buffer = Data()
        var queued: [Wire] = []
        init(readFD: Int32, writeFD: Int32) throws {
            self.readFD = readFD; self.writeFD = writeFD
            guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) == 0 else { throw ProbeError.io }
            // A lost pipe must enter cleanup, not kill the process with SIGPIPE.
            guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw ProbeError.io }
        }
        func send(_ message: Wire) throws {
            var data = try JSONEncoder().encode(message)
            guard data.count <= 16_383 else { throw ProbeError.protocolFailure }; data.append(10)
            try writeAll(writeFD, data)
        }
        func available() throws -> [Wire] {
            if !queued.isEmpty { let result = queued; queued = []; return result }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            if count == 0 { throw ProbeError.peerClosed }
            if count < 0 { if errno == EAGAIN || errno == EINTR { return [] }; throw ProbeError.io }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 16_384 else { throw ProbeError.protocolFailure }
            var messages: [Wire] = []
            while let newline = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                messages.append(try JSONDecoder().decode(Wire.self, from: data))
            }
            return messages
        }
        func next(until: Double) throws -> Wire {
            while clock() < until {
                let messages = try available()
                if let first = messages.first { queued.append(contentsOf: messages.dropFirst()); return first }
                pause(0.02)
            }
            throw ProbeError.timeout
        }
    }
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        let deadline = clock() + 0.5
        try data.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, pointer.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, (errno == EINTR || errno == EAGAIN), clock() < deadline { pause(0.01); continue }
                throw ProbeError.io
            }
        }
    }
}
