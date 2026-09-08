import Foundation

public struct PolicyEngine: Sendable {
    public private(set) var jobs: [String: TrackedJob] = [:]
    public private(set) var batteryStage: BatteryStage = .normal
    private var graceDeadline: TimeInterval?
    private var previouslyProtected = false
    private var canSleepOnCompletion = false
    private var healthySince: TimeInterval?
    private var lastClock: TimeInterval?
    private var lastClosedLidPolicy: LidBatteryPolicy?
    private var systemEmergencyLatched = false
    private var checkpointDue: [String: TimeInterval] = [:]
    private var lastCheckpointStage: [String: BatteryStage] = [:]
    private var retiredSessions: [String: Set<String>] = [:]
    public init() {}

    @discardableResult public mutating func receive(_ event: JobEvent, now: TimeInterval) -> Bool {
        guard event.isValid, now.isFinite else { return false }
        let key = event.source + ":" + event.id
        guard retiredSessions[key]?.contains(event.session) != true else { return false }
        if var current = jobs[key], current.event.session == event.session {
            guard event.sequence > current.event.sequence else { return false }
            // Only real hook activity can continue a provisional Stop. The
            // mailbox preserves its marker through later reports/heartbeats so
            // polling need not observe the very first continuation report.
            let hookContinuation = current.event.phase == .completed &&
                current.event.continuableHookStop == current.event.sequence &&
                (event.continuableHookStop ?? -1) >= current.event.sequence
            guard !current.event.phase.isTerminal || event.phase.isTerminal || hookContinuation else { return false }
            if current.event.phase != event.phase { current.phaseChanged = now }
            current.event = event; current.lastSeen = now; current.stale = false
            jobs[key] = current
        } else {
            if let current = jobs[key] { retiredSessions[key, default: []].insert(current.event.session) }
            jobs[key] = TrackedJob(event: event, now: now)
            checkpointDue[key] = nil; lastCheckpointStage[key] = nil
        }
        return true
    }

    /// Remove an observation only when a coordinator retires its integration
    /// or transfers the same live turn to another verified source.
    public mutating func removeObservation(_ key: String) {
        jobs.removeValue(forKey: key); checkpointDue.removeValue(forKey: key); lastCheckpointStage.removeValue(forKey: key)
    }
    /// A verified source observed terminal completion. Late integration
    /// heartbeats or provisional Stops must not resurrect this incarnation.
    public mutating func retireObservation(_ key: String, session: String) {
        retiredSessions[key, default: []].insert(session)
        if jobs[key]?.event.session == session { removeObservation(key) }
    }
    public mutating func expire(_ key: String) { jobs[key]?.stale = true }
    public mutating func checkpointRequested(_ key: String) { jobs[key]?.checkpoint = .requested }
    public mutating func checkpointResult(_ key: String, success: Bool, now: TimeInterval, late: Bool = false) {
        jobs[key]?.checkpoint = success ? (late ? .acknowledgedLate : .acknowledged) : .failed
        if success { jobs[key]?.checkpointAt = now }
    }
    public mutating func cancelCompletionSleep() { canSleepOnCompletion = false }
    public mutating func reconcileAfterWake() {
        for key in jobs.keys where jobs[key]?.event.phase.isTerminal == false { jobs[key]?.stale = true }
        graceDeadline = nil; previouslyProtected = false; canSleepOnCompletion = false
        healthySince = nil
    }
    public mutating func prune(now: TimeInterval) {
        let old = jobs.filter { ($0.value.event.phase.isTerminal || $0.value.stale) && now - $0.value.lastSeen > 3600 }.map(\.key)
        for key in old {
            if let job = jobs[key], job.event.phase.isTerminal, job.event.continuableHookStop == nil { retiredSessions[key, default: []].insert(job.event.session) }
            jobs.removeValue(forKey: key); checkpointDue.removeValue(forKey: key); lastCheckpointStage.removeValue(forKey: key)
        }
    }

    public mutating func evaluate(now: TimeInterval, power: PowerSnapshot, settings input: PolicySettings,
                                 userIdle: TimeInterval = 0, externalHold: Bool = false,
                                 closedLidBatteryPolicy: LidBatteryPolicy? = nil) -> PolicyDecision {
        var settings = input; settings.normalize()
        if let lastClock, now < lastClock { reconcileAfterWake() }
        lastClock = now
        let previousStage = batteryStage
        let customized = closedLidBatteryPolicy?.isValid == true
        let desired = closedLidBatteryPolicy?.isValid == false ? BatteryStage.critical :
            Self.stage(for: power, useSystemEmergencyLimitsOnly: customized)
        if power.warningLevel >= 3 || power.thermalLevel >= 3 { systemEmergencyLatched = true }
        let policyChanged = lastClosedLidPolicy != closedLidBatteryPolicy
        lastClosedLidPolicy = closedLidBatteryPolicy
        if policyChanged && !systemEmergencyLatched {
            // An explicit cutoff choice replaces the app's old numeric limit,
            // including a previously latched percentage/time-based critical state.
            batteryStage = desired; healthySince = nil
        } else if desired >= batteryStage {
            batteryStage = desired; healthySince = nil
        } else if power.onAC && !power.discharging && power.thermalLevel < 2 && desired == .normal {
            if healthySince == nil { healthySince = now }
            if now - (healthySince ?? now) >= 30 { batteryStage = .normal; healthySince = nil }
        } else if desired == .normal, (power.percent ?? 0) > 30, (power.credibleSeconds ?? .infinity) > 2100 {
            if healthySince == nil { healthySince = now }
            if now - (healthySince ?? now) >= 60 { batteryStage = .normal; healthySince = nil }
        } else { healthySince = nil }
        if batteryStage == .normal { systemEmergencyLatched = false }
        if previousStage > .normal && batteryStage == .normal { lastCheckpointStage.removeAll() }

        var eligible: Set<String> = []
        var unknown = false
        for key in jobs.keys {
            guard var job = jobs[key], !job.event.phase.isTerminal else { continue }
            if now - job.lastSeen >= settings.leaseDuration { job.stale = true; jobs[key] = job }
            if job.stale { unknown = true; continue }
            if job.event.phase == .needsInput && now - job.phaseChanged >= settings.inputGrace { unknown = true; continue }
            eligible.insert(key)
        }
        if unknown { canSleepOnCompletion = false }
        let active = settings.enabled && !eligible.isEmpty
        if active {
            graceDeadline = nil; previouslyProtected = true
            if !unknown { canSleepOnCompletion = true }
        } else if previouslyProtected {
            graceDeadline = now + settings.completionGrace; previouslyProtected = false
        }
        if !settings.enabled { graceDeadline = nil; canSleepOnCompletion = false }
        let grace = graceDeadline.map { max(0, $0 - now) }
        let inGrace = (grace ?? 0) > 0 && settings.enabled && !unknown
        var checkpointIDs: Set<String> = []
        if active && batteryStage < .critical {
            for key in eligible {
                guard let job = jobs[key], job.event.checkpointCapable else { continue }
                let deadline = checkpointDue[key] ?? (job.firstSeen + settings.checkpointInterval)
                let escalate = batteryStage >= .prepare && (lastCheckpointStage[key] ?? .normal) < batteryStage
                if now >= deadline || escalate {
                    checkpointIDs.insert(key)
                    checkpointDue[key] = now + settings.checkpointInterval
                    lastCheckpointStage[key] = batteryStage
                    jobs[key]?.checkpoint = .requested
                }
            }
        }
        let critical = batteryStage == .critical
        let reserveReleased = closedLidBatteryPolicy.map { policy in
            policy.cutoffEnabled && !(power.percent.map {
                $0.isFinite && $0 >= Double(policy.cutoffPercent) && $0 <= 100
            } ?? false)
        } ?? false
        let hold = settings.enabled && !critical && !reserveReleased && (active || inGrace)
        let mode: ProtectionMode = !settings.enabled ? .paused : (critical || reserveReleased) ? .limited :
            (active && batteryStage == .prepare) ? .saving : active ? .protecting : inGrace ? .finishing : .ready
        let sleep = !active && !inGrace && graceDeadline != nil && canSleepOnCompletion &&
            settings.enabled && settings.completionSleep && !unknown && !externalHold && userIdle >= settings.userIdleBeforeSleep
        let reason: String
        if !settings.enabled { reason = "Automatic protection is paused" }
        else if critical { reason = power.thermalLevel >= 3 ? "Mac thermal state is critical" : "Battery reserve reached; protection withdrawn" }
        else if reserveReleased { reason = "Battery auto-release threshold reached; protection withdrawn" }
        else if active { reason = "Protecting \(eligible.count) \(eligible.count == 1 ? "job" : "jobs")" }
        else if inGrace { reason = "Work finished; allowing time for new jobs" }
        else if unknown { reason = "An integration stopped reporting; its job state is unknown" }
        else { reason = "Ready for supported work" }
        return PolicyDecision(mode: mode, shouldHold: hold, stage: batteryStage, protectedIDs: eligible,
                              checkpointIDs: checkpointIDs, sleepEligible: sleep,
                              emergencySleep: critical && settings.enabled && (active || inGrace),
                              reason: reason, graceRemaining: inGrace ? grace : nil)
    }

    public static func stage(for power: PowerSnapshot, useSystemEmergencyLimitsOnly: Bool = false) -> BatteryStage {
        if power.thermalLevel >= 3 { return .critical }
        var result: BatteryStage = power.thermalLevel >= 2 ? .prepare : .normal
        guard power.discharging || !power.onAC || power.warningLevel >= 2 else { return result }
        let percent = power.percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let seconds = power.credibleSeconds
        if power.warningLevel >= 3 || (!useSystemEmergencyLimitsOnly &&
            ((percent ?? .infinity) <= 10 || (seconds ?? .infinity) <= 600)) { return .critical }
        if (percent ?? .infinity) <= 20 || (seconds ?? .infinity) <= 1200 || power.warningLevel >= 2 { result = max(result, .prepare) }
        if (percent ?? .infinity) <= 25 || (seconds ?? .infinity) <= 1800 { result = max(result, .warning) }
        return result
    }
}
