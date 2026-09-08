import Foundation
import Testing
import LonghaulBridge
import LonghaulCore

private let sessionIdentity = LidSessionIdentity(bootID: "00000000-0000-4000-8000-000000000001",
                                                sessionID: "00000000-0000-4000-8000-000000000002",
                                                appPID: 1234, appBirth: 42)
private func sessionGrant(_ sequence: UInt64 = 1, evaluated: Double = 100, expiry: Double = 110,
                          kind: LidSessionGrant.Kind = .renew) -> LidSessionGrant {
    .init(identity: sessionIdentity, sequence: sequence, kind: kind, evaluatedAt: evaluated, expiresAt: expiry)
}

@Test func lidSessionFirstGrantAndOriginalDeadline() {
    var lease = LidSessionLease(identity: sessionIdentity)
    #expect(lease.isAuthorized(at: 100) == false)
    #expect(!lease.stopped)
    #expect(lease.accept(sessionGrant(), now: 108, appAlive: true) == true)
    #expect(lease.expiresAt == 110) // Receipt at 108 never creates an expiry of 118.
    #expect(lease.isAuthorized(at: 109.9) == true)
    #expect(lease.isAuthorized(at: 110) == false)
    #expect(lease.stopReason == .expired)
    #expect(lease.accept(sessionGrant(2, evaluated: 110, expiry: 120), now: 110, appAlive: true) == false)
}

@Test func lidSessionFreshRenewalsCanSustainOneSession() {
    var lease = LidSessionLease(identity: sessionIdentity)
    for sequence in UInt64(1)...500 {
        let time = 100 + Double(sequence) * 2
        #expect(lease.accept(sessionGrant(sequence, evaluated: time, expiry: time + 10), now: time, appAlive: true) == true)
    }
    #expect(lease.lastSequence == 500)
    #expect(lease.expiresAt == 1110)
    #expect(lease.isAuthorized(at: 1109) == true)
}

@Test func lidSessionRejectedGrantIsTerminal() {
    let bad: [LidSessionGrant] = [
        sessionGrant(0), sessionGrant(expiry: 111), sessionGrant(evaluated: 101),
        sessionGrant(expiry: 100), sessionGrant(evaluated: -.infinity), sessionGrant(expiry: .nan),
        .init(version: 3, identity: sessionIdentity, sequence: 1, kind: .renew, evaluatedAt: 100, expiresAt: 110),
        .init(identity: .init(bootID: sessionIdentity.bootID, sessionID: UUID().uuidString, appPID: 1234, appBirth: 42),
              sequence: 1, kind: .renew, evaluatedAt: 100, expiresAt: 110),
        .init(identity: .init(bootID: sessionIdentity.bootID, sessionID: sessionIdentity.sessionID, appPID: 1234, appBirth: 43),
              sequence: 1, kind: .renew, evaluatedAt: 100, expiresAt: 110)
    ]
    for grant in bad {
        var lease = LidSessionLease(identity: sessionIdentity)
        #expect(lease.accept(grant, now: 100, appAlive: true) == false)
        #expect(lease.stopped)
        #expect(lease.accept(sessionGrant(), now: 100, appAlive: true) == false)
    }
}

@Test func lidSessionRejectsReplayLateRenewalAndDeadApp() {
    var replay = LidSessionLease(identity: sessionIdentity)
    #expect(replay.accept(sessionGrant(), now: 100, appAlive: true) == true)
    #expect(replay.accept(sessionGrant(), now: 101, appAlive: true) == false)
    #expect(replay.stopReason == .invalidGrant)
    var late = LidSessionLease(identity: sessionIdentity)
    #expect(late.accept(sessionGrant(), now: 100, appAlive: true) == true)
    #expect(late.accept(sessionGrant(2, evaluated: 110, expiry: 120), now: 110, appAlive: true) == false)
    #expect(late.stopReason == .expired)
    var dead = LidSessionLease(identity: sessionIdentity)
    #expect(dead.accept(sessionGrant(), now: 100, appAlive: false) == false)
    #expect(dead.stopReason == .appUnavailable)
}

@Test func lidSessionClockRegressionAndRevocationAreTerminal() {
    var clock = LidSessionLease(identity: sessionIdentity)
    #expect(clock.accept(sessionGrant(), now: 100, appAlive: true) == true)
    #expect(clock.isAuthorized(at: 104) == true)
    #expect(clock.accept(sessionGrant(2, evaluated: 102, expiry: 112), now: 102, appAlive: true) == false)
    #expect(clock.stopReason == .invalidClock)
    var revoked = LidSessionLease(identity: sessionIdentity)
    #expect(revoked.accept(sessionGrant(), now: 100, appAlive: true) == true)
    #expect(revoked.accept(sessionGrant(2, evaluated: 102, expiry: 102, kind: .revoke), now: 102, appAlive: true) == true)
    #expect(revoked.lastSequence == 2)
    #expect(revoked.stopReason == .revoked)
    #expect(revoked.accept(sessionGrant(3, evaluated: 103, expiry: 113), now: 103, appAlive: true) == false)
}

@Test func lidSessionProtocolRoundTripAndStatusValidation() throws {
    let grant = sessionGrant()
    #expect(try JSONDecoder().decode(LidSessionGrant.self, from: JSONEncoder().encode(grant)) == grant)
    let active = LidSessionStatus(identity: sessionIdentity, sequence: 1, observedAt: 100, state: .active, leaseExpiresAt: 110)
    #expect(try JSONDecoder().decode(LidSessionStatus.self, from: JSONEncoder().encode(active)) == active)
    #expect(active.isValid(for: sessionIdentity, after: 0, now: 101))
    #expect(!active.isValid(for: sessionIdentity, after: 1, now: 101))
    #expect(!active.isValid(for: sessionIdentity, after: 0, now: 110))
    #expect(!active.isValid(for: sessionIdentity, after: 0, now: 99))
    let noDeadline = LidSessionStatus(identity: sessionIdentity, sequence: 1, observedAt: 100, state: .active)
    #expect(!noDeadline.isValid(for: sessionIdentity, after: 0, now: 101))
}

@Test func lidSessionBatteryPolicyVersionsAndStrictPresence() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let v2 = sessionGrant()
    #expect(v2.version == 2 && v2.effectiveBatteryPolicy == .init())
    var value = try JSONSerialization.jsonObject(with: encoder.encode(v2)) as! [String: Any]
    for version in [1, 2, 3] {
        for shape in ["absent", "null", "valid", "invalid", "disabledInvalid"] {
            value["version"] = version
            switch shape {
            case "absent": value.removeValue(forKey: "batteryPolicy")
            case "null": value["batteryPolicy"] = NSNull()
            default: value["batteryPolicy"] = ["cutoffEnabled": shape != "disabledInvalid", "cutoffPercent": shape == "valid" ? 20 : 0]
            }
            let grant = try decoder.decode(LidSessionGrant.self, from: JSONSerialization.data(withJSONObject: value))
            var lease = LidSessionLease(identity: sessionIdentity)
            let allowed = (version == 1 && shape == "absent") || (version == 2 && shape == "valid")
            #expect(lease.accept(grant, now: 100, appAlive: true) == allowed)
            #expect(lease.batteryPolicy == (allowed ? LidBatteryPolicy() : nil))
            let roundTrip = try decoder.decode(LidSessionGrant.self, from: encoder.encode(grant))
            #expect(roundTrip == grant && roundTrip.effectiveBatteryPolicy == grant.effectiveBatteryPolicy)
        }
    }
}

@Test func lidSessionBatteryPolicyChangesOnlyThroughAcceptedOriginalGrants() {
    var lease = LidSessionLease(identity: sessionIdentity)
    #expect(lease.batteryPolicy == nil)
    #expect(lease.accept(sessionGrant(), now: 100, appAlive: true) == true)
    let off = LidSessionGrant(identity: sessionIdentity, sequence: 2, kind: .renew, evaluatedAt: 101, expiresAt: 111,
                              batteryPolicy: .init(cutoffEnabled: false, cutoffPercent: 40))
    #expect(lease.accept(off, now: 101, appAlive: true) == true)
    #expect(lease.batteryPolicy == off.batteryPolicy && lease.expiresAt == 111)
    let invalid = LidSessionGrant(identity: sessionIdentity, sequence: 3, kind: .renew, evaluatedAt: 102, expiresAt: 112,
                                  batteryPolicy: .init(cutoffPercent: 0))
    #expect(lease.accept(invalid, now: 102, appAlive: true) == false)
    #expect(lease.batteryPolicy == off.batteryPolicy && lease.stopReason == .invalidGrant)
    #expect(lease.accept(.init(identity: sessionIdentity, sequence: 4, kind: .renew, evaluatedAt: 103, expiresAt: 113),
                         now: 103, appAlive: true) == false)
}

@Test func lidSessionBatteryPolicyGrantFitsAtomicAppTransport() throws {
    let identity = LidSessionIdentity(bootID: UUID().uuidString, sessionID: UUID().uuidString,
                                      appPID: Int32.max, appBirth: UInt64.max)
    let grant = LidSessionGrant(identity: identity, sequence: UInt64.max, kind: .revoke,
                                evaluatedAt: Double.greatestFiniteMagnitude, expiresAt: Double.greatestFiniteMagnitude,
                                batteryPolicy: .init(cutoffEnabled: false, cutoffPercent: 100))
    #expect(try JSONEncoder().encode(grant).count < 511)
}
