import Foundation
import Testing
@testable import LonghaulCore

private struct CoordinationFixture {
    var broker: CoordinationBroker
    var sequence: [String: Int] = [:]
    var principal: [String: String] = [:]
    init(initiallyFenced: Bool = false, windows: Set<String> = []) {
        broker = CoordinationBroker(initiallyFenced: initiallyFenced, qualifiedWindowApplications: windows)
    }
    mutating func client(_ principal: String, incarnation: String = UUID().uuidString, at time: Double = 0) throws -> CoordinationClient {
        let value = try broker.register(principal: principal, incarnation: incarnation, now: time)
        self.principal[value.id] = principal; return value
    }
    mutating func send(_ client: CoordinationClient, _ operation: CoordinationOperation, at time: Double = 0) -> CoordinationReply {
        sequence[client.id, default: 0] += 1
        return broker.exchange(.init(client: client, sequence: sequence[client.id]!, operation: operation),
                               authenticatedPrincipal: principal[client.id]!, now: time)
    }
    mutating func reserve(_ client: CoordinationClient, _ resources: [CoordinationResource], at time: Double = 0) -> CoordinationReply {
        send(client, .reserve(taskID: UUID().uuidString, resources: resources), at: time)
    }
}

struct CoordinationTests {
    @Test func independentBackgroundAgentsCoexist() throws {
        var f = CoordinationFixture(); let a = try f.client("peer-a"), b = try f.client("peer-b")
        let left = f.reserve(a, [.application("app.a")]), right = f.reserve(b, [.application("app.b")])
        #expect(left.disposition == .granted && right.disposition == .granted)
        #expect(left.activity == .workingInBackground && right.activity == .workingInBackground)
        #expect(f.broker.snapshot().reservations.count == 2)
    }

    @Test func sameAppUsesFIFOWithoutPartialAcquisition() throws {
        var f = CoordinationFixture()
        let a = try f.client("a"), b = try f.client("b"), c = try f.client("c"), d = try f.client("d")
        let held = try #require(f.reserve(a, [.application("app.a")]).permit)
        let first = f.reserve(b, [.application("app.a"), .application("app.b")])
        let second = f.reserve(c, [.application("app.b")])
        let independent = f.reserve(d, [.application("app.c")])
        #expect(first.disposition == .queued && first.permit == nil)
        #expect(second.disposition == .queued && second.permit == nil)
        #expect(independent.disposition == .granted)
        _ = f.send(a, .release(permitID: held.id, fence: held.fence), at: 1)
        let firstAfter = f.send(b, .poll(ticketID: first.ticketID!), at: 1)
        let secondAfter = f.send(c, .poll(ticketID: second.ticketID!), at: 1)
        #expect(firstAfter.disposition == .granted)
        #expect(firstAfter.permit?.resources.count == 2)
        #expect(secondAfter.disposition == .queued)
    }

    @Test func cancellingAnEarlierTicketLetsAnIndependentResourceProceed() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b"), c = try f.client("c")
        _ = f.reserve(a, [.application("app.a")])
        let first = f.reserve(b, [.application("app.a"), .application("app.b")])
        let next = f.reserve(c, [.application("app.b")])
        _ = f.send(b, .cancel(ticketID: first.ticketID!))
        let result = f.send(c, .poll(ticketID: next.ticketID!))
        #expect(result.disposition == .granted)
        let cancelledAgain = f.send(b, .cancel(ticketID: first.ticketID!))
        #expect(cancelledAgain.disposition == .cancelled)
    }

    @Test func foregroundAndClipboardSerializeWhileBackgroundContinues() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b"), c = try f.client("c")
        let first = f.reserve(a, [.application("app.a"), .foreground, .clipboard])
        let second = f.reserve(b, [.application("app.b"), .foreground])
        let third = f.reserve(c, [.application("app.c")])
        #expect(first.activity == .workingInForeground)
        #expect(second.disposition == .queued && third.disposition == .granted)
        let clipboard = f.reserve(c, [.clipboard])
        #expect(clipboard.disposition == .queued)
        let underspecified = f.reserve(c, [.foreground])
        #expect(underspecified.failure == .invalidInput)
    }

    @Test func windowConcurrencyRequiresQualificationAndAppLockStillWins() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let first = f.reserve(a, [.window(application: "editor", instance: "pid1", window: "one")])
        let second = f.reserve(b, [.window(application: "editor", instance: "pid1", window: "two")])
        #expect(first.permit?.resources == [.application("editor")])
        #expect(second.disposition == .queued)
        var qualified = CoordinationFixture(windows: ["editor"])
        let x = try qualified.client("a"), y = try qualified.client("b"), z = try qualified.client("c")
        let one = qualified.reserve(x, [.window(application: "editor", instance: "pid1", window: "one")])
        let two = qualified.reserve(y, [.window(application: "editor", instance: "pid1", window: "two")])
        let broad = qualified.reserve(z, [.application("editor")])
        #expect(one.disposition == .granted && two.disposition == .granted)
        #expect(broad.disposition == .queued)
    }

    @Test func independentBrowserSessionsRespectBroaderProfileAndAppScopes() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b"), c = try f.client("c")
        let one = f.reserve(a, [.browserSession(application: "browser", profile: "p1", session: "s1")])
        let two = f.reserve(b, [.browserSession(application: "browser", profile: "p2", session: "s2")])
        #expect(one.disposition == .granted && two.disposition == .granted)
        let profile = f.reserve(c, [.browserProfile(application: "browser", profile: "p1")])
        let broad = f.reserve(c, [.application("browser")])
        #expect(profile.disposition == .queued && broad.disposition == .queued)
    }

    @Test func humanPriorityRevokesUnusedPermitsAndRequiresNewObservation() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b"), c = try f.client("c")
        let first = try #require(f.reserve(a, [.application("app.a")]).permit)
        let waiting = f.reserve(b, [.application("app.a")])
        try f.broker.setHumanPriority([.application("app.a")], now: 1)
        let oldAction = f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 1), at: 1)
        #expect(oldAction.failure == .invalidPermit)
        let blocked = f.send(b, .poll(ticketID: waiting.ticketID!), at: 1)
        #expect(blocked.activity == .yieldingToHuman)
        let other = f.reserve(c, [.application("app.b")], at: 1)
        #expect(other.disposition == .granted)
        try f.broker.setHumanPriority([], now: 2)
        let fresh = try #require(f.send(b, .poll(ticketID: waiting.ticketID!), at: 2).permit)
        let staleObservation = f.send(b, .beginAction(permitID: fresh.id, fence: fresh.fence, observedAt: 0), at: 2)
        #expect(staleObservation.failure == .observationRequired)
        let action = f.send(b, .beginAction(permitID: fresh.id, fence: fresh.fence, observedAt: 2), at: 2)
        #expect(action.disposition == .actionBegan)
    }

    @Test func humanTakeoverDoesNotPretendToStopAnInFlightAction() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let first = try #require(f.reserve(a, [.application("app"), .foreground]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 1), at: 1).action)
        let waiting = f.reserve(b, [.application("app"), .foreground], at: 1)
        try f.broker.setHumanPriority([.foreground], now: 2)
        let status = f.broker.snapshot()
        #expect(status.fences.count == 1)
        #expect(status.reservations.contains(where: { $0.disposition == .fenced && $0.activity == .yieldingToHuman }))
        let release = f.send(a, .release(permitID: first.id, fence: first.fence), at: 2)
        #expect(release.failure == .resourcesFenced)
        try f.broker.setHumanPriority([], now: 3)
        let stillBlocked = f.send(b, .poll(ticketID: waiting.ticketID!), at: 3)
        #expect(stillBlocked.disposition == .queued)
        _ = f.send(a, .endAction(actionID: action.id, outcome: .completed), at: 4)
        let next = f.send(b, .poll(ticketID: waiting.ticketID!), at: 4)
        #expect(next.disposition == .granted && next.permit?.observationAfter == 4)
    }

    @Test func idleExpiryCleansUpWithoutRevivingAnOldPermit() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let first = try #require(f.reserve(a, [.application("app")]).permit)
        let waiting = f.reserve(b, [.application("app")])
        try f.broker.advance(to: 15)
        let next = f.send(b, .poll(ticketID: waiting.ticketID!), at: 15)
        #expect(next.disposition == .granted)
        let lateRenew = f.send(a, .renew(permitID: first.id, fence: first.fence), at: 15)
        #expect(lateRenew.failure == .invalidPermit)
        let lateAction = f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 15), at: 15)
        #expect(lateAction.failure == .invalidPermit)
    }

    @Test func inFlightExpiryRemainsFencedUntilCompletionIsConfirmed() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let first = try #require(f.reserve(a, [.application("app")]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 1), at: 1).action)
        let waiting = f.reserve(b, [.application("app")], at: 1)
        for time in stride(from: 10.0, through: 100.0, by: 10) {
            _ = f.send(b, .poll(ticketID: waiting.ticketID!), at: time)
        }
        #expect(f.broker.snapshot().fences.count == 1)
        let blocked = f.send(b, .poll(ticketID: waiting.ticketID!), at: 100)
        #expect(blocked.disposition == .queued)
        _ = f.send(a, .endAction(actionID: action.id, outcome: .completed), at: 100)
        let safe = f.send(b, .poll(ticketID: waiting.ticketID!), at: 100)
        #expect(safe.disposition == .granted)
    }

    @Test func indeterminateActionCannotBeReleasedByAnOrdinaryReleaseRequest() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let first = try #require(f.reserve(a, [.application("app")]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 0)).action)
        let waiting = f.reserve(b, [.application("app")])
        let uncertain = f.send(a, .endAction(actionID: action.id, outcome: .indeterminate))
        #expect(uncertain.disposition == .fenced)
        let release = f.send(a, .release(permitID: first.id, fence: first.fence))
        #expect(release.failure == .resourcesFenced)
        try f.broker.confirmSafeRelease(fenceID: first.id, evidence: .executorConfirmedStopped, now: 1)
        let next = f.send(b, .poll(ticketID: waiting.ticketID!), at: 1)
        #expect(next.disposition == .granted)
    }

    @Test func disconnectAndNewIncarnationCannotClearAmbiguousWork() throws {
        var f = CoordinationFixture(); let a = try f.client("a", incarnation: "first"), b = try f.client("b")
        let first = try #require(f.reserve(a, [.application("app")]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: first.id, fence: first.fence, observedAt: 0)).action)
        let waiting = f.reserve(b, [.application("app")])
        _ = f.send(a, .disconnect)
        let replacement = try f.client("a", incarnation: "second", at: 1)
        #expect(replacement.id != a.id)
        let old = f.send(a, .endAction(actionID: action.id, outcome: .completed), at: 1)
        #expect(old.failure == .unauthenticated)
        let blocked = f.send(b, .poll(ticketID: waiting.ticketID!), at: 1)
        #expect(blocked.disposition == .queued)
        try f.broker.confirmSafeRelease(fenceID: first.id, evidence: .executorConfirmedStopped, now: 1)
        let next = f.send(b, .poll(ticketID: waiting.ticketID!), at: 1)
        #expect(next.disposition == .granted)
    }

    @Test func restartRotatesEpochAndReconcilesPersistedReservations() throws {
        var f = CoordinationFixture(); let oldClient = try f.client("a")
        let first = try #require(f.reserve(oldClient, [.application("app")]).permit)
        let persisted = try JSONEncoder().encode(f.broker)
        f.broker = try JSONDecoder().decode(CoordinationBroker.self, from: persisted)
        try f.broker.restart(now: 1)
        #expect(f.broker.epoch != oldClient.epoch)
        let stale = f.send(oldClient, .beginAction(permitID: first.id, fence: first.fence, observedAt: 1), at: 1)
        #expect(stale.failure == .staleEpoch)
        let nextClient = try f.client("a", at: 1)
        let waiting = f.reserve(nextClient, [.application("app")], at: 1)
        #expect(waiting.disposition == .queued)
        try f.broker.confirmSafeRelease(fenceID: first.id, evidence: .userConfirmedSafe, now: 2)
        let granted = f.send(nextClient, .poll(ticketID: waiting.ticketID!), at: 2)
        #expect(granted.disposition == .granted && granted.permit?.epoch == f.broker.epoch)
    }

    @Test func coldStartDefaultsToReconciliationAndPreservesHumanPauseAcrossRestart() throws {
        var f = CoordinationFixture(initiallyFenced: true); let a = try f.client("a")
        let waiting = f.reserve(a, [.application("app")])
        #expect(waiting.disposition == .queued)
        let fence = try #require(f.broker.snapshot().fences.first)
        try f.broker.setHumanPriority([.application("app")], now: 1)
        try f.broker.restart(now: 1)
        #expect(f.broker.snapshot().humanPriority == [.application("app")])
        try f.broker.confirmSafeRelease(fenceID: fence.id, evidence: .userConfirmedSafe, now: 1)
        let newClient = try f.client("a", at: 1)
        let paused = f.reserve(newClient, [.application("app")], at: 1)
        #expect(paused.activity == .yieldingToHuman)
    }

    @Test func oneActionAtATimeAndFreshObservationAfterEveryAction() throws {
        var f = CoordinationFixture(); let a = try f.client("a")
        let permit = try #require(f.reserve(a, [.application("app")]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 0)).action)
        let overlapping = f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 0))
        #expect(overlapping.failure == .actionInFlight)
        _ = f.send(a, .endAction(actionID: action.id, outcome: .completed), at: 2)
        let stale = f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 0), at: 2)
        #expect(stale.failure == .observationRequired)
        let future = f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 3), at: 2)
        #expect(future.failure == .observationRequired)
        let fresh = f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 2), at: 2)
        #expect(fresh.disposition == .actionBegan)
    }

    @Test func actionReplayDoesNotAuthorizeExecutionAgain() throws {
        var f = CoordinationFixture(); let a = try f.client("a")
        let permit = try #require(f.reserve(a, [.application("app")]).permit)
        let message = CoordinationEnvelope(client: a, sequence: 2,
            operation: .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 0))
        let first = f.broker.exchange(message, authenticatedPrincipal: "a", now: 0)
        let duplicate = f.broker.exchange(message, authenticatedPrincipal: "a", now: 0)
        #expect(first.disposition == .actionBegan)
        #expect(duplicate.disposition == .duplicate && duplicate.action == nil && duplicate.permit == nil)
        var changed = message; changed.operation = .disconnect
        let reuse = f.broker.exchange(changed, authenticatedPrincipal: "a", now: 0)
        #expect(reuse.failure == .requestIDReused)
    }

    @Test func authenticatedOwnerAndSequenceCannotBeSpoofed() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let permit = try #require(f.reserve(a, [.application("app")]).permit)
        let stolen = f.send(b, .release(permitID: permit.id, fence: permit.fence))
        #expect(stolen.failure == .invalidPermit)
        let request = CoordinationEnvelope(client: a, sequence: 2, operation: .disconnect)
        let forged = f.broker.exchange(request, authenticatedPrincipal: "b", now: 0)
        #expect(forged.failure == .unauthenticated)
        let stale = f.broker.exchange(.init(client: a, sequence: 1, operation: .disconnect), authenticatedPrincipal: "a", now: 0)
        #expect(stale.failure == .staleSequence)
        var invalid = request; invalid.version = 2
        let version = f.broker.exchange(invalid, authenticatedPrincipal: "a", now: 0)
        #expect(version.failure == .unsupportedVersion)
    }

    @Test func renewalsRequireASafeBoundaryAtTheHardDeadline() throws {
        var f = CoordinationFixture(); let a = try f.client("a")
        let permit = try #require(f.reserve(a, [.application("app")]).permit)
        for time in stride(from: 10.0, through: 50.0, by: 10) {
            let renewal = f.send(a, .renew(permitID: permit.id, fence: permit.fence), at: time)
            #expect(renewal.disposition == .renewed)
            #expect(renewal.permit!.expiresAt <= 60)
        }
        let final = f.send(a, .renew(permitID: permit.id, fence: permit.fence), at: 59)
        #expect(final.permit?.expiresAt == 60)
        let expired = f.send(a, .renew(permitID: permit.id, fence: permit.fence), at: 60)
        #expect(expired.failure == .invalidPermit)
    }

    @Test func boundsAndClockAreValidatedWithoutCreatingClaims() throws {
        var f = CoordinationFixture(); let a = try f.client("a")
        let oversized = f.reserve(a, [.application(String(repeating: "a", count: 181))])
        #expect(oversized.failure == .invalidInput)
        let excessive = f.send(a, .reserve(taskID: "task", resources: [.application("a")], leaseSeconds: 600))
        #expect(excessive.failure == .invalidInput)
        #expect(f.broker.snapshot().reservations.isEmpty)
        for i in 0..<8 { _ = f.reserve(a, [.application("app.\(i)")]) }
        let ninth = f.reserve(a, [.application("app.9")])
        #expect(ninth.failure == .limitReached)
        try f.broker.advance(to: 1)
        let backwards = f.send(a, .disconnect, at: 0)
        let invalid = f.send(a, .disconnect, at: .nan)
        #expect(backwards.failure == .invalidClock && invalid.failure == .invalidClock)
    }

    @Test func abandonedQueueTicketsExpireWithoutBlockingLaterWork() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b"), c = try f.client("c")
        let permit = try #require(f.reserve(a, [.application("app.a")]).permit)
        let action = try #require(f.send(a, .beginAction(permitID: permit.id, fence: permit.fence, observedAt: 0)).action)
        let abandoned = f.reserve(b, [.application("app.a"), .application("app.b")])
        let active = f.reserve(c, [.application("app.b")])
        _ = f.send(c, .poll(ticketID: active.ticketID!), at: 20)
        try f.broker.advance(to: 30)
        let expired = f.send(b, .poll(ticketID: abandoned.ticketID!), at: 30)
        let next = f.send(c, .poll(ticketID: active.ticketID!), at: 30)
        #expect(expired.disposition == .cancelled)
        #expect(next.disposition == .granted)
        #expect(f.broker.snapshot().fences.count == 1)
        _ = f.send(a, .endAction(actionID: action.id, outcome: .completed), at: 30)
    }

    @Test func rebootClockResetStillInvalidatesAndFencesPriorPermits() throws {
        var f = CoordinationFixture(); let a = try f.client("a", at: 100)
        let permit = try #require(f.reserve(a, [.application("app")], at: 100).permit)
        try f.broker.restart(now: 0)
        #expect(f.broker.epoch != a.epoch)
        #expect(f.broker.snapshot().fences.contains(where: { $0.id == permit.id }))
    }

    @Test func releaseAndDisconnectAreIdempotentAtSafeBoundaries() throws {
        var f = CoordinationFixture(); let a = try f.client("a"), b = try f.client("b")
        let permit = try #require(f.reserve(a, [.application("app")]).permit)
        let queued = f.reserve(b, [.application("app")])
        _ = f.send(a, .release(permitID: permit.id, fence: permit.fence))
        let released = f.send(a, .release(permitID: permit.id, fence: permit.fence))
        #expect(released.disposition == .released)
        let next = f.send(b, .poll(ticketID: queued.ticketID!))
        #expect(next.disposition == .granted)
        let request = CoordinationEnvelope(client: a, sequence: 20, operation: .disconnect)
        let disconnect = f.broker.exchange(request, authenticatedPrincipal: "a", now: 0)
        let duplicate = f.broker.exchange(request, authenticatedPrincipal: "a", now: 0)
        #expect(disconnect.disposition == .disconnected && duplicate.disposition == .duplicate)
    }
}
