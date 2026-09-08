import Testing
@testable import LonghaulCore

private let charged = PowerSnapshot(percent: 80, onAC: true)
private func job(_ id: String, sequence: Int = 0, phase: JobPhase = .running, capable: Bool = false) -> JobEvent {
    JobEvent(id: id, source: "test", title: "Test job", phase: phase, sequence: sequence, session: id, checkpointCapable: capable)
}

@Test func overlappingJobsNeverReleaseEachOther() {
    var engine = PolicyEngine(); let settings = PolicySettings()
    engine.receive(job("a"), now: 0); engine.receive(job("b"), now: 0)
    #expect(engine.evaluate(now: 1, power: charged, settings: settings).protectedIDs.count == 2)
    engine.receive(job("a", sequence: 1, phase: .completed), now: 2)
    let d = engine.evaluate(now: 3, power: charged, settings: settings)
    #expect(d.shouldHold); #expect(d.protectedIDs == ["test:b"])
}
@Test func waitIsWorkEvenWithoutCPU() {
    var engine = PolicyEngine(); engine.receive(job("a", phase: .waiting), now: 0)
    #expect(engine.evaluate(now: 10, power: charged, settings: .init()).shouldHold)
}
@Test func completionGraceIsCancelledByNewWork() {
    var engine = PolicyEngine(); var s = PolicySettings(); s.completionSleep = true
    engine.receive(job("a"), now: 0); _ = engine.evaluate(now: 0, power: charged, settings: s)
    engine.receive(job("a", sequence: 1, phase: .completed), now: 5)
    #expect(engine.evaluate(now: 5, power: charged, settings: s).mode == .finishing)
    engine.receive(job("b"), now: 124)
    let d = engine.evaluate(now: 126, power: charged, settings: s, userIdle: 1000)
    #expect(d.shouldHold); #expect(!d.sleepEligible)
}
@Test func onlyExplicitCompletionCanScheduleSleep() {
    var engine = PolicyEngine(); var s = PolicySettings(); s.completionSleep = true
    engine.receive(job("a"), now: 0); _ = engine.evaluate(now: 0, power: charged, settings: s)
    let lost = engine.evaluate(now: 130, power: charged, settings: s, userIdle: 1000)
    #expect(!lost.shouldHold); #expect(!lost.sleepEligible)
    let later = engine.evaluate(now: 1000, power: charged, settings: s, userIdle: 1000)
    #expect(!later.sleepEligible)
}
@Test func explicitCompletionRespectsUserAndOtherApps() {
    var engine = PolicyEngine(); var s = PolicySettings(); s.completionSleep = true
    engine.receive(job("a"), now: 0); _ = engine.evaluate(now: 0, power: charged, settings: s)
    engine.receive(job("a", sequence: 1, phase: .completed), now: 5)
    _ = engine.evaluate(now: 5, power: charged, settings: s)
    #expect(!engine.evaluate(now: 130, power: charged, settings: s, userIdle: 2).sleepEligible)
    #expect(!engine.evaluate(now: 130, power: charged, settings: s, userIdle: 1000, externalHold: true).sleepEligible)
    #expect(engine.evaluate(now: 130, power: charged, settings: s, userIdle: 1000).sleepEligible)
    engine.cancelCompletionSleep()
    #expect(!engine.evaluate(now: 131, power: charged, settings: s, userIdle: 1000).sleepEligible)
}
@Test func sequenceAndTerminalGuards() {
    var engine = PolicyEngine()
    let accepted = engine.receive(job("a", sequence: 2), now: 2); #expect(accepted)
    let old = engine.receive(job("a", sequence: 1), now: 3); #expect(!old)
    let completed = engine.receive(job("a", sequence: 3, phase: .completed), now: 4); #expect(completed)
    let revived = engine.receive(job("a", sequence: 4), now: 5); #expect(!revived)
}
@Test func batteryUsesEarliestCredibleSignal() {
    #expect(PolicyEngine.stage(for: .init(percent: 80, onAC: false, secondsRemaining: 1199)) == .prepare)
    #expect(PolicyEngine.stage(for: .init(percent: 9, onAC: false, secondsRemaining: -1)) == .critical)
    #expect(PolicyEngine.stage(for: .init(percent: 60, onAC: false, secondsRemaining: -2)) == .normal)
    #expect(PolicyEngine.stage(for: .init(percent: 60, onAC: true, discharging: true, secondsRemaining: 500)) == .critical)
    #expect(PolicyEngine.stage(for: .init(percent: 50, onAC: false, warningLevel: 3)) == .critical)
    #expect(PolicyEngine.stage(for: .init(percent: 80, thermalLevel: 3)) == .critical)
}
@Test func unknownPowerIsNotZeroRuntime() {
    #expect(PolicyEngine.stage(for: .init(onAC: false, secondsRemaining: -.infinity)) == .normal)
    #expect(PolicyEngine.stage(for: .init(percent: .nan, onAC: false, secondsRemaining: .nan)) == .normal)
}
@Test func criticalBatteryOverridesManualAndWaitingJobs() {
    var engine = PolicyEngine(); engine.receive(job("a", phase: .waiting), now: 0)
    let d = engine.evaluate(now: 1, power: .init(percent: 10, onAC: false), settings: .init())
    #expect(!d.shouldHold); #expect(d.emergencySleep); #expect(d.stage == .critical)
}
@Test func batteryRecoveryRequiresStablePower() {
    var engine = PolicyEngine()
    _ = engine.evaluate(now: 0, power: .init(percent: 9, onAC: false), settings: .init())
    #expect(engine.evaluate(now: 1, power: charged, settings: .init()).stage == .critical)
    #expect(engine.evaluate(now: 32, power: charged, settings: .init()).stage == .normal)
}
@Test func checkpointEscalatesOnceAndIsNotASaveReceipt() {
    var engine = PolicyEngine(); engine.receive(job("a", capable: true), now: 0)
    let low = PowerSnapshot(percent: 19, onAC: false)
    let d = engine.evaluate(now: 1, power: low, settings: .init())
    #expect(d.checkpointIDs == ["test:a"])
    #expect(engine.jobs["test:a"]?.checkpoint == .requested)
    #expect(engine.evaluate(now: 2, power: low, settings: .init()).checkpointIDs.isEmpty)
    engine.checkpointResult("test:a", success: false, now: 3)
    #expect(engine.jobs["test:a"]?.checkpoint == .failed)
}
@Test func wakeInvalidatesOldLeases() {
    var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
    engine.reconcileAfterWake()
    #expect(!engine.evaluate(now: 2, power: charged, settings: .init()).shouldHold)
    engine.receive(job("a", sequence: 1), now: 3)
    #expect(engine.evaluate(now: 3, power: charged, settings: .init()).shouldHold)
}
@Test func pausedMeansNoReacquisition() {
    var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
    var s = PolicySettings(); s.enabled = false
    let d = engine.evaluate(now: 1, power: charged, settings: s)
    #expect(!d.shouldHold); #expect(!d.sleepEligible); #expect(d.mode == .paused)
}
@Test func inputWaitHasBoundedGraceDespiteHeartbeats() {
    var engine = PolicyEngine(); var s = PolicySettings(); s.inputGrace = 60
    engine.receive(job("a", phase: .needsInput), now: 0)
    engine.receive(job("a", sequence: 1, phase: .needsInput), now: 50)
    #expect(engine.evaluate(now: 65, power: charged, settings: s).protectedIDs.isEmpty)
}
@Test func invalidEventsNeverCreateClaims() {
    var engine = PolicyEngine(); var e = job("a"); e.progress = 10
    let invalid = engine.receive(e, now: 0); #expect(!invalid)
    e = job(""); let empty = engine.receive(e, now: 0); #expect(!empty)
    #expect(engine.jobs.isEmpty)
}

@Test func historicalWorkCannotTriggerEmergencySleep() {
    var engine = PolicyEngine()
    engine.receive(job("old", phase: .completed), now: 0)
    let d = engine.evaluate(now: 20, power: .init(percent: 8, onAC: false), settings: .init())
    #expect(!d.emergencySleep)
}
@Test func expiredInputWaitIsNotCompletion() {
    var engine = PolicyEngine(); var s = PolicySettings(); s.completionSleep = true; s.inputGrace = 30
    engine.receive(job("a", phase: .needsInput), now: 0)
    _ = engine.evaluate(now: 0, power: charged, settings: s)
    engine.receive(job("a", sequence: 1, phase: .needsInput), now: 90)
    #expect(!engine.evaluate(now: 100, power: charged, settings: s, userIdle: 900).sleepEligible)
    #expect(!engine.evaluate(now: 900, power: charged, settings: s, userIdle: 900).sleepEligible)
}
@Test func retiredIncarnationCannotReplaceCurrentWork() {
    var engine = PolicyEngine()
    var original = job("a"); original.session = "first"
    engine.receive(original, now: 0)
    var replacement = original; replacement.session = "second"
    engine.receive(replacement, now: 1)
    original.sequence = 9
    let late = engine.receive(original, now: 2)
    #expect(!late)
    #expect(engine.jobs["test:a"]?.event.session == "second")
}

@Test func closedLidCustomCutoffReplacesHiddenNumericEmergencyStop() {
    for policy in [LidBatteryPolicy(cutoffEnabled: false), LidBatteryPolicy(cutoffPercent: 5)] {
        var engine = PolicyEngine(); engine.receive(job("a", capable: true), now: 0)
        let power = PowerSnapshot(percent: 6, onAC: false, discharging: true, secondsRemaining: 120)
        let d = engine.evaluate(now: 1, power: power, settings: .init(), closedLidBatteryPolicy: policy)
        #expect(d.shouldHold); #expect(!d.emergencySleep)
        #expect(d.stage == .prepare); #expect(d.checkpointIDs == ["test:a"])
    }
}
@Test func closedLidCutoffOffDoesNotBypassSystemEmergency() {
    for power in [PowerSnapshot(percent: 6, onAC: false, warningLevel: 3),
                  PowerSnapshot(percent: 70, thermalLevel: 3)] {
        var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
        let d = engine.evaluate(now: 1, power: power, settings: .init(),
                                closedLidBatteryPolicy: .init(cutoffEnabled: false))
        #expect(!d.shouldHold); #expect(d.emergencySleep)
    }
}
@Test func explicitCutoffChangeClearsOnlyNumericEmergencyLatch() {
    var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
    let power = PowerSnapshot(percent: 6, onAC: false)
    #expect(engine.evaluate(now: 1, power: power, settings: .init()).emergencySleep)
    #expect(engine.evaluate(now: 2, power: power, settings: .init(),
                            closedLidBatteryPolicy: .init(cutoffEnabled: false)).shouldHold)
    #expect(engine.evaluate(now: 3, power: power, settings: .init()).emergencySleep)
    var warned = power; warned.warningLevel = 3
    _ = engine.evaluate(now: 4, power: warned, settings: .init())
    #expect(!engine.evaluate(now: 5, power: power, settings: .init(),
                             closedLidBatteryPolicy: .init(cutoffEnabled: false)).shouldHold)
}
@Test func invalidClosedLidCutoffFailsClosed() {
    var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
    #expect(!engine.evaluate(now: 1, power: charged, settings: .init(),
                             closedLidBatteryPolicy: .init(cutoffPercent: 101)).shouldHold)
}

@Test func selectedCutoffReleasesIdleHoldWithoutForcingSystemSleep() {
    var engine = PolicyEngine(); engine.receive(job("a"), now: 0)
    let policy = LidBatteryPolicy(cutoffPercent: 20)
    let at = engine.evaluate(now: 1, power: .init(percent: 20, onAC: false), settings: .init(), closedLidBatteryPolicy: policy)
    #expect(at.shouldHold); #expect(!at.emergencySleep)
    let below = engine.evaluate(now: 2, power: .init(percent: 19.9, onAC: false), settings: .init(), closedLidBatteryPolicy: policy)
    #expect(!below.shouldHold); #expect(!below.emergencySleep)
    let off = engine.evaluate(now: 3, power: .init(percent: 6, onAC: false, secondsRemaining: 60), settings: .init(),
                              closedLidBatteryPolicy: .init(cutoffEnabled: false))
    #expect(off.shouldHold); #expect(!off.emergencySleep)
}
