import Foundation
import Darwin
import LonghaulCore
import LonghaulBridge

/// Compile with RuntimeIO.swift, Journal.swift, the app's bridging header, SQLite,
/// and isolated LonghaulCore/LonghaulBridge modules.
/// All writes are disposable fixtures; no application or power APIs are called.
@main struct RuntimeIORecoveryHarness {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("longhaul-recovery-fixtures-" + UUID().uuidString)
        let box = try Mailbox(root: root)
        defer { try? fm.removeItem(at: root) }
        let io = try RuntimeIO(root: root)
        // The runner invokes this mode in a separate process with a five-second
        // timeout, so a regression to blocking open cannot hang the test suite.
        if CommandLine.arguments.contains("--fifo-probe") {
            for folder in ["events", "receipts", "requests"] {
                let path = root.appendingPathComponent(folder).appendingPathComponent("invalid-pipe.json").path
                guard mkfifo(path, 0o600) == 0 else { throw POSIXError(.EIO) }
            }
            let valid = JobEvent(id: "valid-with-fifo", source: "Review", title: "Regular event", session: "fixture")
            try box.emit(valid)
            let batch = await io.poll()
            guard batch.events == [valid], batch.requests.isEmpty, batch.receipts.isEmpty else {
                fatalError("FIFO entries must be rejected while valid events remain readable")
            }
            print("RuntimeIO FIFO: nonblocking poll regression passed")
            return
        }
        let now = Date()
        let event = JobEvent(id: "job", source: "Review", title: "Recovery fixture", session: "first", checkpointCapable: true)
        let request = CheckpointRequest(id: "accepted", jobID: event.id, source: event.source, session: event.session,
                                        reason: "Fixture", deadline: now.addingTimeInterval(60), createdAt: now.addingTimeInterval(-10))
        let saved = root.appendingPathComponent("saved-output.blend")
        let savedBytes = Data("fixture saved content".utf8)
        try savedBytes.write(to: saved)
        let receipt = CheckpointReceipt(requestID: request.id, jobID: event.id, source: event.source, session: event.session,
                                        savedPaths: [saved.path], summary: "Fixture recovery", success: true)
        try box.write(request, folder: "requests", key: request.id)
        try box.write(receipt, folder: "receipts", key: receipt.requestID)
        let accepted = try await io.reconcile(currentJobs: [event], now: now)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }; checks += 1
        }
        check(accepted.acceptedReceipts.count == 1, "Fixture receipt accepted")
        let envelopeURL = root.appendingPathComponent("recovery").appendingPathComponent(Mailbox.key(request.id) + ".json")
        let envelopeBytes = try Data(contentsOf: envelopeURL)
        var records = try await io.recovery()
        check(records.count == 1 && records[0].success, "Available accepted save is listed")
        try fm.removeItem(at: saved)
        records = try await io.recovery()
        check(records.count == 1 && !records[0].success, "Missing accepted save is unavailable")
        check(records[0].summary.contains("currently unavailable"), "Missing save explains unavailability")
        check(try Data(contentsOf: envelopeURL) == envelopeBytes, "Historical envelope remains byte-identical")
        let rejected = try await io.reconcile(currentJobs: [event], now: now.addingTimeInterval(1))
        check(rejected.acceptedReceipts.isEmpty, "Reconciliation no longer accepts missing save")
        check(try Data(contentsOf: envelopeURL) == envelopeBytes, "Reconciliation retains historical envelope")
        try savedBytes.write(to: saved)
        records = try await io.recovery()
        check(records.count == 1 && records[0].success, "Restored save automatically becomes available")
        check(!records[0].summary.contains("currently unavailable"), "Restored availability explanation is current")
        try Data().write(to: saved)
        check(try await io.recovery().first?.success == false, "Empty saved file is unavailable")
        try savedBytes.write(to: saved)

        let legacyPath = root.appendingPathComponent("legacy-save.blend")
        try savedBytes.write(to: legacyPath)
        var legacy = receipt; legacy.requestID = "legacy"; legacy.savedPaths = [legacyPath.path]
        try box.write(legacy, folder: "recovery", key: legacy.requestID)
        records = try await io.recovery()
        check(records.first(where: { $0.requestID == "legacy" })?.success == true, "Valid legacy receipt is checked")
        try fm.removeItem(at: legacyPath)
        records = try await io.recovery()
        check(records.first(where: { $0.requestID == "legacy" })?.success == false, "Missing legacy save cannot retain success")
        try savedBytes.write(to: legacyPath)
        records = try await io.recovery()
        check(records.first(where: { $0.requestID == "legacy" })?.success == true, "Restored legacy save becomes available")
        var malformed = legacy; malformed.requestID = "malformed"; malformed.source = ""
        try box.write(malformed, folder: "recovery", key: malformed.requestID)
        var failed = legacy; failed.requestID = "failed"; failed.success = false
        try box.write(failed, folder: "recovery", key: failed.requestID)
        var empty = legacy; empty.requestID = "empty-paths"; empty.savedPaths = []
        try box.write(empty, folder: "recovery", key: empty.requestID)
        records = try await io.recovery()
        check(records.first(where: { $0.requestID == "malformed" })?.success == false, "Malformed legacy identity is not acknowledged")
        check(records.first(where: { $0.requestID == "failed" })?.success == false, "Existing file does not promote failed receipt")
        check(records.first(where: { $0.requestID == "empty-paths" })?.success == false, "Empty path collection cannot confirm a save")
        try fm.removeItem(at: legacyPath)
        try fm.createSymbolicLink(atPath: legacyPath.path, withDestinationPath: saved.path)
        records = try await io.recovery()
        check(records.first(where: { $0.requestID == "legacy" })?.success == false, "Symlink replacement is unavailable")

        let uncertainRequest = CheckpointRequest(id: "uncertain-timing", jobID: event.id, source: event.source, session: event.session,
                                                 reason: "Clock fixture", deadline: now.addingTimeInterval(60), createdAt: now)
        var uncertainReceipt = receipt; uncertainReceipt.requestID = uncertainRequest.id
        let uncertain = try CheckpointCoordinator.reconcile(requests: [uncertainRequest],
            receipts: [.init(uncertainReceipt, observedAt: now.addingTimeInterval(-1))], currentJobs: [event], now: now)
        check(uncertain.acceptedReceipts.first?.timing == .observationTimeUnknown, "Pre-request observation retains uncertain timing")
        try box.write(uncertain.acceptedReceipts[0], folder: "recovery", key: uncertainRequest.id)
        let reopened = try RuntimeIO(root: root)
        let reconstructed = try await reopened.reconcile(currentJobs: [event], now: now.addingTimeInterval(1))
        check(reconstructed.acceptedReceipts.first(where: { $0.receipt.requestID == uncertainRequest.id })?.timing == .observationTimeUnknown,
              "Persisted uncertain timing remains uncertain after RuntimeIO restart")
        print("RuntimeIO recovery: \(checks) checks passed; isolated fixtures only")
    }
}
