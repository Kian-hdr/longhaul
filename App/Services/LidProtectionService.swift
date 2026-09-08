import Foundation
import Observation
import Darwin
import LonghaulBridge
import LonghaulCore

/// Only AppModel's completed policy evaluations may issue grants. The transport
/// has no renewal timer; helpers independently enforce the original deadline.
@MainActor @Observable
final class LidProtectionService {
    private(set) var state: LidSessionStatus.State = .stopped
    private(set) var detail = "Closed-lid protection is off."
    private(set) var expiresAt: Double?
    @ObservationIgnored private var identity: LidSessionIdentity?
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var reportSequence: UInt64 = 0
    @ObservationIgnored private var transport: LidSessionTransport?
    @ObservationIgnored private var failedEpisode = false
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var batteryPolicy = LidBatteryPolicy()
    @ObservationIgnored private var rearmAfterCleanup = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    private enum Event: Sendable { case status(LidSessionStatus), ended(String?, Bool) }

    var active: Bool { state == .active && (expiresAt ?? 0) > LidQualificationIO.monotonicSeconds() }
    var title: String { active ? "Closed-lid protection active" : "Keep the lid open" }

    func evaluate(workPresent: Bool, eligible: Bool, evaluatedAt: Double, executable: URL?,
                  batteryPolicy: LidBatteryPolicy = .init()) {
        requested = workPresent
        if !eligible || !batteryPolicy.isValid {
            if transport != nil && workPresent { failedEpisode = true }
            revoke(reason: "Closed-lid protection released. Keep the lid open.")
            return
        }
        self.batteryPolicy = batteryPolicy
        let current = LidQualificationIO.monotonicSeconds()
        guard evaluatedAt.isFinite, current >= evaluatedAt, current - evaluatedAt < 2 else {
            revoke(reason: "Policy evaluation was delayed. Keep the lid open."); failedEpisode = true; return
        }
        if state == .active, (expiresAt ?? 0) <= current {
            revoke(reason: "Protection expired. Keep the lid open."); failedEpisode = true
        }
        guard !failedEpisode, state != .stopping, state != .cleanupRequired else { return }
        if transport == nil {
            guard let executable, let bootID = LidSessionIdentity.currentBootID() else {
                state = .unavailable; detail = "Closed-lid protection is unavailable."; failedEpisode = true; return
            }
            let id = LidSessionIdentity(bootID: bootID, sessionID: UUID().uuidString,
                                       appPID: getpid(), appBirth: ProcessIdentity.birth(getpid()))
            guard id.isValid else { state = .unavailable; failedEpisode = true; return }
            identity = id; sequence = 0; reportSequence = 0; state = .starting
            detail = "Checking closed-lid protection. Keep the lid open."
            let connection = LidSessionTransport()
            transport = connection
            let events = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(128))
            eventTask = Task { [weak self] in
                for await event in events.stream {
                    guard let self else { return }
                    switch event {
                    case .status(let status): self.receive(status, identity: id)
                    case .ended(let message, let launched): self.ended(identity: id, message: message, launched: launched); return
                    }
                }
                self?.ended(identity: id, message: "Protection status ended.", launched: true)
            }
            connection.start(executable: executable, status: { status in
                // A dropped status must close the channel, never silently keep
                // claiming a live hold while its consumer is stalled.
                if case .dropped = events.continuation.yield(.status(status)) { connection.closeInput(); events.continuation.finish() }
            }, ended: { message, launched in
                events.continuation.yield(.ended(message, launched)); events.continuation.finish()
            })
        }
        guard let identity else { return }
        sequence += 1
        transport?.send(LidSessionGrant(identity: identity, sequence: sequence, kind: .renew,
                                       evaluatedAt: evaluatedAt, expiresAt: evaluatedAt + LidSessionLease.maximumLifetime,
                                       batteryPolicy: batteryPolicy))
    }

    func rearm() {
        guard state != .cleanupRequired else { return }
        if transport != nil {
            if state == .stopping || state == .stopped { rearmAfterCleanup = true }
            return
        }
        failedEpisode = false
    }

    func revoke(reason: String) {
        guard let transport, let identity, state != .stopping, state != .stopped else { return }
        let t = LidQualificationIO.monotonicSeconds()
        sequence += 1
        transport.send(LidSessionGrant(identity: identity, sequence: sequence, kind: .revoke,
                                      evaluatedAt: t, expiresAt: t, batteryPolicy: batteryPolicy))
        transport.closeInput()
        state = .stopping; expiresAt = nil; detail = reason
    }

    private func receive(_ status: LidSessionStatus, identity expected: LidSessionIdentity) {
        guard identity == expected, transport != nil else { return }
        guard status.isValid(for: expected, after: reportSequence, now: LidQualificationIO.monotonicSeconds()) else {
            failedEpisode = true; revoke(reason: "Protection could not be confirmed. Keep the lid open."); return
        }
        reportSequence = status.sequence
        // Once local policy revoked, a queued active report cannot reassert UI protection.
        if state == .stopping && (status.state == .active || status.state == .starting) { return }
        // An independently stopped helper ends this protection attempt even if
        // work disappears before EOF. Only an explicit rearm may clear failure.
        if requested && state != .stopping && (status.state == .stopping || status.state == .stopped) {
            failedEpisode = true
        }
        state = status.state; expiresAt = status.leaseExpiresAt
        switch status.state {
        case .active:
            let cutoff = batteryPolicy.cutoffEnabled ? "Battery auto-release: below \(batteryPolicy.cutoffPercent)%." : "Battery auto-release is off."
            detail = "Reported jobs are protected on battery or connected power. \(cutoff) Desktop automation may still require an unlocked session."
        case .starting: detail = "Checking closed-lid protection. Keep the lid open."
        case .stopping: detail = "Releasing closed-lid protection."
        case .stopped: detail = "Closed-lid protection released."
        case .unavailable: detail = "Closed-lid protection is unavailable. Keep the lid open."; failedEpisode = true
        case .cleanupRequired: detail = "Power protection needs recovery. Keep the lid open and check Diagnostics."; failedEpisode = true
        }
    }

    private func ended(identity expected: LidSessionIdentity, message: String?, launched: Bool) {
        guard identity == expected else { return }
        transport = nil; identity = nil; expiresAt = nil; eventTask = nil
        if !launched { state = .unavailable; detail = "Closed-lid protection could not start."; failedEpisode = true }
        else if state != .stopped && state != .unavailable && state != .cleanupRequired {
            state = .cleanupRequired; detail = "Protection ended without confirmed cleanup. Keep the lid open."; failedEpisode = true
        }
        if requested { failedEpisode = true }
        if rearmAfterCleanup && state == .stopped { failedEpisode = false }
        rearmAfterCleanup = false
    }
}

/// Pipe operations are serialized off the main actor. Writes are nonblocking,
/// bounded and never retried with a new timestamp. EOF leaves cleanup to helpers.
private final class LidSessionTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "space.exlumina.longhaul.lid-session", qos: .utility)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var finished = false
    private var launched = false
    private var onStatus: (@Sendable (LidSessionStatus) -> Void)?
    private var onEnd: (@Sendable (String?, Bool) -> Void)?

    func start(executable: URL, status: @escaping @Sendable (LidSessionStatus) -> Void,
               ended: @escaping @Sendable (String?, Bool) -> Void) {
        queue.async { [self] in
            onStatus = status; onEnd = ended
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = executable; child.arguments = ["lid-session"]
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            do {
                try child.run(); launched = true
                process = child; input = stdin; output = stdout
                try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
                let writeFD = stdin.fileHandleForWriting.fileDescriptor
                _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
                _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
                let fd = stdout.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                reader = source
                source.setEventHandler { [self] in drain(fd) }
                source.resume()
            } catch { finish("Could not start protection.") }
        }
    }
    func send(_ grant: LidSessionGrant) {
        queue.async { [self] in
            guard !finished, let input, var data = try? JSONEncoder().encode(grant), data.count < 511 else { return }
            data.append(10)
            let count = data.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
            if count != data.count { closeInputOnQueue() }
        }
    }
    func closeInput() { queue.async { [self] in closeInputOnQueue() } }
    private func closeInputOnQueue() { try? input?.fileHandleForWriting.close(); input = nil }
    private func drain(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while !finished {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { finish(nil); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish("Protection status was lost.") }
                return
            }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 65536 else { finish("Invalid protection status."); return }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let status = try? JSONDecoder().decode(LidSessionStatus.self, from: line) else {
                    finish("Invalid protection status."); return
                }
                onStatus?(status)
            }
        }
    }
    private func finish(_ message: String?) {
        guard !finished else { return }; finished = true
        closeInputOnQueue(); reader?.cancel(); reader = nil
        try? output?.fileHandleForReading.close(); output = nil
        onEnd?(message, launched); onStatus = nil; onEnd = nil
        process = nil
    }
}
