import Foundation
import Darwin
import Testing
import LonghaulBridge

private let ledgerSuccess = LidMutationResult(serviceFound: true, openResult: 0, callResult: 0, closeResult: 0)
private let ledgerFailure = LidMutationResult(serviceFound: true, openResult: 0, callResult: -1, closeResult: 0)
private final class LedgerFixture {
    let root: URL
    let boot = UUID().uuidString
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("longhaul-ledger-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) } // Disposable fixture only.
    func identity() -> LidSessionIdentity { .init(bootID: boot, sessionID: UUID().uuidString, appPID: 1234, appBirth: 42) }
    func ledger() throws -> LidSessionLedger { try .init(root: root) }
}

@Test func lidSessionLedgerIntentSurvivesReopenAndBlocksAdmission() throws {
    let f = try LedgerFixture(), identity = f.identity()
    #expect(try f.ledger().admission(currentBootID: f.boot) == .available)
    try f.ledger().beginEnable(identity: identity, at: 100)
    guard case .blocked(let record) = try f.ledger().admission(currentBootID: f.boot) else { Issue.record("Intent did not persist"); return }
    #expect(record.identity == identity)
    #expect(record.stage == .enableIntent)
    #expect(throws: (any Error).self) { try f.ledger().beginEnable(identity: f.identity(), at: 101) }
}

@Test func lidSessionLedgerSingleClearAndAcceptedOutcome() throws {
    let f = try LedgerFixture(), identity = f.identity(), ledger = try f.ledger()
    try ledger.beginEnable(identity: identity, at: 100)
    try ledger.recordEnableResult(identity: identity, result: ledgerSuccess, at: 101)
    try ledger.beginCleanupAttempt(identity: identity, at: 102)
    #expect(throws: (any Error).self) { try ledger.beginCleanupAttempt(identity: identity, at: 103) }
    #expect(throws: (any Error).self) { try ledger.beginEnable(identity: f.identity(), at: 103) }
    try ledger.recordCleanupResult(identity: identity, result: ledgerSuccess, at: 104)
    #expect(try f.ledger().admission(currentBootID: f.boot) == .available)
    #expect(throws: (any Error).self) { try ledger.recordCleanupResult(identity: identity, result: ledgerSuccess, at: 105) }
    #expect(throws: (any Error).self) { try ledger.beginEnable(identity: identity, at: 105) }
    try ledger.beginEnable(identity: f.identity(), at: 106)
}

@Test func lidSessionLedgerUnknownOrFailedClearCannotRetry() throws {
    for failure in [false, true] {
        let f = try LedgerFixture(), identity = f.identity(), ledger = try f.ledger()
        try ledger.beginEnable(identity: identity, at: 100)
        // Missing enable receipt still means enable may have happened.
        try ledger.beginCleanupAttempt(identity: identity, at: 101)
        if failure { try ledger.recordCleanupResult(identity: identity, result: ledgerFailure, at: 102) }
        #expect(throws: (any Error).self) { try f.ledger().beginCleanupAttempt(identity: identity, at: 103) }
        #expect(throws: (any Error).self) { try f.ledger().beginEnable(identity: f.identity(), at: 103) }
    }
}

@Test func lidSessionLedgerCoOwnerConflictAndWrongIdentityBlock() throws {
    let f = try LedgerFixture(), identity = f.identity(), ledger = try f.ledger()
    try ledger.beginEnable(identity: identity, at: 100)
    #expect(throws: (any Error).self) { try ledger.beginCleanupAttempt(identity: f.identity(), at: 101) }
    #expect(throws: (any Error).self) { try ledger.beginCleanupAttempt(identity: identity, at: 99) }
    try ledger.markUnresolved(identity: identity, reason: "Competing controller observed", at: 101)
    #expect(throws: (any Error).self) { try ledger.beginCleanupAttempt(identity: identity, at: 102) }
    #expect(throws: (any Error).self) { try ledger.beginEnable(identity: f.identity(), at: 103) }
}

@Test func lidSessionLedgerFailedEnableStillNeedsClear() throws {
    let f = try LedgerFixture(), identity = f.identity(), ledger = try f.ledger()
    try ledger.beginEnable(identity: identity, at: 100)
    try ledger.recordEnableResult(identity: identity, result: ledgerFailure, at: 101)
    #expect(throws: (any Error).self) { try ledger.beginEnable(identity: f.identity(), at: 102) }
    try ledger.beginCleanupAttempt(identity: identity, at: 102)
    try ledger.recordCleanupResult(identity: identity, result: ledgerSuccess, at: 103)
    #expect(try ledger.admission(currentBootID: f.boot) == .available)
}

@Test func lidSessionLedgerDifferentBootRequiresExplicitReconciliation() throws {
    let f = try LedgerFixture(), identity = f.identity(), ledger = try f.ledger()
    let nextBoot = try LidSessionLedger.currentBootID()
    #expect(LidSessionIdentity.currentBootID() == nextBoot)
    try ledger.beginEnable(identity: identity, at: 100)
    guard case .previousBoot(let old) = try ledger.admission(currentBootID: nextBoot) else { Issue.record("Expected previous boot"); return }
    #expect(old.identity == identity)
    #expect(throws: (any Error).self) { _ = try ledger.reconcilePreviousBoot(currentBootID: f.boot) }
    #expect(throws: (any Error).self) {
        try ledger.beginEnable(identity: .init(bootID: nextBoot, sessionID: UUID().uuidString, appPID: 1234, appBirth: 42), at: 1)
    }
    #expect(try ledger.reconcilePreviousBoot(currentBootID: nextBoot))
    #expect(try ledger.admission(currentBootID: nextBoot) == .available)
    let archived = try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix("lid-retired-") }
    #expect(archived.count == 1)
    let currentIdentity = LidSessionIdentity(bootID: nextBoot, sessionID: UUID().uuidString, appPID: 1234, appBirth: 42)
    try ledger.beginEnable(identity: currentIdentity, at: 1)
    #expect(try !ledger.reconcilePreviousBoot(currentBootID: nextBoot))
    #expect(throws: (any Error).self) { _ = try ledger.reconcilePreviousBoot(currentBootID: UUID().uuidString) }
}

@Test func lidSessionLedgerExclusiveLockRefusesConcurrentMutation() throws {
    let f = try LedgerFixture(), ledger = try f.ledger()
    _ = try ledger.admission(currentBootID: f.boot) // Establish lock inode.
    let fd = Darwin.open(f.root.appendingPathComponent(".lid-session-ledger.lock").path, O_RDWR)
    #expect(fd >= 0); defer { Darwin.close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: (any Error).self) { try ledger.beginEnable(identity: f.identity(), at: 100) }
    #expect(flock(fd, LOCK_UN) == 0)
    try ledger.beginEnable(identity: f.identity(), at: 100)
}

@Test func lidSessionLedgerConcurrentAdmissionHasOneWinner() async throws {
    let f = try LedgerFixture(), root = f.root, boot = f.boot
    let winners = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<12 {
            group.addTask {
                do {
                    let ledger = try LidSessionLedger(root: root)
                    try ledger.beginEnable(identity: .init(bootID: boot, sessionID: UUID().uuidString, appPID: 1234, appBirth: 42), at: 100)
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await accepted in group { if accepted { count += 1 } }
        return count
    }
    #expect(winners == 1)
}

@Test func lidSessionLedgerRejectsUnsafeAndCorruptRecords() throws {
    for contents in ["{}", "not json", String(repeating: "x", count: 17_000)] {
        let f = try LedgerFixture(), path = f.root.appendingPathComponent("lid-current-session.json")
        try Data(contents.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(throws: (any Error).self) { _ = try f.ledger().admission(currentBootID: f.boot) }
        #expect(throws: (any Error).self) { _ = try f.ledger().reconcilePreviousBoot(currentBootID: UUID().uuidString) }
        #expect(throws: (any Error).self) { try f.ledger().beginEnable(identity: f.identity(), at: 100) }
    }
    let f = try LedgerFixture(), destination = f.root.appendingPathComponent("target")
    try Data("original".utf8).write(to: destination)
    let path = f.root.appendingPathComponent("lid-current-session.json")
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: destination)
    #expect(throws: (any Error).self) { try f.ledger().beginEnable(identity: f.identity(), at: 100) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
}

@Test func lidSessionLedgerPrivateRootAndRecordRequired() throws {
    let f = try LedgerFixture(), ledger = try f.ledger()
    try ledger.beginEnable(identity: f.identity(), at: 100)
    let path = f.root.appendingPathComponent("lid-current-session.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    #expect(throws: (any Error).self) { _ = try ledger.admission(currentBootID: f.boot) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
    #expect(throws: (any Error).self) { _ = try f.ledger() }
}
