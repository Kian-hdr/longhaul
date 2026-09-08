import Foundation
import Testing
@testable import LonghaulBridge
import LonghaulCore

@Test func nativeActivityCoversUnreportedTurns() {
    #expect(CodexActivityPreference.useActivity(hook: nil, hookIsFresh: false))
}
@Test func freshHookAvoidsDuplicateNativeActivity() {
    let event = JobEvent(id: "turn", source: "Codex", title: "Fixture")
    #expect(!CodexActivityPreference.useActivity(hook: event, hookIsFresh: true))
    #expect(CodexActivityPreference.useActivity(hook: event, hookIsFresh: false))
}
@Test func hardHookTerminalsCannotBeReopenedByObservation() {
    for phase in [JobPhase.completed, .cancelled, .failed] {
        let event = JobEvent(id: "turn", source: "Codex", title: "Fixture", phase: phase)
        #expect(!CodexActivityPreference.useActivity(hook: event, hookIsFresh: false))
    }
}
@Test func provisionalStopMayUseNativeLifecycle() {
    var event = JobEvent(id: "turn", source: "Codex", title: "Fixture", phase: .completed, sequence: 5)
    event.continuableHookStop = 5
    #expect(CodexActivityPreference.useActivity(hook: event, hookIsFresh: true))
}

@Test func definitiveNativeTerminalWinsStaleHookHeartbeats() {
    let event = JobEvent(id: "turn", source: "Codex", title: "Fixture")
    #expect(CodexActivityPreference.useActivity(hook: event, hookIsFresh: true, nativeIsTerminal: true))
    var engine = PolicyEngine()
    #expect(engine.receive(event, now: 0) == true)
    engine.retireObservation("Codex:turn", session: event.session)
    var delayed = event; delayed.sequence = 10
    #expect(engine.receive(delayed, now: 1) == false)
    delayed.phase = .completed; delayed.continuableHookStop = 10
    #expect(engine.receive(delayed, now: 2) == false)
    delayed.sequence = 11; delayed.phase = .running
    #expect(engine.receive(delayed, now: 3) == false)
}

@Test func deadOrDifferentHookOwnerCannotSuppressVerifiedNativeActivity() {
    let event = JobEvent(id: "turn", source: "Codex", title: "Fixture", pid: 7, processBirth: 9)
    #expect(CodexActivityPreference.useActivity(hook: event, hookIsFresh: true, hookOwnerMatches: false))
}
