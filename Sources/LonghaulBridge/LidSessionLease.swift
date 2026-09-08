import Foundation
import LonghaulCore

/// Incarnation of the app that evaluated policy. A helper must independently
/// verify the process birth and obtain bootID locally, never from an untrusted grant.
public struct LidSessionIdentity: Codable, Sendable, Equatable {
    public let bootID: String
    public let sessionID: String
    public let appPID: Int32
    public let appBirth: UInt64
    public init(bootID: String, sessionID: String, appPID: Int32, appBirth: UInt64) {
        self.bootID = bootID; self.sessionID = sessionID; self.appPID = appPID; self.appBirth = appBirth
    }
    public var isValid: Bool {
        UUID(uuidString: bootID) != nil && UUID(uuidString: sessionID) != nil && appPID > 1 && appBirth != 0
    }
    public static func currentBootID() -> String? { try? LidSessionLedger.currentBootID() }
}

/// Grants continue a single admitted hold. They never authorize another enable.
/// Both timestamps use mach_continuous_time seconds from the original app.
public struct LidSessionGrant: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case renew, revoke }
    public let version: Int
    public let identity: LidSessionIdentity
    public let sequence: UInt64
    public let kind: Kind
    public let evaluatedAt: Double
    public let expiresAt: Double
    public let batteryPolicy: LidBatteryPolicy?
    private let policyFieldPresent: Bool
    public init(version: Int = 2, identity: LidSessionIdentity, sequence: UInt64, kind: Kind,
                evaluatedAt: Double, expiresAt: Double, batteryPolicy: LidBatteryPolicy? = .init()) {
        self.version = version; self.identity = identity; self.sequence = sequence
        self.kind = kind; self.evaluatedAt = evaluatedAt; self.expiresAt = expiresAt
        self.batteryPolicy = batteryPolicy; self.policyFieldPresent = batteryPolicy != nil
    }
    /// Legacy grants can use the historical default only when the policy key was
    /// absent. Explicit null or a policy attached to v1 must not downgrade v2.
    public var effectiveBatteryPolicy: LidBatteryPolicy? {
        if version == 1, !policyFieldPresent, batteryPolicy == nil { return .init() }
        if version == 2, let batteryPolicy, batteryPolicy.isValid { return batteryPolicy }
        return nil
    }
    private enum CodingKeys: String, CodingKey {
        case version, identity, sequence, kind, evaluatedAt, expiresAt, batteryPolicy
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        identity = try values.decode(LidSessionIdentity.self, forKey: .identity)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        kind = try values.decode(Kind.self, forKey: .kind)
        evaluatedAt = try values.decode(Double.self, forKey: .evaluatedAt)
        expiresAt = try values.decode(Double.self, forKey: .expiresAt)
        policyFieldPresent = values.contains(.batteryPolicy)
        batteryPolicy = try values.decodeIfPresent(LidBatteryPolicy.self, forKey: .batteryPolicy)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(identity, forKey: .identity)
        try values.encode(sequence, forKey: .sequence); try values.encode(kind, forKey: .kind)
        try values.encode(evaluatedAt, forKey: .evaluatedAt); try values.encode(expiresAt, forKey: .expiresAt)
        if policyFieldPresent { try values.encode(batteryPolicy, forKey: .batteryPolicy) }
    }
}

/// Fail-closed validation shared by the monitor and watchdog. Instantiate once
/// per admitted session, not once per message. No receipt-time lease extension.
public struct LidSessionLease: Sendable {
    public enum StopReason: String, Codable, Sendable { case revoked, expired, appUnavailable, invalidClock, invalidGrant }
    public static let maximumLifetime: Double = 10
    public let identity: LidSessionIdentity
    public private(set) var lastSequence: UInt64 = 0
    public private(set) var evaluatedAt: Double?
    public private(set) var expiresAt: Double?
    public private(set) var batteryPolicy: LidBatteryPolicy?
    public private(set) var stopped = false
    public private(set) var stopReason: StopReason?
    private var lastObservation: Double?
    public init(identity: LidSessionIdentity) {
        self.identity = identity; stopped = !identity.isValid
        stopReason = identity.isValid ? nil : .invalidGrant
    }

    @discardableResult public mutating func accept(_ grant: LidSessionGrant, now: Double, appAlive: Bool) -> Bool {
        guard !stopped else { return false }
        guard appAlive else { stop(.appUnavailable); return false }
        guard now.isFinite, now >= 0, lastObservation.map({ now >= $0 }) ?? true else {
            stop(.invalidClock); return false
        }
        guard expiresAt.map({ now < $0 }) ?? true else { stop(.expired); return false }
        guard
              let policy = grant.effectiveBatteryPolicy, grant.identity == identity, grant.sequence > lastSequence,
              grant.evaluatedAt.isFinite, grant.expiresAt.isFinite, grant.evaluatedAt >= 0,
              grant.evaluatedAt <= now,
              evaluatedAt.map({ grant.evaluatedAt >= $0 }) ?? true else { stop(.invalidGrant); return false }
        switch grant.kind {
        case .renew:
            guard grant.expiresAt > now, grant.expiresAt > grant.evaluatedAt,
                  grant.expiresAt - grant.evaluatedAt <= Self.maximumLifetime else { stop(.invalidGrant); return false }
        case .revoke:
            guard grant.expiresAt == grant.evaluatedAt else { stop(.invalidGrant); return false }
            stop(.revoked)
        }
        lastSequence = grant.sequence; evaluatedAt = grant.evaluatedAt
        expiresAt = grant.expiresAt; lastObservation = now; batteryPolicy = policy
        return true
    }

    public mutating func isAuthorized(at now: Double) -> Bool {
        guard !stopped else { return false }
        guard now.isFinite, now >= 0, lastObservation.map({ now >= $0 }) ?? true else {
            stop(.invalidClock); return false
        }
        lastObservation = now
        guard let expiresAt else { return false }
        guard now < expiresAt else { stop(.expired); return false }
        return true
    }
    public mutating func revoke() { stop(.revoked) }
    private mutating func stop(_ reason: StopReason) { stopped = true; if stopReason == nil { stopReason = reason } }
}

/// Runtime observations, not a certificate of physical continuity or ownership.
public struct LidSessionStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case starting, active, stopping, stopped, unavailable, cleanupRequired
    }
    public let version: Int
    public let identity: LidSessionIdentity
    public let sequence: UInt64
    public let observedAt: Double
    public let state: State
    public let reason: String?
    public let leaseExpiresAt: Double?
    public init(version: Int = 1, identity: LidSessionIdentity, sequence: UInt64, observedAt: Double,
                state: State, reason: String? = nil, leaseExpiresAt: Double? = nil) {
        self.version = version; self.identity = identity; self.sequence = sequence
        self.observedAt = observedAt; self.state = state; self.reason = reason; self.leaseExpiresAt = leaseExpiresAt
    }
    public func isValid(for expected: LidSessionIdentity, after sequence: UInt64, now: Double,
                        maximumAge: Double = LidSessionLease.maximumLifetime) -> Bool {
        version == 1 && identity.isValid && identity == expected && self.sequence > sequence &&
            now.isFinite && observedAt.isFinite && observedAt >= 0 && observedAt <= now &&
            maximumAge.isFinite && maximumAge > 0 && now - observedAt <= maximumAge &&
            (reason?.utf8.count ?? 0) <= 1024 &&
            (leaseExpiresAt.map { $0.isFinite && $0 >= 0 && $0 <= observedAt + LidSessionLease.maximumLifetime } ?? true) &&
            (state != .active || leaseExpiresAt.map { $0 > now } == true)
    }
}
