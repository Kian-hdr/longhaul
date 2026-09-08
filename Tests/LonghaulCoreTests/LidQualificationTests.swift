import Foundation
import Testing
import LonghaulCore
import LonghaulBridge

private let lidNormal = LidRegistrySnapshot(lidClosed: false, clamshellCausesSleep: true, sleepDisabled: false)
private let lidSuccess = LidMutationResult(serviceFound: true, openResult: 0, callResult: 0, closeResult: 0)

private func lidConditions(active: Bool = false) -> LidProbeConditions {
    .init(registry: .init(lidClosed: false, clamshellCausesSleep: !active, sleepDisabled: false),
          power: .init(percent: 70, onAC: true, discharging: false), clientAlive: true,
          monitorAlive: true, coOwnerScanComplete: true, knownCoOwners: [])
}

/// Executes only in-memory fake writes. These tests never call the native backend.
private struct FakeLidBackend {
    var writes: [Bool] = []
    var snapshot = lidNormal
    mutating func apply(_ directive: LidProbeDirective) -> LidMutationResult {
        switch directive {
        case .disableClamshellSleep: writes.append(true); snapshot.clamshellCausesSleep = false
        case .enableClamshellSleep: writes.append(false); snapshot.clamshellCausesSleep = true
        default: Issue.record("Unexpected fake mutation directive")
        }
        return lidSuccess
    }
}

@Test func lidQualificationLeaseHasAcceptedBalancingClear() {
    var session = LidQualificationSession(); var backend = FakeLidBackend()
    let start = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    #expect(start == .disableClamshellSleep)
    #expect(session.didEnable(backend.apply(start), now: 100) == .inspectPolicy)
    #expect(session.poll(now: 129, conditions: lidConditions(active: true)) == .none)
    let expiry = session.poll(now: 130, conditions: lidConditions(active: true))
    #expect(expiry == .enableClamshellSleep)
    #expect(session.stopReason == .leaseExpired)
    #expect(session.didDisable(backend.apply(expiry)) == .inspectPolicy)
    #expect(session.cleanupOutstanding)
    _ = session.observeCleanup(backend.snapshot)
    #expect(session.phase == .completed)
    #expect(session.cleanupCallAccepted)
    #expect(!session.cleanupOutstanding)
    #expect(backend.writes == [true, false])
}

@Test func lidQualificationRenewalsCannotExceedAbsoluteSessionCap() {
    var session = LidQualificationSession()
    #expect(session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true) == .disableClamshellSleep)
    _ = session.didEnable(lidSuccess, now: 100)
    #expect(session.heartbeat(now: 120, conditions: lidConditions(active: true)) == .none)
    #expect(session.leaseDeadline == 150)
    #expect(session.heartbeat(now: 140, conditions: lidConditions(active: true)) == .none)
    #expect(session.leaseDeadline == 160)
    #expect(session.heartbeat(now: 159, conditions: lidConditions(active: true)) == .none)
    #expect(session.leaseDeadline == 160)
    #expect(session.heartbeat(now: 160, conditions: lidConditions(active: true)) == .enableClamshellSleep)
    #expect(session.stopReason == .sessionExpired)
    #expect(session.heartbeat(now: 161, conditions: lidConditions(active: true)) == .none)
    #expect(session.start(now: 162, conditions: lidConditions(), explicitlyAuthorized: true) == .none)
}

@Test func lidQualificationExpiredHeartbeatCannotReviveLease() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    #expect(session.heartbeat(now: 130, conditions: lidConditions(active: true)) == .enableClamshellSleep)
    #expect(session.leaseDeadline == 130)
}

@Test func lidQualificationRequiresAllStartupGates() {
    var unauthorized = LidQualificationSession()
    #expect(unauthorized.start(now: 0, conditions: lidConditions(), explicitlyAuthorized: false) == .none)
    #expect(unauthorized.stopReason == .authorizationMissing)
    let changes: [(inout LidProbeConditions) -> Void] = [
        { $0.registry.lidClosed = true }, { $0.registry.lidClosed = nil },
        { $0.registry.clamshellCausesSleep = false }, { $0.registry.clamshellCausesSleep = nil },
        { $0.registry.sleepDisabled = true }, { $0.registry.sleepDisabled = nil },
        { $0.power.percent = 29.99 }, { $0.power.percent = nil }, { $0.power.percent = .nan },
        { $0.power.percent = 101 }, { $0.power.onAC = false }, { $0.power.discharging = true },
        { $0.batteryStage = .prepare }, { $0.batteryStage = .critical }, { $0.power.warningLevel = 2 },
        { $0.power.thermalLevel = 1 }, { $0.clientAlive = false }, { $0.monitorAlive = false },
        { $0.coOwnerScanComplete = false }, { $0.knownCoOwners = ["Amphetamine"] }
    ]
    for change in changes {
        var conditions = lidConditions(); change(&conditions)
        var session = LidQualificationSession()
        #expect(session.start(now: 0, conditions: conditions, explicitlyAuthorized: true) == .none)
        #expect(session.phase == .refused)
        #expect(!session.cleanupOutstanding)
    }
    var boundary = LidQualificationSession(); var conditions = lidConditions(); conditions.power.percent = 30
    #expect(boundary.start(now: 0, conditions: conditions, explicitlyAuthorized: true) == .disableClamshellSleep)
}

@Test func lidQualificationInvalidLeaseAndClockRefused() {
    for (lease, cap) in [(29.0, 60.0), (61, 61), (30, 61), (40, 30), (.nan, 60), (30, .infinity)] {
        var session = LidQualificationSession()
        #expect(session.start(now: 0, conditions: lidConditions(), explicitlyAuthorized: true,
                              leaseSeconds: lease, sessionCapSeconds: cap) == .none)
        #expect(session.stopReason == .invalidDuration)
    }
    for now in [-1.0, .nan, .infinity] {
        var session = LidQualificationSession()
        #expect(session.start(now: now, conditions: lidConditions(), explicitlyAuthorized: true) == .none)
        #expect(session.stopReason == .invalidClock)
    }
}

@Test func lidQualificationSafetySignalsReleaseWithoutWaitingForLease() {
    let changes: [(LidProbeReason, (inout LidProbeConditions) -> Void)] = [
        (.clientExited, { $0.clientAlive = false }), (.monitorUnavailable, { $0.monitorAlive = false }),
        (.batteryPrepare, { $0.batteryStage = .prepare }), (.batteryPrepare, { $0.batteryStage = .critical }),
        (.batteryPrepare, { $0.power.warningLevel = 2 }), (.thermal, { $0.power.thermalLevel = 2 }),
        (.powerUnavailable, { $0.power.onAC = false }), (.powerUnavailable, { $0.power.discharging = true }),
        (.powerUnavailable, { $0.power.percent = 29 }), (.powerUnavailable, { $0.power.percent = nil })
    ]
    for (reason, change) in changes {
        var session = LidQualificationSession()
        _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
        _ = session.didEnable(lidSuccess, now: 100)
        var conditions = lidConditions(active: true); change(&conditions)
        #expect(session.poll(now: 101, conditions: conditions) == .enableClamshellSleep)
        #expect(session.stopReason == reason)
        #expect(session.poll(now: 102, conditions: conditions) == .none)
    }
}

@Test func lidQualificationAllowsLidClosureOnlyAfterStart() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    var closed = lidConditions(active: true); closed.registry.lidClosed = true
    #expect(session.poll(now: 101, conditions: closed) == .none)
    #expect(session.phase == .active)
}

@Test func lidQualificationNeverReassertsAfterPowerdPolicyChange() {
    var session = LidQualificationSession(); var backend = FakeLidBackend()
    let start = session.start(now: 0, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(backend.apply(start), now: 0)
    var closed = lidConditions(); closed.registry.lidClosed = true
    let changed = session.poll(now: 1, conditions: closed)
    #expect(changed == .enableClamshellSleep)
    _ = session.didDisable(backend.apply(changed))
    _ = session.observeCleanup(backend.snapshot)
    #expect(session.failures.contains(.policyChanged))
    #expect(session.heartbeat(now: 2, conditions: lidConditions()) == .none)
    #expect(backend.writes.filter { $0 }.count == 1)
}

@Test func lidQualificationChangedOwnerReportsCleanupDebtWithoutBlindClear() {
    for scanComplete in [true, false] {
        var session = LidQualificationSession()
        _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
        _ = session.didEnable(lidSuccess, now: 100)
        var conditions = lidConditions(active: true)
        conditions.coOwnerScanComplete = scanComplete
        if scanComplete { conditions.knownCoOwners = ["New keep-awake owner"] }
        #expect(session.poll(now: 101, conditions: conditions) == .inspectPolicy)
        #expect(session.phase == .cleanupRequired)
        #expect(session.cleanupOutstanding)
        #expect(!session.cleanupCallAccepted)
        #expect(session.poll(now: 161, conditions: conditions) == .none)
    }
}

@Test func lidQualificationFailedClearCannotBeProvenByPublishedSnapshot() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    let failure = LidMutationResult(serviceFound: true, openResult: 0, callResult: -1, closeResult: 0)
    #expect(session.didEnable(failure, now: 100) == .enableClamshellSleep)
    #expect(session.failures == [.enableFailed])
    #expect(session.didDisable(failure) == .inspectPolicy)
    #expect(session.phase == .cleanupRequired)
    _ = session.observeCleanup(.init(lidClosed: false, clamshellCausesSleep: false, sleepDisabled: false))
    #expect(session.failures.contains(.cleanupUnconfirmed))
    _ = session.observeCleanup(lidNormal)
    #expect(session.phase == .cleanupRequired)
    #expect(!session.cleanupCallAccepted)
    #expect(session.failures == [.enableFailed, .disableFailed, .cleanupUnconfirmed])
}

@Test func lidQualificationUnknownCleanupIsNotSuccess() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    #expect(session.stop() == .enableClamshellSleep)
    _ = session.didDisable(lidSuccess)
    _ = session.observeCleanup(.init(lidClosed: nil, clamshellCausesSleep: nil, sleepDisabled: nil))
    #expect(session.phase == .cleanupRequired)
    #expect(session.cleanupOutstanding)
    #expect(session.cleanupCallAccepted)
}

@Test func lidQualificationClockRegressionAndLateEnableCannotRestart() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    #expect(session.poll(now: 99, conditions: lidConditions(active: true)) == .enableClamshellSleep)
    #expect(session.failures.contains(.invalidClock))
    #expect(session.didEnable(lidSuccess, now: 101) == .none)
    _ = session.didDisable(lidSuccess); _ = session.observeCleanup(lidNormal)
    #expect(session.start(now: 102, conditions: lidConditions(), explicitlyAuthorized: true) == .none)
}

@Test func lidQualificationSlowEnableDoesNotOutliveDeadline() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    #expect(session.didEnable(lidSuccess, now: 130) == .enableClamshellSleep)
    #expect(session.phase == .disabling)
    #expect(session.stopReason == .leaseExpired)
}

@Test func lidQualificationAcceptsKnownStaleOpenLidSnapshotAfterEnable() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    // The setter does not republish the property, so it can remain true.
    #expect(session.poll(now: 101, conditions: lidConditions()) == .none)
    #expect(session.phase == .active)
    #expect(session.failures.isEmpty)
    #expect(session.stop() == .enableClamshellSleep)
}

@Test func lidQualificationAcceptedClearAllowsStaleFalseSnapshot() {
    var session = LidQualificationSession()
    _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
    _ = session.didEnable(lidSuccess, now: 100)
    _ = session.stop()
    _ = session.didDisable(lidSuccess)
    _ = session.observeCleanup(.init(lidClosed: false, clamshellCausesSleep: false, sleepDisabled: false))
    #expect(session.cleanupCallAccepted)
    #expect(session.phase == .completed)
    // Completion records call acceptance, not a physically observed mask clear.
    #expect(session.failures.isEmpty)
}

@Test func lidQualificationRejectsUnknownAndUnsafeSnapshotsWhileActive() {
    let changes: [(inout LidRegistrySnapshot) -> Void] = [
        { $0.lidClosed = nil }, { $0.clamshellCausesSleep = nil },
        { $0.sleepDisabled = nil }, { $0.sleepDisabled = true }
    ]
    for change in changes {
        var session = LidQualificationSession()
        _ = session.start(now: 100, conditions: lidConditions(), explicitlyAuthorized: true)
        _ = session.didEnable(lidSuccess, now: 100)
        var conditions = lidConditions(); change(&conditions.registry)
        #expect(session.poll(now: 101, conditions: conditions) == .enableClamshellSleep)
        #expect(session.failures == [.policyChanged])
    }
}
