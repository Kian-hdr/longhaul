import Testing
import Foundation
import LonghaulCore
@testable import LonghaulBridge

@Test func mailboxRoundtripAndPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    let e = JobEvent(id: "a", source: "Test", title: "Private event", session: "one")
    try box.emit(e)
    let result = try box.read(JobEvent.self, at: box.eventURL("Test:a"))
    #expect(result == e)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: box.eventURL("Test:a").path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    // Each helper reopens the mailbox independently; no file is kept open to
    // depend on an unless-open protection class surviving a later screen lock.
    for folder in ["requests", "receipts", "recovery"] {
        try box.write(["fixture": "metadata only"], folder: folder, key: "reopen")
        let fresh = try Mailbox(root: directory)
        let path = directory.appendingPathComponent(folder).appendingPathComponent(Mailbox.key("reopen") + ".json")
        #expect(try fresh.read([String: String].self, at: path) == ["fixture": "metadata only"])
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
@Test func heartbeatCannotReviveCompletedWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var e = JobEvent(id: "a", source: "Test", title: "Job", session: "one")
    try box.emit(e)
    let alive = try box.heartbeat(key: "Test:a", session: "one"); #expect(alive)
    let other = try box.heartbeat(key: "Test:a", session: "wrong"); #expect(!other)
    e.phase = .completed; e.sequence = 3; try box.emit(e)
    let finished = try box.heartbeat(key: "Test:a", session: "one"); #expect(!finished)
}
@Test func symlinkMailboxIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(throws: (any Error).self) { try Mailbox(root: link) }
}
@Test func messagesCannotFollowSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    let e = JobEvent(id: "a", source: "Test", title: "Job", session: "one")
    try box.emit(e)
    let link = directory.appendingPathComponent("bad.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.eventURL("Test:a"))
    #expect(throws: (any Error).self) { try box.read(JobEvent.self, at: link) }
}
@Test func processIdentityRejectsPIDReuse() {
    let birth = ProcessIdentity.birth(getpid())
    #expect(birth > 0)
    #expect(ProcessIdentity.isSame(pid: getpid(), birth: birth))
    #expect(!ProcessIdentity.isSame(pid: getpid(), birth: birth + 1))
}

@Test func terminalEventWinsConcurrentHeartbeatSequence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var event = JobEvent(id: "race", source: "Test", title: "Race fixture", session: "one")
    try box.emit(event)
    event.sequence += 1; event.phase = .cancelled
    _ = try box.heartbeat(key: "Test:race", session: "one")
    try box.emit(event)
    let result = try box.read(JobEvent.self, at: box.eventURL("Test:race"))
    #expect(result.phase == .cancelled)
    #expect(result.sequence == 2)
    let alive = try box.heartbeat(key: "Test:race", session: "one")
    #expect(!alive)
}

@Test func realHookContinuesSoftStopWithoutHeartbeatRevival() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var engine = PolicyEngine()
    func report(_ phase: JobPhase, _ sequence: Int, stop: Bool = false) throws -> JobEvent {
        let event = JobEvent(id: "hook", source: "Test", title: "Hook", phase: phase, sequence: sequence, session: "turn")
        try box.emitHook(event, isStop: stop)
        return try box.read(JobEvent.self, at: box.eventURL("Test:hook"))
    }
    let outcome1 = engine.receive(try report(.running, 10), now: 0)
    #expect(outcome1)
    let stopped = try report(.completed, 20, stop: true)
    let outcome2 = engine.receive(stopped, now: 1)
    #expect(outcome2)
    #expect(!(try box.heartbeat(key: "Test:hook", session: "turn")))
    // Neither an older actual observation nor a generic high-sequence producer revives it.
    #expect(try report(.waiting, 19) == stopped)
    try box.emit(JobEvent(id: "hook", source: "Test", title: "Hook", sequence: 1000, session: "turn"))
    #expect(try box.read(JobEvent.self, at: box.eventURL("Test:hook")) == stopped)
    let resumed = try report(.waiting, 30)
    #expect(resumed.phase == .waiting)
    #expect(resumed.continuableHookStop == stopped.sequence)
    // A delayed Stop cannot terminate newer real work, even after worker increments.
    #expect(try box.heartbeat(key: "Test:hook", session: "turn"))
    let beforeDelayedStop = try box.read(JobEvent.self, at: box.eventURL("Test:hook"))
    #expect(try report(.completed, 25, stop: true) == beforeDelayedStop)
    let later = try report(.running, 40)
    // The engine deliberately missed the first resumed event.
    let outcome3 = engine.receive(later, now: 2)
    #expect(outcome3)
    let outcome4 = engine.evaluate(now: 2, power: PowerSnapshot(), settings: PolicySettings()).shouldHold
    #expect(outcome4)
    let cancelled = try report(.cancelled, 50)
    let outcome5 = engine.receive(cancelled, now: 3)
    #expect(outcome5)
    #expect(try report(.completed, 60, stop: true) == cancelled)
    #expect(try report(.running, 70) == cancelled)
    #expect(!(try box.heartbeat(key: "Test:hook", session: "turn")))
}

@Test func hookStopSurvivesMissedTransitionsAndSessionEndSealsIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var engine = PolicyEngine()
    func report(_ phase: JobPhase, _ sequence: Int, stop: Bool = false) throws -> JobEvent {
        try box.emitHook(JobEvent(id: "hook", source: "Test", title: "Hook", phase: phase, sequence: sequence, session: "turn"), isStop: stop)
        return try box.read(JobEvent.self, at: box.eventURL("Test:hook"))
    }
    let outcome6 = engine.receive(try report(.completed, 20, stop: true), now: 0)
    #expect(outcome6)
    _ = try report(.running, 30)
    _ = try report(.completed, 40, stop: true)
    let outcome7 = engine.receive(try report(.running, 50), now: 2)
    #expect(outcome7)
    let stopped = try report(.completed, 60, stop: true)
    let outcome8 = engine.receive(stopped, now: 3)
    #expect(outcome8)
    let sealed = try report(.completed, 70) // SessionEnd preserves the completed label.
    #expect(sealed.continuableHookStop == nil)
    #expect(try report(.running, 80) == sealed)
    #expect(try report(.completed, 90, stop: true) == sealed)
    let outcome9 = engine.receive(sealed, now: 4)
    #expect(outcome9)
    var forgedContinuation = stopped
    forgedContinuation.phase = .running; forgedContinuation.sequence = 100
    let outcome10 = !engine.receive(forgedContinuation, now: 5)
    #expect(outcome10)
}

@Test func hookObservationOrderingIsIndependentOfWorkerSequence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var event = JobEvent(id: "hook", source: "Test", title: "Hook", sequence: 10, session: "turn")
    try box.emitHook(event)
    for _ in 0..<5 { #expect(try box.heartbeat(key: "Test:hook", session: "turn")) }
    event.sequence = 11; event.phase = .completed
    try box.emitHook(event, isStop: true)
    let stopped = try box.read(JobEvent.self, at: box.eventURL("Test:hook"))
    #expect(stopped.sequence == 16)
    #expect(stopped.continuableHookStop == 16)
    event.sequence = 12; event.phase = .running
    try box.emitHook(event)
    let resumed = try box.read(JobEvent.self, at: box.eventURL("Test:hook"))
    #expect(resumed.sequence == 17)
    #expect(resumed.continuableHookStop == 16)
}

@Test func incompleteSoftStopReceiptDoesNotReopenWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = try Mailbox(root: directory)
    var event = JobEvent(id: "hook", source: "Test", title: "Hook", phase: .completed, sequence: 10, session: "turn")
    try box.emitHook(event, isStop: true)
    let receipt = directory.appendingPathComponent("recovery").appendingPathComponent(Mailbox.key("hook-observation:Test:hook") + ".json")
    // Simulate interruption after the event write and before its receipt write.
    try FileManager.default.removeItem(at: receipt)
    event.sequence = 20; event.phase = .running
    try box.emitHook(event)
    #expect(try box.read(JobEvent.self, at: box.eventURL("Test:hook")).phase == .completed)
}

@Test func prunedSoftStopCanContinueButHardTerminalStaysRetired() {
    var engine = PolicyEngine()
    var soft = JobEvent(id: "soft", source: "Test", title: "Hook", phase: .completed, sequence: 10, session: "turn")
    soft.continuableHookStop = 10
    let hard = JobEvent(id: "hard", source: "Test", title: "Command", phase: .completed, sequence: 10, session: "run")
    _ = engine.receive(soft, now: 0); _ = engine.receive(hard, now: 0)
    engine.prune(now: 3601)
    soft.sequence = 20; soft.phase = .running
    var late = hard; late.sequence = 20; late.phase = .running
    let continued = engine.receive(soft, now: 3602)
    let revived = engine.receive(late, now: 3602)
    #expect(continued)
    #expect(!revived)
}
