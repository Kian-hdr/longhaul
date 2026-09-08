import Foundation
import Darwin
import LonghaulCore

/// Incarnation identity is a tuple, not a colon-concatenated lookup key.
public struct CheckpointJobIdentity: Codable, Hashable, Sendable {
    public let source: String
    public let jobID: String
    public let session: String
    public init(source: String, jobID: String, session: String) {
        self.source = source; self.jobID = jobID; self.session = session
    }
    public init(_ event: JobEvent) { self.init(source: event.source, jobID: event.id, session: event.session) }
    public func matches(_ event: JobEvent) -> Bool { event.isValid && self == Self(event) }
}

/// `observedAt` is when Longhaul first observed the acknowledgement, not its save time.
/// Persist this envelope to retain that evidence across restarts. Legacy receipts use nil.
public struct ObservedCheckpointReceipt: Codable, Sendable {
    public let receipt: CheckpointReceipt
    public let observedAt: Date?
    public let timingUncertain: Bool?
    public init(_ receipt: CheckpointReceipt, observedAt: Date? = nil, timingUncertain: Bool = false) {
        self.receipt = receipt; self.observedAt = observedAt; self.timingUncertain = timingUncertain
    }
}

public enum CheckpointReceiptTiming: String, Codable, Sendable {
    case observedWithinDeadline, observedAfterDeadline, observationTimeUnknown
    public var explanation: String {
        switch self {
        case .observedWithinDeadline: "Acknowledgement observed within the deadline. Application restore is not verified."
        case .observedAfterDeadline: "Acknowledgement observed after the deadline. Save time and application restore are not verified."
        case .observationTimeUnknown: "Acknowledgement observation time is uncertain. Save time and application restore are not verified."
        }
    }
}

public struct AcceptedCheckpointReceipt: Codable, Sendable {
    public let request: CheckpointRequest
    public let receipt: CheckpointReceipt
    public let observedAt: Date?
    public let timing: CheckpointReceiptTiming
    public var identity: CheckpointJobIdentity { .init(source: request.source, jobID: request.jobID, session: request.session) }
}

public enum CheckpointRequestStatus: String, Sendable {
    case pending, expired, failed, acknowledged
}

/// Per-request outcome. It is deliberately not an unscoped mutation of a job's UI state.
public struct CheckpointOutcome: Sendable {
    public let requestID: String
    public let identity: CheckpointJobIdentity
    public let deadline: Date
    public let createdAt: Date?
    public let status: CheckpointRequestStatus
    public let receiptTiming: CheckpointReceiptTiming?
    public func applies(to event: JobEvent) -> Bool { identity.matches(event) }
}

public struct CheckpointReconciliation: Sendable {
    /// Valid saves remain recoverable even when their job is gone or replaced.
    public var acceptedReceipts: [AcceptedCheckpointReceipt] = []
    /// Outcomes are emitted only for exact identities present in `currentJobs`.
    public var outcomes: [CheckpointOutcome] = []
    /// Unresolved requests only. A late accepted receipt resolves an expired request.
    public var pendingRequests: [CheckpointRequest] = []
    public var expiredRequests: [CheckpointRequest] = []
    public var rejectedRequestIDs: Set<String> = []
    public var rejectedReceiptRequestIDs: Set<String> = []
}

/// Stateless reconciliation can rebuild the same state from disk after a crash.
/// It performs no persistence or power actions. Run file validation off the main actor.
public enum CheckpointCoordinator {
    public enum ReconciliationError: Error { case invalidClock, inputTooLarge }

    public static func reconcile(requests: [CheckpointRequest], receipts: [ObservedCheckpointReceipt],
                                 currentJobs: [JobEvent], now: Date,
                                 validateSavedFiles: ([String]) -> Bool = regularSavedFilesExist) throws -> CheckpointReconciliation {
        guard now.timeIntervalSince1970.isFinite else { throw ReconciliationError.invalidClock }
        guard requests.count <= 4096, receipts.count <= 4096, currentJobs.count <= 4096 else {
            throw ReconciliationError.inputTooLarge
        }
        var result = CheckpointReconciliation()
        var unique: [String: CheckpointRequest] = [:]
        for request in requests {
            guard valid(request) else { result.rejectedRequestIDs.insert(request.id); continue }
            if let prior = unique[request.id], !sameRequest(prior, request) {
                result.rejectedRequestIDs.insert(request.id)
            } else { unique[request.id] = request }
        }
        // An ambiguous request ID must not authorize either conflicting payload.
        for id in result.rejectedRequestIDs { unique[id] = nil }
        let current = Set(currentJobs.filter(\.isValid).map(CheckpointJobIdentity.init))
        var matching: [String: [ObservedCheckpointReceipt]] = [:]
        for envelope in receipts {
            let receipt = envelope.receipt
            guard valid(receipt), let request = unique[receipt.requestID],
                  request.source == receipt.source, request.jobID == receipt.jobID,
                  request.session == receipt.session else {
                result.rejectedReceiptRequestIDs.insert(receipt.requestID); continue
            }
            matching[receipt.requestID, default: []].append(envelope)
        }
        for request in unique.values.sorted(by: { $0.id < $1.id }) {
            let identity = CheckpointJobIdentity(source: request.source, jobID: request.jobID, session: request.session)
            let candidates = matching[request.id] ?? []
            // Validate every candidate. An invalid/failed duplicate cannot erase a real save.
            let successful = candidates.filter { $0.receipt.success && validateSavedFiles($0.receipt.savedPaths) }
            let chosen = successful.sorted { receiptOrder($0, now: now) < receiptOrder($1, now: now) }.first
            let status: CheckpointRequestStatus
            var timing: CheckpointReceiptTiming?
            if let chosen {
                let observed: Date?
                if chosen.timingUncertain == true { observed = nil }
                else if let recorded = chosen.observedAt {
                    observed = recorded.timeIntervalSince1970.isFinite && recorded <= now &&
                        (request.createdAt.map { recorded >= $0 } ?? true) ? recorded : nil
                } else { observed = (request.createdAt.map { now >= $0 } ?? true) ? now : nil }
                let receiptTiming: CheckpointReceiptTiming = observed.map {
                    $0 <= request.deadline ? .observedWithinDeadline : .observedAfterDeadline
                } ?? .observationTimeUnknown
                timing = receiptTiming
                result.acceptedReceipts.append(AcceptedCheckpointReceipt(request: request, receipt: chosen.receipt,
                                                                         observedAt: observed, timing: receiptTiming))
                status = .acknowledged
            } else if !candidates.isEmpty {
                status = .failed
            } else if now >= request.deadline {
                status = .expired; result.expiredRequests.append(request)
            } else {
                status = .pending; result.pendingRequests.append(request)
            }
            if current.contains(identity) {
                result.outcomes.append(CheckpointOutcome(requestID: request.id, identity: identity,
                                                         deadline: request.deadline, createdAt: request.createdAt,
                                                         status: status, receiptTiming: timing))
            }
        }
        return result
    }

    /// Only proves accessible nonempty regular files now, not durability or application restore.
    public static func regularSavedFilesExist(_ paths: [String]) -> Bool {
        guard (1...32).contains(paths.count) else { return false }
        return paths.allSatisfy { path in
            guard validPath(path) else { return false }
            let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { Darwin.close(descriptor) }
            var info = stat()
            return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0
        }
    }

    private static func valid(_ request: CheckpointRequest) -> Bool {
        validIdentity(request.source, request.jobID, request.session) && bounded(request.id, 180) &&
        request.reason.utf8.count <= 2000 && request.deadline.timeIntervalSince1970.isFinite &&
        (request.createdAt.map { $0.timeIntervalSince1970.isFinite && $0 <= request.deadline } ?? true)
    }
    private static func valid(_ receipt: CheckpointReceipt) -> Bool {
        validIdentity(receipt.source, receipt.jobID, receipt.session) && bounded(receipt.requestID, 180) &&
        receipt.summary.utf8.count <= 2000 && receipt.savedPaths.count <= 32 &&
        (!receipt.success || !receipt.savedPaths.isEmpty) && receipt.savedPaths.allSatisfy(validPath)
    }
    private static func validIdentity(_ source: String, _ job: String, _ session: String) -> Bool {
        bounded(source, 80) && bounded(job, 180) && bounded(session, 180)
    }
    private static func bounded(_ value: String, _ limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.utf8.contains(0)
    }
    private static func validPath(_ path: String) -> Bool { path.hasPrefix("/") && bounded(path, 4096) }
    private static func sameRequest(_ a: CheckpointRequest, _ b: CheckpointRequest) -> Bool {
        a.id == b.id && a.source == b.source && a.jobID == b.jobID && a.session == b.session &&
        a.deadline == b.deadline && a.createdAt == b.createdAt && a.reason == b.reason
    }
    private static func receiptOrder(_ envelope: ObservedCheckpointReceipt, now: Date) -> (Double, String) {
        let recorded = envelope.observedAt
        let observed = recorded.flatMap { $0.timeIntervalSince1970.isFinite && $0 <= now ? $0 : nil } ?? now
        // Known early observations win duplicate receipts. Serialized bytes break ties deterministically.
        let bytes = (try? Mailbox.encoder().encode(envelope.receipt)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (observed.timeIntervalSince1970, bytes)
    }
}
