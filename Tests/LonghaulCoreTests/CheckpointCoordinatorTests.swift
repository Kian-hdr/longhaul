import Foundation
import Testing
import LonghaulCore
import LonghaulBridge

private func checkpointFixture(session: String = "one", requestID: String = "request", deadline: Double = 100)
    -> (JobEvent, CheckpointRequest, CheckpointReceipt) {
    let event = JobEvent(id: "job", source: "Fixture", title: "Checkpoint fixture", session: session, checkpointCapable: true)
    let request = CheckpointRequest(id: requestID, jobID: event.id, source: event.source, session: event.session,
                                    reason: "Recovery fixture", deadline: Date(timeIntervalSince1970: deadline), createdAt: Date(timeIntervalSince1970: 0))
    let receipt = CheckpointReceipt(requestID: requestID, jobID: event.id, source: event.source, session: event.session,
                                    savedPaths: ["/fixture/save.blend"], summary: "Saved scene", success: true)
    return (event, request, receipt)
}

@Test func checkpointCoordinatorRecoversPersistedRequestAndReceiptAfterRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (job, request, baseReceipt) = checkpointFixture()
    let firstMailbox = try Mailbox(root: root)
    let artifact = root.appendingPathComponent("saved.blend")
    try Data("disposable artifact".utf8).write(to: artifact)
    var receipt = baseReceipt; receipt.savedPaths = [artifact.path]
    try firstMailbox.write(request, folder: "requests", key: request.id)
    try firstMailbox.write(receipt, folder: "receipts", key: request.id)
    // No previous in-memory pending state is available to the reopened coordinator.
    let reopened = try Mailbox(root: root)
    let requests = try reopened.files(in: "requests").map { try reopened.read(CheckpointRequest.self, at: $0) }
    let receipts = try reopened.files(in: "receipts").map { ObservedCheckpointReceipt(try reopened.read(CheckpointReceipt.self, at: $0)) }
    let result = try CheckpointCoordinator.reconcile(requests: requests, receipts: receipts,
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90))
    #expect(result.acceptedReceipts.count == 1)
    #expect(result.acceptedReceipts.first?.timing == .observedWithinDeadline)
    #expect(result.outcomes.first?.status == .acknowledged)
    #expect(result.pendingRequests.isEmpty)
    #expect(result.expiredRequests.isEmpty)
    let archived = try Mailbox.decoder().decode(AcceptedCheckpointReceipt.self,
                                                from: Mailbox.encoder().encode(result.acceptedReceipts[0]))
    #expect(archived.request.deadline == request.deadline)
    #expect(archived.observedAt == Date(timeIntervalSince1970: 90))
}

@Test func checkpointCoordinatorAcceptsRealSaveAfterExpiredDeadline() throws {
    let (job, request, receipt) = checkpointFixture()
    let expired = try CheckpointCoordinator.reconcile(requests: [request], receipts: [], currentJobs: [job],
                                                     now: Date(timeIntervalSince1970: 100))
    #expect(expired.outcomes.first?.status == .expired)
    #expect(expired.expiredRequests.map(\.id) == [request.id])
    let recovered = try CheckpointCoordinator.reconcile(requests: [request], receipts: [.init(receipt)], currentJobs: [job],
                                                       now: Date(timeIntervalSince1970: 105), validateSavedFiles: { _ in true })
    #expect(recovered.acceptedReceipts.first?.timing == .observedAfterDeadline)
    #expect(recovered.outcomes.first?.status == .acknowledged)
    #expect(recovered.expiredRequests.isEmpty)
    #expect(CheckpointReceiptTiming.observedAfterDeadline.explanation.contains("Save time"))
}

@Test func checkpointCoordinatorRetainsSaveWithPreCreationObservationAsUnknown() throws {
    let (job, base, receipt) = checkpointFixture()
    var request = base; request.createdAt = Date(timeIntervalSince1970: 50)
    let result = try CheckpointCoordinator.reconcile(requests: [request],
        receipts: [.init(receipt, observedAt: Date(timeIntervalSince1970: 49))], currentJobs: [job],
        now: Date(timeIntervalSince1970: 90), validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.count == 1)
    #expect(result.acceptedReceipts.first?.timing == .observationTimeUnknown)
    #expect(result.outcomes.first?.receiptTiming == .observationTimeUnknown)
    let accepted = try #require(result.acceptedReceipts.first)
    let afterRestart = try CheckpointCoordinator.reconcile(requests: [request],
        receipts: [.init(accepted.receipt, observedAt: accepted.observedAt, timingUncertain: accepted.timing == .observationTimeUnknown)],
        currentJobs: [job], now: Date(timeIntervalSince1970: 95), validateSavedFiles: { _ in true })
    #expect(afterRestart.acceptedReceipts.first?.timing == .observationTimeUnknown)
}

@Test func checkpointCoordinatorRejectsInvertedRequestInterval() throws {
    let (job, base, receipt) = checkpointFixture()
    var request = base; request.createdAt = request.deadline.addingTimeInterval(1)
    let result = try CheckpointCoordinator.reconcile(requests: [request], receipts: [.init(receipt)], currentJobs: [job],
        now: Date(timeIntervalSince1970: 110), validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.isEmpty)
    #expect(result.rejectedRequestIDs == [request.id])
}

@Test func checkpointCoordinatorDoesNotCreditReplacementJob() throws {
    let (_, oldRequest, oldReceipt) = checkpointFixture()
    let (replacement, newRequest, _) = checkpointFixture(session: "two", requestID: "new", deadline: 200)
    let result = try CheckpointCoordinator.reconcile(requests: [oldRequest, newRequest], receipts: [.init(oldReceipt)],
                                                    currentJobs: [replacement], now: Date(timeIntervalSince1970: 110),
                                                    validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.first?.identity.session == "one")
    #expect(result.outcomes.count == 1)
    #expect(result.outcomes.first?.requestID == "new")
    #expect(result.outcomes.first?.status == .pending)
    #expect(result.outcomes.first?.applies(to: replacement) == true)
    var third = replacement; third.session = "three"
    #expect(result.outcomes.first?.applies(to: third) == false)
}

@Test func checkpointCoordinatorExpiredOldRequestCannotFailReplacement() throws {
    let (_, oldRequest, _) = checkpointFixture()
    let (replacement, _, _) = checkpointFixture(session: "two")
    let result = try CheckpointCoordinator.reconcile(requests: [oldRequest], receipts: [], currentJobs: [replacement],
                                                    now: Date(timeIntervalSince1970: 110))
    #expect(result.outcomes.isEmpty)
    #expect(result.expiredRequests.map(\.id) == [oldRequest.id])
}

@Test func checkpointCoordinatorPreservesPreviouslyObservedTiming() throws {
    let (job, request, receipt) = checkpointFixture()
    let observed = ObservedCheckpointReceipt(receipt, observedAt: Date(timeIntervalSince1970: 99))
    let persisted = try Mailbox.decoder().decode(ObservedCheckpointReceipt.self, from: Mailbox.encoder().encode(observed))
    let result = try CheckpointCoordinator.reconcile(requests: [request], receipts: [persisted], currentJobs: [job],
                                                    now: Date(timeIntervalSince1970: 110), validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.first?.timing == .observedWithinDeadline)
    #expect(result.acceptedReceipts.first?.observedAt == observed.observedAt)
}

@Test func checkpointCoordinatorDoesNotTrustFutureObservationTime() throws {
    let (job, request, receipt) = checkpointFixture()
    let result = try CheckpointCoordinator.reconcile(requests: [request],
                                                    receipts: [.init(receipt, observedAt: Date(timeIntervalSince1970: 200))],
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 110),
                                                    validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.first?.timing == .observationTimeUnknown)
    #expect(result.acceptedReceipts.first?.observedAt == nil)
}

@Test func checkpointCoordinatorRejectsMismatchedAndOrphanReceipts() throws {
    let (job, request, base) = checkpointFixture()
    var wrongSession = base; wrongSession.session = "wrong"
    var wrongSource = base; wrongSource.source = "Other"
    var orphan = base; orphan.requestID = "orphan"
    var validations = 0
    let result = try CheckpointCoordinator.reconcile(requests: [request],
                                                    receipts: [wrongSession, wrongSource, orphan].map { .init($0) },
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                    validateSavedFiles: { _ in validations += 1; return true })
    #expect(validations == 0)
    #expect(result.acceptedReceipts.isEmpty)
    #expect(result.outcomes.first?.status == .pending)
    #expect(result.rejectedReceiptRequestIDs == [request.id, "orphan"])
}

@Test func checkpointCoordinatorRejectsConflictingRequestIdentity() throws {
    let (job, request, receipt) = checkpointFixture()
    var conflicting = request; conflicting.session = "replacement"
    let result = try CheckpointCoordinator.reconcile(requests: [request, conflicting], receipts: [.init(receipt)],
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                    validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.isEmpty)
    #expect(result.outcomes.isEmpty)
    #expect(result.rejectedRequestIDs == [request.id])
}

@Test func checkpointCoordinatorPreservesCreationTimeAndLegacyNil() throws {
    let (job, base, _) = checkpointFixture()
    var request = base; request.createdAt = Date(timeIntervalSince1970: 60)
    let result = try CheckpointCoordinator.reconcile(requests: [request], receipts: [], currentJobs: [job],
                                                    now: Date(timeIntervalSince1970: 90))
    #expect(result.outcomes.first?.createdAt == request.createdAt)
    let encoded = try Mailbox.encoder().encode(request)
    var legacyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyJSON.removeValue(forKey: "createdAt")
    let legacy = try Mailbox.decoder().decode(CheckpointRequest.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    #expect(legacy.createdAt == nil)
    let legacyResult = try CheckpointCoordinator.reconcile(requests: [legacy], receipts: [], currentJobs: [job],
                                                          now: Date(timeIntervalSince1970: 90))
    #expect(legacyResult.outcomes.first?.createdAt == nil)
}

@Test func checkpointCoordinatorRejectsConflictingCreationTime() throws {
    let (job, base, receipt) = checkpointFixture()
    var request = base; request.createdAt = Date(timeIntervalSince1970: 50)
    var conflicting = request; conflicting.createdAt = Date(timeIntervalSince1970: 60)
    let result = try CheckpointCoordinator.reconcile(requests: [request, conflicting], receipts: [.init(receipt)],
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                    validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.isEmpty)
    #expect(result.outcomes.isEmpty)
    #expect(result.rejectedRequestIDs == [request.id])
}

@Test func checkpointCoordinatorDeduplicatesAndPreservesSuccessfulReceipt() throws {
    let (job, request, receipt) = checkpointFixture()
    var failure = receipt; failure.success = false; failure.savedPaths = []
    let result = try CheckpointCoordinator.reconcile(requests: [request, request],
                                                    receipts: [.init(failure), .init(receipt), .init(receipt)],
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                    validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.count == 1)
    #expect(result.outcomes.count == 1)
    #expect(result.outcomes.first?.status == .acknowledged)
}

@Test func checkpointCoordinatorMissingFilesAndExplicitFailureAreNotSuccess() throws {
    let (job, request, receipt) = checkpointFixture()
    let result = try CheckpointCoordinator.reconcile(requests: [request], receipts: [.init(receipt)],
                                                    currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                    validateSavedFiles: { _ in false })
    #expect(result.acceptedReceipts.isEmpty)
    #expect(result.outcomes.first?.status == .failed)
    var failed = receipt; failed.success = false; failed.savedPaths = []
    let failure = try CheckpointCoordinator.reconcile(requests: [request], receipts: [.init(failed)],
                                                     currentJobs: [job], now: Date(timeIntervalSince1970: 90),
                                                     validateSavedFiles: { _ in true })
    #expect(failure.acceptedReceipts.isEmpty)
    #expect(failure.outcomes.first?.status == .failed)
}

@Test func checkpointCoordinatorFileCheckRejectsEmptySymlinkDirectoryAndRelativePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("artifact")
    let empty = root.appendingPathComponent("empty")
    let link = root.appendingPathComponent("link")
    try Data("saved".utf8).write(to: file); try Data().write(to: empty)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(CheckpointCoordinator.regularSavedFilesExist([file.path]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist([empty.path]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist([link.path]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist([root.path]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist(["relative"]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist([file.path + "\0ignored"]))
    #expect(!CheckpointCoordinator.regularSavedFilesExist([]))
}

@Test func checkpointCoordinatorIdentityCannotCollideThroughColonConcatenation() throws {
    let (base, original, receipt) = checkpointFixture()
    var request = original; request.source = "a:b"; request.jobID = "c"
    var saved = receipt; saved.source = request.source; saved.jobID = request.jobID
    var other = base; other.source = "a"; other.id = "b:c"
    let result = try CheckpointCoordinator.reconcile(requests: [request], receipts: [.init(saved)], currentJobs: [other],
                                                    now: Date(timeIntervalSince1970: 90), validateSavedFiles: { _ in true })
    #expect(result.acceptedReceipts.count == 1)
    #expect(result.outcomes.isEmpty)
}

@Test func checkpointCoordinatorBoundsInputsAndRejectsInvalidClock() {
    let (_, request, _) = checkpointFixture()
    #expect(throws: CheckpointCoordinator.ReconciliationError.self) {
        try CheckpointCoordinator.reconcile(requests: Array(repeating: request, count: 4097), receipts: [], currentJobs: [], now: Date())
    }
    #expect(throws: CheckpointCoordinator.ReconciliationError.self) {
        try CheckpointCoordinator.reconcile(requests: [], receipts: [], currentJobs: [], now: Date(timeIntervalSince1970: .nan))
    }
}
