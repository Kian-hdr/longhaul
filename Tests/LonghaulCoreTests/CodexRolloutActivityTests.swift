import Foundation
import Darwin
import Testing
@testable import LonghaulBridge

private let rolloutThread = "00000000-0000-4000-8000-000000000001"
private let rolloutTurn = "00000000-0000-4000-8000-000000000002"
private let rolloutNext = "00000000-0000-4000-8000-000000000003"
private let rolloutWriter = CodexRolloutWriter(pid: 1234, birth: 100_000_000)
private let rolloutNow = Date(timeIntervalSince1970: 1000)
private func rolloutHeader(version: String = "0.153.4", origin: String = "Codex Desktop", source: String = "vscode") -> String {
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(rolloutThread)\",\"cli_version\":\"\(version)\",\"originator\":\"\(origin)\",\"source\":\"\(source)\"}}\n"
}
private func rolloutEvent(_ type: String, id: String = rolloutTurn, at seconds: Double = 101) -> String {
    let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    return "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(id)\"}}\n"
}
private final class RolloutFixture {
    let root: URL
    let url: URL
    init(_ text: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("longhaul-rollout-tests-" + UUID().uuidString)
        url = root.appendingPathComponent("rollout.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { try? FileManager.default.removeItem(at: root) } // Disposable fixture only.
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
}

@Test func codexRolloutLifecycleAndTerminalSealing() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started"))
    var scanner = CodexRolloutActivityScanner()
    let started = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(started.state == .running)
    #expect(started.threadID == rolloutThread && started.turnID == rolloutTurn)
    #expect(started.startedAt == Date(timeIntervalSince1970: 101))
    try f.append(rolloutEvent("task_complete", at: 102))
    let completed = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(completed.state == .completed && completed.updatedAt == Date(timeIntervalSince1970: 102))
    try f.append(rolloutEvent("task_started", at: 103) + rolloutEvent("turn_aborted", at: 104))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .completed)
    try f.append(rolloutEvent("task_started", id: rolloutNext, at: 105))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    try f.append(rolloutEvent("task_started", at: 106))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).turnID == rolloutNext)
    try f.append(rolloutEvent("turn_aborted", id: rolloutNext, at: 107))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .cancelled)
    #expect(scanner.hasObservedTerminal(turnID: rolloutTurn))
    #expect(scanner.hasObservedTerminal(turnID: rolloutNext))
    scanner.reset()
    #expect(scanner.hasObservedTerminal(turnID: rolloutTurn) == false)
}

@Test func codexRolloutMismatchedTerminalDoesNotEndLatestTurn() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + rolloutEvent("task_complete", id: rolloutNext, at: 102))
    var scanner = CodexRolloutActivityScanner()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    // A terminal seen before its start cannot later resurrect that same turn.
    try f.append(rolloutEvent("task_started", id: rolloutNext, at: 103))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).turnID == rolloutTurn)
}

@Test func codexRolloutPartialTerminalWithholdsRunningUntilCompletedLine() throws {
    let terminal = rolloutEvent("task_complete", at: 102)
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + terminal.dropLast(2))
    var scanner = CodexRolloutActivityScanner()
    let pending = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(pending.state == .catchingUp && pending.reason == .partialRecord)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .catchingUp)
    try f.append(String(terminal.suffix(2)))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .completed)
}

@Test func codexRolloutOversizedAndMalformedTailNeverEmitPartialActive() throws {
    for tail in [String(repeating: "x", count: 257), "not-json\n", "[]\n", "\n"] {
        let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + tail)
        var scanner = CodexRolloutActivityScanner(maximumLineBytes: 256, readBudgetBytes: 2048)
        #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
        #expect(scanner.hasLatchedFailure)
        #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    }
}

@Test func codexRolloutMessageContentCannotCreateLifecycleEvents() throws {
    let messages = """
    {"type":"response_item","payload":{"role":"user","type":"task_started","turn_id":"\(rolloutTurn)","content":"task_started task_complete turn_aborted"}}
    {"type":"event_msg","payload":{"type":"agent_message","turn_id":{"malicious":"shape"},"message":"task_started task_complete turn_aborted"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"{\\\"type\\\":\\\"task_started\\\"}"}}

    """
    let f = try RolloutFixture(rolloutHeader() + messages)
    var scanner = CodexRolloutActivityScanner()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    try f.append(rolloutEvent("task_started"))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    try f.append(messages)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
}

@Test func codexRolloutOldStartCannotBeRevivedByNewWriter() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started", at: 99))
    var scanner = CodexRolloutActivityScanner()
    let old = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(old.state == .unknown && old.reason == .predatesWriter)
    try f.append(rolloutEvent("task_started", id: rolloutNext, at: 101))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    let restarted = CodexRolloutWriter(pid: rolloutWriter.pid, birth: 102_000_000)
    #expect(scanner.poll(url: f.url, writer: restarted, now: rolloutNow).reason == .predatesWriter)
}

@Test func codexRolloutUnsupportedVersionsOriginsAndMissingMetadataAreUnknown() throws {
    for text in [rolloutHeader(version: "0.153.5"), rolloutHeader(version: "0.154.0"),
                 rolloutHeader(origin: "codex_cli_rs"), rolloutHeader(source: "exec"), ""] {
        let f = try RolloutFixture(text + rolloutEvent("task_started"))
        var scanner = CodexRolloutActivityScanner()
        #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    }
}

@Test func codexRolloutSymlinkUnsafePermissionsAndFIFOAreRefused() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started"))
    let link = f.root.appendingPathComponent("alias.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.url)
    var scanner = CodexRolloutActivityScanner()
    #expect(scanner.poll(url: link, writer: rolloutWriter, now: rolloutNow).reason == .unsafeFile)
    scanner.reset()
    try FileManager.default.setAttributes([.posixPermissions: 0o620], ofItemAtPath: f.url.path)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).reason == .unsafeFile)
    scanner.reset()
    let fifo = f.root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(scanner.poll(url: fifo, writer: rolloutWriter, now: rolloutNow).reason == .unsafeFile)
}

@Test func codexRolloutTruncationAndReplacementLatchUnknown() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started"))
    var scanner = CodexRolloutActivityScanner()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    let handle = try FileHandle(forWritingTo: f.url)
    try handle.truncate(atOffset: 0); try handle.close()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).reason == .fileChanged)
    try f.append(rolloutHeader() + rolloutEvent("task_started"))
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    scanner.reset()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .running)
    try Data((rolloutHeader() + rolloutEvent("task_started")).utf8).write(to: f.url, options: .atomic)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).reason == .fileChanged)
}

@Test func codexRolloutBoundedCatchupWithTerminalBeyondReadBudget() throws {
    let filler = "{\"type\":\"response_item\",\"payload\":{\"content\":\"\(String(repeating: "x", count: 120))\"}}\n"
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + String(repeating: filler, count: 12) + rolloutEvent("task_complete", at: 102))
    var scanner = CodexRolloutActivityScanner(maximumLineBytes: 256, readBudgetBytes: 512)
    var result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(result.state == .catchingUp)
    var count = 1
    while result.state == .catchingUp && count < 20 {
        #expect(result.bytesRead <= 512)
        result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow); count += 1
    }
    #expect(count > 1 && count < 20 && result.state == .completed)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).bytesRead == 0)
}

@Test func codexRolloutExpectedFileIdentityAndMaximumSizeAreEnforced() throws {
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started"))
    var info = stat(); #expect(lstat(f.url.path, &info) == 0)
    let device = UInt64(UInt32(bitPattern: info.st_dev)), inode = info.st_ino
    var scanner = CodexRolloutActivityScanner()
    let active = scanner.poll(url: f.url, writer: rolloutWriter, expectedDevice: device, expectedInode: inode, now: rolloutNow)
    #expect(active.state == .running && active.inspectedDevice == device && active.inspectedInode == inode)
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, expectedDevice: device, expectedInode: inode + 1, now: rolloutNow).state == .unknown)
    var small = CodexRolloutActivityScanner(maximumLineBytes: 64, readBudgetBytes: 128, maximumFileBytes: 128)
    #expect(small.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).reason == .fileTooLarge)
}

@Test func codexRolloutFutureMalformedAndRegressingLifecycleTimesAreUnknown() throws {
    let bad = [rolloutEvent("task_started", at: 1001), rolloutEvent("task_started", id: "invalid"),
               rolloutEvent("task_started") + rolloutEvent("task_complete", at: 100),
               rolloutEvent("task_started").replacingOccurrences(of: "1970-01-01T00:01:41Z", with: "not-a-date")]
    for events in bad {
        let f = try RolloutFixture(rolloutHeader() + events)
        var scanner = CodexRolloutActivityScanner()
        #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    }
}

@Test func codexRolloutNewRecordInsideMeasuredPollWindowIsAccepted() throws {
    let event = rolloutEvent("task_started").replacingOccurrences(of: "1970-01-01T00:01:41Z", with: "1970-01-01T00:01:41.100Z")
    let f = try RolloutFixture(rolloutHeader() + event)
    var scanner = CodexRolloutActivityScanner(), clockRead = 0
    let result = scanner.poll(url: f.url, writer: rolloutWriter, now: Date(timeIntervalSince1970: 101.05), observationClock: {
        defer { clockRead += 1 }
        return clockRead == 0 ? 500 : 500.1
    })
    #expect(result.state == .running)
    #expect(result.startedAt == Date(timeIntervalSince1970: 101.1))
}

@Test func codexRolloutMeasuredPollWindowDoesNotAllowFutureOrRegressingClock() throws {
    let event = rolloutEvent("task_started").replacingOccurrences(of: "1970-01-01T00:01:41Z", with: "1970-01-01T00:01:41.200Z")
    let f = try RolloutFixture(rolloutHeader() + event)
    for elapsed in [0.1, -0.1, Double.nan] {
        var scanner = CodexRolloutActivityScanner(), clockRead = 0
        let result = scanner.poll(url: f.url, writer: rolloutWriter, now: Date(timeIntervalSince1970: 101.05), observationClock: {
            defer { clockRead += 1 }
            return clockRead == 0 ? 500 : 500 + elapsed
        })
        #expect(result.state == .unknown && result.reason == .invalidTimestamp)
    }
}

@Test func codexRolloutLargeIgnoredRecordsCrossPollsWithoutRetainingPayload() throws {
    let payload = String(repeating: "private-fixture-text-", count: 300_000)
    let response = "{\"type\":\"response_item\",\"payload\":{\"content\":\"" + payload + "\"}}\n"
    let compacted = "{\"replacement_history\":[{\"content\":\"" + payload + "\"}],\"type\":\"compacted\"}\n"
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + response + compacted +
                              rolloutEvent("task_complete", at: 102) + rolloutEvent("task_started", id: rolloutNext, at: 103))
    var scanner = CodexRolloutActivityScanner(), polls = 0
    var result: CodexRolloutActivity
    repeat {
        result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow); polls += 1
        #expect(result.bytesRead <= 4_194_304)
        #expect(scanner.retainedMetadataBytes < 4096)
        #expect(result.state != .unknown)
    } while result.state == .catchingUp && polls < 10
    #expect(polls >= 3 && polls < 10)
    #expect(result.state == .running && result.turnID == rolloutNext)
    #expect(scanner.hasObservedTerminal(turnID: rolloutTurn))
}

@Test func codexRolloutLargeMalformedPayloadAndHiddenLifecycleCannotPass() throws {
    let large = String(repeating: "x", count: 1_048_577)
    let tails = [
        "{\"type\":\"response_item\",\"payload\":\"" + large + "\\q\"}\n",
        "{\"type\":\"compacted\",\"payload\":[\"" + large + "\",]}\n",
        "{\"type\":\"response_item\",\"payload\":\"" + large + "\",\"ty\\u0070e\":\"event_msg\"}\n",
        "{\"payload\":{\"content\":\"" + large + "\",\"type\":\"agent_message\",\"ty\\u0070e\":\"task_complete\"},\"type\":\"event_msg\"}\n"
    ]
    for tail in tails {
        let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + tail)
        var scanner = CodexRolloutActivityScanner()
        let result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
        #expect(result.state == .unknown && result.reason == .malformedRecord)
        #expect(scanner.hasLatchedFailure)
    }
}

@Test func codexRolloutStreamingPayloadBeforeTypePreservesTrueLifecycle() throws {
    let large = String(repeating: "x", count: 1_048_577)
    let terminal = "{\"payload\":{\"irrelevant\":\"" + large + "\",\"turn_id\":\"\(rolloutTurn)\",\"ty\\u0070e\":\"task_complete\"},\"timestamp\":\"1970-01-01T00:01:42Z\",\"ty\\u0070e\":\"event_msg\"}\n"
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + terminal)
    var scanner = CodexRolloutActivityScanner()
    let result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(result.state == .completed)
    #expect(scanner.hasObservedTerminal(turnID: rolloutTurn))
}

@Test func codexRolloutStreamingPartialLargeRecordResumesWithoutReread() throws {
    let prefix = "{\"type\":\"compacted\",\"payload\":\"" + String(repeating: "x", count: 1_048_577)
    let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + prefix)
    var scanner = CodexRolloutActivityScanner()
    let partial = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(partial.state == .catchingUp && partial.reason == .partialRecord)
    #expect(scanner.retainedMetadataBytes < 4096)
    let unchanged = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(unchanged.state == .catchingUp && unchanged.bytesRead == 0)
    try f.append("\"}\n" + rolloutEvent("task_complete", at: 102))
    let complete = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
    #expect(complete.state == .completed && complete.bytesRead < 1024)
}

@Test func codexRolloutStreamingSyntaxUTF8AndEscapesAcrossByteBoundaries() throws {
    let valid = #"{"payload":{"text":"é🙂\uD83D\uDE42\"\\\/\b\f\n\r\t","values":[null,true,false,-0,0,1.25,-1e+2,1E-2,{},[]]},"ty\u0070e":"response_item"}"# + "\n"
    var stream = CodexRolloutJSONStream(maximumMetadataBytes: 128)
    var records = 0
    for byte in valid.utf8 {
        if let record = try stream.feed(byte) { records += 1; #expect(record.string(.type) == "response_item") }
        #expect(stream.retainedMetadataBytes < 256)
    }
    #expect(records == 1 && !stream.hasPartialRecord)
    let invalid: [[UInt8]] = [
        Array(#"{"type":"response_item","x":"\uD800"}"#.utf8),
        Array(#"{"type":"response_item","x":"\uDC00"}"#.utf8),
        Array(#"{"type":"response_item","x":"\uD800\u0041"}"#.utf8),
        Array(#"{"type":"response_item","x":01}"#.utf8),
        Array(#"{"type":"response_item","x":1.}"#.utf8),
        Array(#"{"type":"response_item","x":1e+}"#.utf8),
        Array(#"{"type":"response_item","x":truefalse}"#.utf8),
        Array(#"{"type":"response_item",}"#.utf8),
        Array(#"{"type":"response_item","x":""#.utf8) + [0xc0, 0xaf, 34, 125],
        Array(#"{"type":"response_item","x":""#.utf8) + [0xed, 0xa0, 0x80, 34, 125],
        Array(#"{"type":"response_item","x":""#.utf8) + [0xf4, 0x90, 0x80, 0x80, 34, 125],
        Array(#"{"type":"response_item","x":""#.utf8) + [0xe2, 34, 125]
    ]
    for bytes in invalid {
        var parser = CodexRolloutJSONStream(maximumMetadataBytes: 128)
        var rejected = false
        do { for byte in bytes + [10] { _ = try parser.feed(byte) } } catch { rejected = true }
        #expect(rejected)
    }
}

@Test func codexRolloutStreamingDepthAndMetadataRemainBounded() throws {
    let f = try RolloutFixture(rolloutHeader() + "{\"type\":\"" + String(repeating: "x", count: 1_048_577) + "\"}\n")
    var scanner = CodexRolloutActivityScanner()
    #expect(scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow).state == .unknown)
    #expect(scanner.retainedMetadataBytes < 4096)
    var stream = CodexRolloutJSONStream(maximumMetadataBytes: 128), rejected = false
    do {
        for byte in ("{\"type\":\"response_item\",\"x\":" + String(repeating: "[", count: 129)).utf8 { _ = try stream.feed(byte) }
    } catch { rejected = true }
    #expect(rejected)
}

@Test func codexRolloutStreamingNeverRetainsUnrelatedStringPayloadOrKey() throws {
    for prefix in ["{\"type\":\"compacted\",\"payload\":\"", "{\"type\":\"compacted\",\"unrelated-private-key-"] {
        var stream = CodexRolloutJSONStream(maximumMetadataBytes: 4096)
        for byte in (prefix + String(repeating: "private-value-", count: 1000)).utf8 { _ = try stream.feed(byte) }
        #expect(stream.retainedMetadataBytes == "compacted".utf8.count)
    }
}

@Test func codexRolloutStreamingProtectedDuplicateKeysAndPayloadShapesFail() throws {
    let records = [
        #"{"type":"event_msg","timestamp":"1970-01-01T00:01:42Z","time\u0073tamp":"1970-01-01T00:01:43Z","payload":{"type":"task_complete","turn_id":"TURN"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"TURN"},"pay\u006coad":{"type":"agent_message"}}"#,
        #"{"type":"event_msg","payload":"object","timestamp":"1970-01-01T00:01:42Z"}"#,
        #"{"type":"event_msg","payload":[{"type":"task_complete","turn_id":"TURN"}],"timestamp":"1970-01-01T00:01:42Z"}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"TURN","turn_\u0069d":"TURN"},"timestamp":"1970-01-01T00:01:42Z"}"#
    ]
    for record in records {
        let f = try RolloutFixture(rolloutHeader() + rolloutEvent("task_started") + record.replacingOccurrences(of: "TURN", with: rolloutTurn) + "\n")
        var scanner = CodexRolloutActivityScanner()
        let result = scanner.poll(url: f.url, writer: rolloutWriter, now: rolloutNow)
        #expect(result.state == .unknown && result.reason == .malformedRecord)
    }
}
