import Foundation
import LonghaulCore
import LonghaulBridge

struct MailboxBatch: Sendable {
    var events: [JobEvent] = []
    var receipts: [CheckpointReceipt] = []
    var requests: [CheckpointRequest] = []
    var errors: [String] = []
    var expiredIDs: [String] = []
    var removedIDs: [String] = []
    var retiredObservations: [(key: String, session: String)] = []
    var codexActivityStatus: String?
}

actor RuntimeIO {
    private let box: Mailbox
    private var versions: [String: Date] = [:]
    private var hooks: [String: (event: JobEvent, modified: Date)] = [:]
    private let codexActivity = CodexActivityMonitor()
    init(root: URL) throws { box = try Mailbox(root: root) }
    func poll(codexProfiles: [URL] = [], nativeHosts: [CodexNativeHost] = [], monitorCodex: Bool = false) -> MailboxBatch {
        var result = MailboxBatch()
        for folder in ["events", "receipts"] {
            do {
                for url in try box.files(in: folder) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let modified = attributes[.modificationDate] as? Date, versions[url.path] != modified else { continue }
                    versions[url.path] = modified
                    if folder == "events" {
                        guard abs(modified.timeIntervalSinceNow) < 120,
                              let e = try? box.read(JobEvent.self, at: url), e.isValid,
                              url.deletingPathExtension().lastPathComponent == Mailbox.key(e.source + ":" + e.id) else { continue }
                        result.events.append(e)
                        if e.source.hasPrefix("Codex (") { hooks[e.source + ":" + e.id] = (e, modified) }
                    } else if let r = try? box.read(CheckpointReceipt.self, at: url), r.savedPaths.count <= 32,
                              r.summary.utf8.count <= 2000, r.savedPaths.allSatisfy({ $0.utf8.count <= 4096 }) {
                        result.receipts.append(r)
                    }
                }
            } catch { result.errors.append("Could not read the local integration mailbox.") }
        }
        let native = codexActivity.poll(profiles: codexProfiles, hosts: nativeHosts, enabled: monitorCodex, hooks: hooks, now: Date())
        result.events += native.events; result.expiredIDs = native.expiredIDs; result.removedIDs = native.removedIDs
        result.retiredObservations = native.retiredObservations
        result.codexActivityStatus = native.status
        if hooks.count > 512 {
            hooks = Dictionary(uniqueKeysWithValues: hooks.sorted { $0.value.modified > $1.value.modified }.prefix(512).map { ($0.key, $0.value) })
        }
        result.requests = ((try? box.files(in: "requests")) ?? []).compactMap { url in
            guard let request = try? box.read(CheckpointRequest.self, at: url) else { return nil }
            let receiptURL = box.root.appendingPathComponent("receipts").appendingPathComponent(Mailbox.key(request.id) + ".json")
            if let receipt = try? box.read(CheckpointReceipt.self, at: receiptURL), receipt.requestID == request.id,
               receipt.source == request.source, receipt.jobID == request.jobID, receipt.session == request.session { return nil }
            return request
        }
        return result
    }
    func emit(_ event: JobEvent) throws { try box.emit(event) }
    func request(_ request: CheckpointRequest) throws { try box.write(request, folder: "requests", key: request.id) }
    func reconcile(currentJobs: [JobEvent], now: Date) throws -> CheckpointReconciliation {
        var requests = try box.files(in: "requests").compactMap { try? box.read(CheckpointRequest.self, at: $0) }
        let accepted = try box.files(in: "recovery").compactMap { try? box.read(AcceptedCheckpointReceipt.self, at: $0) }
        requests += accepted.map(\.request)
        let persisted = Dictionary(accepted.map { ($0.receipt.requestID, $0) }, uniquingKeysWith: { a, _ in a })
        var receipts = accepted.map { ObservedCheckpointReceipt($0.receipt, observedAt: $0.observedAt,
                                                                 timingUncertain: $0.timing == .observationTimeUnknown) }
        for url in try box.files(in: "receipts") {
            guard let receipt = try? box.read(CheckpointReceipt.self, at: url) else { continue }
            if let prior = persisted[receipt.requestID],
               (try? Mailbox.encoder().encode(prior.receipt)) == (try? Mailbox.encoder().encode(receipt)),
               CheckpointCoordinator.regularSavedFilesExist(prior.receipt.savedPaths) { continue }
            receipts.append(ObservedCheckpointReceipt(receipt, observedAt: now))
        }
        let result = try CheckpointCoordinator.reconcile(requests: requests, receipts: receipts, currentJobs: currentJobs, now: now)
        for accepted in result.acceptedReceipts {
            if let prior = persisted[accepted.receipt.requestID],
               (try? Mailbox.encoder().encode(prior)) == (try? Mailbox.encoder().encode(accepted)) { continue }
            try box.write(accepted, folder: "recovery", key: accepted.receipt.requestID)
        }
        return result
    }
    func recovery() throws -> [CheckpointReceipt] {
        try box.files(in: "recovery").compactMap { url in
            if let accepted = try? box.read(AcceptedCheckpointReceipt.self, at: url) {
                let timing: String = switch accepted.timing {
                case .observedWithinDeadline: "Acknowledged before the deadline."
                case .observedAfterDeadline: "Acknowledged after the deadline; save time is unverified."
                case .observationTimeUnknown: "Acknowledgement timing is unknown."
                }
                return Self.currentRecovery(accepted.receipt, timing: timing)
            }
            guard let legacy = try? box.read(CheckpointReceipt.self, at: url) else { return nil }
            return Self.currentRecovery(legacy, timing: "Legacy acknowledgement; timing and application restore are unverified.")
        }
    }
    /// Availability is a current observation, separate from the retained receipt.
    /// Never rewrite historical success just because an external drive is absent.
    private static func currentRecovery(_ original: CheckpointReceipt, timing: String) -> CheckpointReceipt {
        var receipt = original
        func bounded(_ value: String, _ limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && !value.utf8.contains(0)
        }
        let valid = bounded(receipt.requestID, 180) && bounded(receipt.jobID, 180) &&
            bounded(receipt.source, 80) && bounded(receipt.session, 180) &&
            receipt.summary.utf8.count <= 2000 && receipt.savedPaths.count <= 32 &&
            receipt.savedPaths.allSatisfy { $0.hasPrefix("/") && bounded($0, 4096) }
        let detail: String
        if !valid {
            receipt.success = false
            detail = "This recovery record is invalid; its save is not confirmed."
        } else if !original.success {
            detail = "This record does not confirm a successful recovery save."
        } else if !CheckpointCoordinator.regularSavedFilesExist(receipt.savedPaths) {
            receipt.success = false
            detail = "Saved files are currently unavailable or empty. This checkpoint is unavailable until its files return."
        } else { detail = timing }
        receipt.summary = String(original.summary.prefix(1200)) + " " + detail
        return receipt
    }
    func export(_ entries: [HistoryEntry], to url: URL) throws {
        // Events intentionally contain no raw conversations or command arguments.
        try Mailbox.encoder().encode(entries).write(to: url, options: .atomic)
    }
}
