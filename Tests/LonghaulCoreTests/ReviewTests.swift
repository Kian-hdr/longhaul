import Foundation
import Testing
import LonghaulCore
import LonghaulBridge

private let reviewPower = PowerSnapshot(percent: 80, onAC: true)
private func reviewJob(session: String = "first", sequence: Int = 0,
                       phase: JobPhase = .running, capable: Bool = false) -> JobEvent {
    JobEvent(id: "review-job", source: "Review", title: "Review fixture", phase: phase,
             sequence: sequence, session: session, checkpointCapable: capable)
}

@Test func reviewPrunedTerminalIncarnationCannotRevive() {
    var engine = PolicyEngine()
    engine.receive(reviewJob(phase: .completed), now: 0)
    engine.prune(now: 3601)
    #expect(engine.jobs.isEmpty)
    let revived = engine.receive(reviewJob(sequence: 1), now: 3602)
    #expect(!revived)
    #expect(!engine.evaluate(now: 3602, power: reviewPower, settings: .init()).shouldHold)
}

@Test func reviewNewBatteryEpisodeRequestsFreshCheckpoint() {
    var engine = PolicyEngine()
    var settings = PolicySettings(); settings.checkpointInterval = 3600
    engine.receive(reviewJob(capable: true), now: 0)
    let firstLow = engine.evaluate(now: 1, power: .init(percent: 19, onAC: false), settings: settings)
    #expect(firstLow.checkpointIDs == ["Review:review-job"])
    engine.checkpointResult("Review:review-job", success: true, now: 2)
    _ = engine.evaluate(now: 3, power: reviewPower, settings: settings)
    #expect(engine.evaluate(now: 34, power: reviewPower, settings: settings).stage == .normal)
    engine.receive(reviewJob(sequence: 1, capable: true), now: 40)
    let secondLow = engine.evaluate(now: 41, power: .init(percent: 19, onAC: false), settings: settings)
    #expect(secondLow.checkpointIDs == ["Review:review-job"])
}

@Test func reviewRetiredMailboxWriterCannotReplaceCurrentIncarnation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let box = try Mailbox(root: root)
    try box.emit(reviewJob(session: "first"))
    try box.emit(reviewJob(session: "second"))
    try box.emit(reviewJob(session: "first", sequence: 100))
    let saved = try box.read(JobEvent.self, at: box.eventURL("Review:review-job"))
    #expect(saved.session == "second")
    let currentCanRenew = try box.heartbeat(key: "Review:review-job", session: "second")
    #expect(currentCanRenew)
}

@Test func reviewLeaseBoundaryReleasesOnlyExpiredClaim() {
    var engine = PolicyEngine()
    engine.receive(reviewJob(), now: 0)
    var another = reviewJob(session: "other"); another.id = "other"
    engine.receive(another, now: 60)
    #expect(engine.evaluate(now: 119.99, power: reviewPower, settings: .init()).protectedIDs.count == 2)
    let expired = engine.evaluate(now: 120, power: reviewPower, settings: .init())
    #expect(expired.protectedIDs == ["Review:other"])
    #expect(expired.shouldHold)
    #expect(!expired.sleepEligible)
}

@Test func reviewCriticalReserveOverridesCompetingAssertion() {
    var engine = PolicyEngine(); engine.receive(reviewJob(), now: 0)
    let result = engine.evaluate(now: 1, power: .init(percent: 9, onAC: false),
                                 settings: .init(), userIdle: 0, externalHold: true)
    #expect(!result.shouldHold)
    #expect(result.emergencySleep)
    #expect(!result.sleepEligible)
}

@Test func reviewInputResumptionStartsAUsableLease() {
    var engine = PolicyEngine(); var settings = PolicySettings(); settings.inputGrace = 30
    engine.receive(reviewJob(phase: .needsInput), now: 0)
    #expect(!engine.evaluate(now: 31, power: reviewPower, settings: settings).shouldHold)
    engine.receive(reviewJob(sequence: 1), now: 32)
    #expect(engine.evaluate(now: 33, power: reviewPower, settings: settings).shouldHold)
}

@Test func reviewMailboxReopensOutstandingCheckpoint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let event = reviewJob(capable: true)
    let request = CheckpointRequest(jobID: event.id, source: event.source, session: event.session,
                                    reason: "Restart fixture", deadline: Date().addingTimeInterval(30))
    try Mailbox(root: root).write(request, folder: "requests", key: request.id)
    let reopened = try Mailbox(root: root)
    let requests = try reopened.requests(for: event)
    #expect(requests.map(\.id) == [request.id])
    // This proves message durability only, not AppModel's pending-request reconstruction.
}
