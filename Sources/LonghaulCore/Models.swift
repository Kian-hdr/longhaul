import Foundation

public enum JobPhase: String, Codable, Sendable, CaseIterable {
    case running, waiting, needsInput, completed, cancelled, failed
    public var isTerminal: Bool { [.completed, .cancelled, .failed].contains(self) }
    public var label: String {
        switch self {
        case .running: "Working"
        case .waiting: "Waiting for a tool"
        case .needsInput: "Needs your input"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

public struct JobEvent: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var id: String
    public var source: String
    public var title: String
    public var phase: JobPhase
    public var sequence: Int
    public var session: String
    public var pid: Int32?
    public var processBirth: UInt64?
    public var progress: Double?
    public var checkpointCapable: Bool
    public var outputPath: String?
    public var evidenceAt: Date? = nil
    // Set only by the mailbox hook path. On a provisional Stop this equals
    // sequence; subsequent real activity carries it until another terminal event.
    public var continuableHookStop: Int? = nil

    public init(id: String, source: String, title: String, phase: JobPhase = .running,
                sequence: Int = 0, session: String = UUID().uuidString, pid: Int32? = nil,
                processBirth: UInt64? = nil, progress: Double? = nil,
                checkpointCapable: Bool = false, outputPath: String? = nil) {
        self.id = id; self.source = source; self.title = title; self.phase = phase
        self.sequence = sequence; self.session = session; self.pid = pid; self.processBirth = processBirth
        self.progress = progress; self.checkpointCapable = checkpointCapable; self.outputPath = outputPath
    }
    public var isValid: Bool {
        (continuableHookStop == nil || (continuableHookStop! >= 0 && continuableHookStop! <= sequence &&
            (!phase.isTerminal || (phase == .completed && continuableHookStop == sequence)))) &&
        version == 1 && !id.isEmpty && id.utf8.count <= 180 && source.utf8.count <= 80 &&
        !source.isEmpty && title.utf8.count <= 240 && session.utf8.count <= 180 &&
        !session.isEmpty && sequence >= 0 && sequence <= 9_007_199_254_740_990 && (progress == nil || (progress!.isFinite && (0...1).contains(progress!))) &&
        (pid == nil || pid! > 0) && (outputPath?.utf8.count ?? 0) <= 4096
    }
}

public struct TrackedJob: Identifiable, Sendable, Equatable {
    public var id: String { event.source + ":" + event.id }
    public var event: JobEvent
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval
    public var phaseChanged: TimeInterval
    public var stale = false
    public var checkpoint: CheckpointState = .unsupported
    public var checkpointAt: TimeInterval?
    public init(event: JobEvent, now: TimeInterval) {
        self.event = event; firstSeen = now; lastSeen = now; phaseChanged = now
        checkpoint = event.checkpointCapable ? .available : .unsupported
    }
}

public enum CheckpointState: String, Codable, Sendable { case unsupported, available, requested, acknowledged, acknowledgedLate, failed
    public var label: String { switch self { case .acknowledgedLate: "Acknowledged after deadline"; default: rawValue.capitalized } }
}
public enum BatteryStage: Int, Codable, Sendable, Comparable {
    case normal, warning, prepare, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var label: String {
        switch self { case .normal: "Normal"; case .warning: "Low battery"; case .prepare: "Saving progress"; case .critical: "Protection withdrawn" }
    }
}
public struct PowerSnapshot: Codable, Sendable, Equatable {
    public var percent: Double?
    public var onAC: Bool
    public var discharging: Bool
    public var secondsRemaining: Double?
    public var warningLevel: Int
    public var thermalLevel: Int
    public init(percent: Double? = nil, onAC: Bool = true, discharging: Bool = false,
                secondsRemaining: Double? = nil, warningLevel: Int = 1, thermalLevel: Int = 0) {
        self.percent = percent; self.onAC = onAC; self.discharging = discharging
        self.secondsRemaining = secondsRemaining; self.warningLevel = warningLevel; self.thermalLevel = thermalLevel
    }
    public var credibleSeconds: Double? {
        guard let s = secondsRemaining, s.isFinite, s >= 0 else { return nil }; return s
    }
    /// Reserve and OS warnings govern sustained lid protection on either power
    /// source. Unplugging or a brief current reversal must not end a healthy hold.
    public var supportsClosedLidWork: Bool { supportsClosedLidWork(policy: .init()) }
    public func supportsClosedLidWork(policy: LidBatteryPolicy) -> Bool {
        guard policy.isValid, let percent, percent.isFinite, (0...100).contains(percent) else { return false }
        return (!policy.cutoffEnabled || percent >= Double(policy.cutoffPercent)) &&
            thermalLevel == 0 && warningLevel == 1
    }
}
public struct PolicySettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var completionSleep = false
    public var completionGrace: Double = 120
    public var userIdleBeforeSleep: Double = 300
    public var leaseDuration: Double = 120
    public var inputGrace: Double = 600
    public var checkpointInterval: Double = 300
    public var checkpointDeadline: Double = 60
    public init() {}
    public mutating func normalize() {
        completionGrace = finiteClamp(completionGrace, 10...600, 120)
        userIdleBeforeSleep = finiteClamp(userIdleBeforeSleep, 60...3600, 300)
        leaseDuration = finiteClamp(leaseDuration, 30...600, 120)
        inputGrace = finiteClamp(inputGrace, 30...3600, 600)
        checkpointInterval = finiteClamp(checkpointInterval, 60...3600, 300)
        checkpointDeadline = finiteClamp(checkpointDeadline, 5...60, 60)
    }
    private func finiteClamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

public enum ProtectionMode: String, Sendable { case ready, protecting, finishing, paused, saving, limited }
public struct PolicyDecision: Sendable, Equatable {
    public var mode: ProtectionMode
    public var shouldHold: Bool
    public var stage: BatteryStage
    public var protectedIDs: Set<String>
    public var checkpointIDs: Set<String>
    public var sleepEligible: Bool
    public var emergencySleep: Bool
    public var reason: String
    public var graceRemaining: Double?
}

public struct CheckpointRequest: Codable, Sendable {
    public var id: String
    public var jobID: String
    public var source: String
    public var session: String
    public var reason: String
    public var deadline: Date
    public var createdAt: Date?
    public init(id: String = UUID().uuidString, jobID: String, source: String, session: String, reason: String, deadline: Date, createdAt: Date? = Date()) {
        self.id = id; self.jobID = jobID; self.source = source; self.session = session; self.reason = reason; self.deadline = deadline; self.createdAt = createdAt
    }
}
public struct CheckpointReceipt: Codable, Sendable {
    public var requestID: String
    public var jobID: String
    public var source: String
    public var session: String
    public var savedPaths: [String]
    public var summary: String
    public var success: Bool
    public init(requestID: String, jobID: String, source: String, session: String, savedPaths: [String], summary: String, success: Bool) {
        self.requestID = requestID; self.jobID = jobID; self.source = source; self.session = session
        self.savedPaths = savedPaths; self.summary = summary; self.success = success
    }
}
