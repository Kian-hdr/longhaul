import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import LonghaulCore

/// Aggregate observations, never an ownership token for the shared clamshell bit.
public struct LidRegistrySnapshot: Codable, Sendable, Equatable {
    public var lidClosed: Bool?
    public var clamshellCausesSleep: Bool?
    public var sleepDisabled: Bool?
    public init(lidClosed: Bool?, clamshellCausesSleep: Bool?, sleepDisabled: Bool?) {
        self.lidClosed = lidClosed; self.clamshellCausesSleep = clamshellCausesSleep
        self.sleepDisabled = sleepDisabled
    }
    public var normalOpenLidPolicy: Bool { lidClosed == false && clamshellCausesSleep == true && sleepDisabled == false }
    /// These published values may lag selector writes. This validates a readable
    /// snapshot, not the hidden mask or a successful cleanup.
    public var policySnapshotKnown: Bool {
        lidClosed != nil && clamshellCausesSleep != nil && sleepDisabled == false
    }
}

public struct LidServiceInspection: Codable, Sendable, Equatable {
    public let serviceFound: Bool
    public let registryID: UInt64?
    public let openResult: Int32?
    public let closeResult: Int32?
    public let snapshot: LidRegistrySnapshot
    public var serviceAccessSucceeded: Bool { serviceFound && openResult == 0 && closeResult == 0 }
}

public struct LidMutationResult: Codable, Sendable, Equatable {
    public let serviceFound: Bool
    public let openResult: Int32?
    public let callResult: Int32?
    public let closeResult: Int32?
    public init(serviceFound: Bool, openResult: Int32?, callResult: Int32?, closeResult: Int32?) {
        self.serviceFound = serviceFound; self.openResult = openResult
        self.callResult = callResult; self.closeResult = closeResult
    }
    /// Only a call result. It does not prove protection or cleanup.
    public var succeeded: Bool { serviceFound && openResult == 0 && callResult == 0 && closeResult == 0 }
}

/// Experimental, low-level backend. No initializer, inspection or test sends selector 12.
/// Only the separately gated probe may call `setClamshellSleepDisabled`.
public enum LidQualificationIO {
    /// Continuous monotonic time includes time spent asleep. Do not persist across a reboot.
    public static func monotonicSeconds() -> Double {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return .nan }
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Opens and closes a service connection without invoking any external selector.
    public static func inspect() -> LidServiceInspection {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            return LidServiceInspection(serviceFound: false, registryID: nil, openResult: nil, closeResult: nil,
                                        snapshot: .init(lidClosed: nil, clamshellCausesSleep: nil, sleepDisabled: nil))
        }
        defer { IOObjectRelease(service) }
        var registryID: UInt64 = 0
        let registryResult = IORegistryEntryGetRegistryEntryID(service, &registryID)
        let snapshot = readSnapshot(service)
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        let closed: Int32? = opened == KERN_SUCCESS ? IOServiceClose(connection) : nil
        return LidServiceInspection(serviceFound: true, registryID: registryResult == KERN_SUCCESS ? registryID : nil,
                                    openResult: opened, closeResult: closed, snapshot: snapshot)
    }

    /// MUTATES SHARED RUNTIME POLICY. This is not a process-scoped assertion.
    /// Caller must gate, monitor and serialize commands, including cleanup. No retry is performed.
    public static func setClamshellSleepDisabled(_ disabled: Bool) -> LidMutationResult {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .init(serviceFound: false, openResult: nil, callResult: nil, closeResult: nil) }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else {
            return .init(serviceFound: true, openResult: opened, callResult: nil, closeResult: nil)
        }
        var input: UInt64 = disabled ? 1 : 0
        var outputCount: UInt32 = 0
        let called = IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, &outputCount)
        let closed = IOServiceClose(connection)
        return .init(serviceFound: true, openResult: opened, callResult: called, closeResult: closed)
    }

    private static func readSnapshot(_ service: io_registry_entry_t) -> LidRegistrySnapshot {
        func boolean(_ key: String) -> Bool? {
            guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let number = value as? NSNumber, number == 0 || number == 1 else { return nil }
            return number.boolValue
        }
        return .init(lidClosed: boolean("AppleClamshellState"), clamshellCausesSleep: boolean("AppleClamshellCausesSleep"),
                     sleepDisabled: boolean("SleepDisabled"))
    }
}

public struct LidProbeConditions: Sendable {
    public var registry: LidRegistrySnapshot
    public var power: PowerSnapshot
    public var batteryStage: BatteryStage
    public var clientAlive: Bool
    public var monitorAlive: Bool
    public var coOwnerScanComplete: Bool
    public var knownCoOwners: [String]
    public init(registry: LidRegistrySnapshot, power: PowerSnapshot, batteryStage: BatteryStage = .normal,
                clientAlive: Bool, monitorAlive: Bool, coOwnerScanComplete: Bool, knownCoOwners: [String]) {
        self.registry = registry; self.power = power; self.batteryStage = batteryStage
        self.clientAlive = clientAlive; self.monitorAlive = monitorAlive
        self.coOwnerScanComplete = coOwnerScanComplete; self.knownCoOwners = knownCoOwners
    }
}

public enum LidProbePhase: String, Codable, Sendable {
    case ready, enabling, active, disabling, verifyingCleanup, cleanupRequired, completed, refused
}
public enum LidProbeReason: String, Codable, Sendable {
    case authorizationMissing, invalidDuration, invalidClock, unsafeInitialPolicy, powerUnavailable
    case batteryPrepare, thermal, clientExited, monitorUnavailable, coOwnerUnknown, coOwnerConflict
    case leaseExpired, sessionExpired, userStopped, policyChanged, enableFailed, disableFailed, cleanupUnconfirmed
}
public enum LidProbeDirective: Sendable, Equatable {
    case none, disableClamshellSleep, enableClamshellSleep, inspectPolicy
}

/// Pure controller. The caller executes directives with a fake or real backend.
/// One instance authorizes at most one enable. A new instance requires a new explicit gate.
/// This is software bookkeeping, never evidence of exclusive ownership of the kernel bit.
public struct LidQualificationSession: Sendable {
    public private(set) var phase: LidProbePhase = .ready
    public private(set) var leaseDeadline: Double?
    public private(set) var sessionDeadline: Double?
    public private(set) var stopReason: LidProbeReason?
    public private(set) var failures: [LidProbeReason] = []
    public private(set) var cleanupCallAccepted = false
    private var lastTime: Double?
    private var leaseSeconds: Double = 30

    public init() {}
    public var cleanupOutstanding: Bool {
        [.enabling, .active, .disabling, .verifyingCleanup, .cleanupRequired].contains(phase)
    }

    public mutating func start(now: Double, conditions: LidProbeConditions, explicitlyAuthorized: Bool,
                               leaseSeconds: Double = 30, sessionCapSeconds: Double = 60) -> LidProbeDirective {
        guard phase == .ready else { return .none }
        guard explicitlyAuthorized else { return refuse(.authorizationMissing) }
        guard leaseSeconds.isFinite, sessionCapSeconds.isFinite, (30...60).contains(leaseSeconds),
              (leaseSeconds...60).contains(sessionCapSeconds) else { return refuse(.invalidDuration) }
        guard validTime(now), (now + sessionCapSeconds).isFinite else { return refuse(.invalidClock) }
        if let reason = unsafe(conditions) { return refuse(reason) }
        guard conditions.registry.normalOpenLidPolicy else { return refuse(.unsafeInitialPolicy) }
        self.leaseSeconds = leaseSeconds
        leaseDeadline = now + leaseSeconds; sessionDeadline = now + sessionCapSeconds
        phase = .enabling
        return .disableClamshellSleep
    }

    /// Deliver the synchronous backend result before issuing another mutation.
    public mutating func didEnable(_ result: LidMutationResult, now: Double) -> LidProbeDirective {
        guard phase == .enabling else { return .none }
        guard validTime(now) else { return beginCleanup(.invalidClock, failure: true) }
        guard result.succeeded else { return beginCleanup(.enableFailed, failure: true) }
        if let reason = expired(now) { return beginCleanup(reason) }
        phase = .active
        return .inspectPolicy
    }

    /// Heartbeats extend only the software lease, never write the clamshell bit again.
    public mutating func heartbeat(now: Double, conditions: LidProbeConditions) -> LidProbeDirective {
        let directive = poll(now: now, conditions: conditions)
        guard phase == .active, directive == .none, let cap = sessionDeadline else { return directive }
        leaseDeadline = min(now + leaseSeconds, cap)
        return .none
    }

    public mutating func poll(now: Double, conditions: LidProbeConditions) -> LidProbeDirective {
        guard phase == .active || phase == .enabling else { return .none }
        guard validTime(now) else { return beginCleanup(.invalidClock, failure: true) }
        // A newly observed owner makes a blind clear unsafe. Report cleanup debt to the monitor.
        if !conditions.coOwnerScanComplete || !conditions.knownCoOwners.isEmpty {
            let reason: LidProbeReason = conditions.coOwnerScanComplete ? .coOwnerConflict : .coOwnerUnknown
            phase = .cleanupRequired; stopReason = reason; fail(reason)
            return .inspectPolicy
        }
        if let reason = unsafe(conditions) { return beginCleanup(reason) }
        if let reason = expired(now) { return beginCleanup(reason) }
        if phase == .active {
            let registry = conditions.registry
            // The setter does not publish AppleClamshellCausesSleep. An open-lid
            // true value can be the pre-enable snapshot, not a policy change.
            // Lid-close notification does publish it; even then a false value
            // is only an observation, not proof the workload kept progressing.
            if !registry.policySnapshotKnown ||
                (registry.lidClosed == true && registry.clamshellCausesSleep != false) {
                return beginCleanup(.policyChanged, failure: true)
            }
        }
        return .none
    }

    public mutating func stop() -> LidProbeDirective {
        guard phase == .active || phase == .enabling else { return .none }
        return beginCleanup(.userStopped)
    }

    public mutating func didDisable(_ result: LidMutationResult) -> LidProbeDirective {
        guard phase == .disabling else { return .none }
        guard result.succeeded else { phase = .cleanupRequired; fail(.disableFailed); return .inspectPolicy }
        cleanupCallAccepted = true
        phase = .verifyingCleanup
        return .inspectPolicy
    }

    /// A snapshot cannot turn a failed/unknown clear into success. Completion
    /// means a clear call was accepted and the later snapshot is readable; it
    /// does not certify the hidden mask or physical lid-sleep restoration.
    public mutating func observeCleanup(_ snapshot: LidRegistrySnapshot) -> LidProbeDirective {
        guard phase == .verifyingCleanup || phase == .cleanupRequired else { return .none }
        if cleanupCallAccepted && snapshot.policySnapshotKnown {
            phase = .completed
        } else { phase = .cleanupRequired; fail(.cleanupUnconfirmed) }
        return .none
    }

    private mutating func refuse(_ reason: LidProbeReason) -> LidProbeDirective {
        phase = .refused; stopReason = reason; fail(reason); return .none
    }
    private mutating func beginCleanup(_ reason: LidProbeReason, failure: Bool = false) -> LidProbeDirective {
        phase = .disabling; stopReason = reason
        if failure { fail(reason) }
        return .enableClamshellSleep
    }
    private mutating func fail(_ reason: LidProbeReason) { if !failures.contains(reason) { failures.append(reason) } }
    private mutating func validTime(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { return false }
        lastTime = now; return true
    }
    private func expired(_ now: Double) -> LidProbeReason? {
        if let end = sessionDeadline, now >= end { return .sessionExpired }
        if let end = leaseDeadline, now >= end { return .leaseExpired }
        return nil
    }
    private func unsafe(_ c: LidProbeConditions) -> LidProbeReason? {
        if !c.clientAlive { return .clientExited }
        if !c.monitorAlive { return .monitorUnavailable }
        if !c.coOwnerScanComplete { return .coOwnerUnknown }
        if !c.knownCoOwners.isEmpty { return .coOwnerConflict }
        if c.batteryStage >= .prepare || c.power.warningLevel > 1 { return .batteryPrepare }
        if c.power.thermalLevel != 0 { return .thermal }
        guard let percent = c.power.percent, percent.isFinite, (30...100).contains(percent),
              c.power.onAC, !c.power.discharging else { return .powerUnavailable }
        return nil
    }
}
