#!/usr/bin/env python3
"""Test the real native-activity coordinator against owned JSONL fixtures.

Discovery is injected; only the fixture process's own identity is used for the
writer. No real Codex log is opened, and no native power operations are invoked.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin
import LonghaulCore
import LonghaulBridge

enum Failure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.assertion(message) }
}

final class Fixture {
    let root: URL, profile: URL, file: URL, handle: FileHandle
    let thread = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
    let pid = getpid(), birth = ProcessIdentity.birth(getpid())
    var visible = true
    var now = Date()
    var snapshot: CodexOpenFilesSnapshot!
    var engine = PolicyEngine()
    lazy var monitor = CodexActivityMonitor { [unowned self] _, _ in self.snapshot }
    var source: String { "Codex activity (" + profile.lastPathComponent + ")" }
    var hookSource: String { "Codex (" + profile.lastPathComponent + ")" }
    var id: String { thread + ":" + turn }
    var key: String { source + ":" + id }
    var hookKey: String { hookSource + ":" + id }

    init(parent: URL, name: String) throws {
        root = parent.appendingPathComponent(name)
        profile = root.appendingPathComponent(".codex-fixture")
        let sessions = profile.appendingPathComponent("sessions/2026/09/08")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = sessions.appendingPathComponent("rollout-" + thread + ".jsonl")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        handle = try FileHandle(forWritingTo: file)
        try require(birth > 0, "Fixture process birth unavailable")
        while Date().timeIntervalSince1970 - Double(birth) / 1_000_000 < 0.020 { usleep(1000) }
        try append(header() + event("task_started"))
    }
    deinit { try? handle.close() }
    func header() -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\",\"originator\":\"Codex Desktop\",\"source\":\"vscode\",\"cli_version\":\"0.153.4\"}}\n"
    }
    func event(_ type: String, turnID: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use a past observation to avoid Foundation formatter millisecond
        // rounding becoming a synthetic future timestamp in this fast fixture.
        return "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: Date().addingTimeInterval(-0.01)))\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turnID ?? turn)\"}}\n"
    }
    func append(_ text: String) throws {
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.synchronize()
    }
    func replaceContents(_ text: String) throws {
        try handle.truncate(atOffset: 0); try append(text)
    }
    func hook(sequence: Int = 1, ownerPID: Int32? = nil, ownerBirth: UInt64? = nil) -> JobEvent {
        .init(id: id, source: hookSource, title: "Fixture hook", sequence: sequence, session: id,
              pid: ownerPID ?? pid, processBirth: ownerBirth ?? birth)
    }
    func poll(enabled: Bool = true, hook: JobEvent? = nil, hookAge: Double = 0) throws -> CodexActivityBatch {
        now = now.addingTimeInterval(3)
        var info = stat(); try require(fstat(handle.fileDescriptor, &info) == 0, "Fixture file stat failed")
        let fileMetadata: [String: Any] = [
            "pid": pid, "processBirth": birth, "appPID": pid, "appBirth": birth,
            "executablePath": CommandLine.arguments[0], "fd": handle.fileDescriptor, "path": file.path,
            "device": UInt32(bitPattern: info.st_dev), "inode": info.st_ino, "ownerUID": getuid(),
            "mode": info.st_mode, "size": info.st_size, "modifiedSeconds": info.st_mtimespec.tv_sec,
            "modifiedNanoseconds": info.st_mtimespec.tv_nsec, "openFlags": O_RDWR, "isWritable": true
        ]
        let data: [String: Any] = ["observedAt": LidQualificationIO.monotonicSeconds(), "complete": true,
                                 "issues": [], "processCount": 1, "matchedProcessCount": 1,
                                 "files": visible ? [fileMetadata] : []]
        snapshot = try JSONDecoder().decode(CodexOpenFilesSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
        var hooks: [String: (event: JobEvent, modified: Date)] = [:]
        if let hook { hooks[hook.source + ":" + hook.id] = (hook, now.addingTimeInterval(-hookAge)) }
        return monitor.poll(profiles: [profile], hosts: [], enabled: enabled, hooks: hooks, now: now)
    }
    func apply(_ batch: CodexActivityBatch, hook: JobEvent? = nil) {
        if let hook { _ = engine.receive(hook, now: now.timeIntervalSince1970) }
        for event in batch.events { _ = engine.receive(event, now: now.timeIntervalSince1970) }
        for entry in batch.retiredObservations { engine.retireObservation(entry.key, session: entry.session) }
        for key in batch.removedIDs { engine.removeObservation(key) }
        for key in batch.expiredIDs { engine.expire(key) }
    }
    var liveJobs: [TrackedJob] { engine.jobs.values.filter { !$0.event.phase.isTerminal && !$0.stale } }
}

@main struct Entry {
    static func main() {
        do { try fixtures() }
        catch { FileHandle.standardError.write(Data(("FAIL \(error)\n").utf8)); exit(1) }
    }
    static func fixtures() throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1])
        var passed = 0
        var failures: [String] = []
        func run(_ name: String, _ body: (Fixture) throws -> Void) throws {
            let fixture = try Fixture(parent: parent, name: name)
            do { try body(fixture) }
            catch { failures.append(name + ": " + String(describing: error)); print("FAIL " + failures.last!); return }
            passed += 1; print("PASS " + name)
        }
        try run("native-to-fresh-hook-handover") { f in
            let initial = try f.poll(); f.apply(initial)
            try require(f.liveJobs.count == 1 && f.liveJobs[0].event.source == f.source, "Native activity missing")
            let hook = f.hook()
            let handover = try f.poll(hook: hook); f.apply(handover, hook: hook)
            try require(handover.events.isEmpty && handover.removedIDs.contains(f.key), "Native duplicate not removed")
            try require(f.liveJobs.count == 1 && f.liveJobs[0].event.source == f.hookSource, "Handover created duplicate or missing work")
        }
        for condition in ["stale", "dead", "different-owner", "reused-pid"] {
            try run(condition + "-hook-native-fallback") { f in
                let ownerPID: Int32 = condition == "dead" ? Int32.max : condition == "different-owner" ? getppid() : f.pid
                let ownerBirth = condition == "reused-pid" ? f.birth + 1 : condition == "different-owner" ? ProcessIdentity.birth(getppid()) : f.birth
                let hook = f.hook(ownerPID: ownerPID, ownerBirth: ownerBirth)
                let result = try f.poll(hook: hook, hookAge: condition == "stale" ? 121 : 0)
                try require(result.events.count == 1 && result.events[0].phase == .running, "Valid native fallback suppressed")
                try require(result.removedIDs.contains(f.hookKey), "Superseded hook duplicate not removed")
                f.apply(result, hook: hook)
                try require(f.liveJobs.count == 1 && f.liveJobs[0].event.source == f.source, "Fallback did not own one observation")
            }
        }
        try run("native-terminal-retires-fresh-hook") { f in
            let first = f.hook(), initial = try f.poll(hook: first); f.apply(initial, hook: first)
            try f.append(f.event("task_complete"))
            let heartbeat = f.hook(sequence: 2), terminal = try f.poll(hook: heartbeat)
            try require(terminal.events.count == 1 && terminal.events[0].phase == .completed, "Native terminal was ignored")
            try require(terminal.retiredObservations.contains { $0.key == f.hookKey && $0.session == heartbeat.session }, "Hook incarnation not retired")
            f.apply(terminal, hook: heartbeat)
            try require(f.liveJobs.isEmpty, "Completed turn still protected")
            let late = f.hook(sequence: 3), repeated = try f.poll(hook: late)
            f.apply(repeated, hook: late)
            try require(repeated.events.isEmpty, "Completed task repeatedly heartbeated")
            try require(f.liveJobs.isEmpty, "Late hook resurrected completed turn")
        }
        try run("new-turn-retires-previous-observation") { f in
            let initial = try f.poll(); f.apply(initial)
            let next = UUID().uuidString.lowercased()
            try f.append(f.event("task_complete") + f.event("task_started", turnID: next))
            let oldHook = f.hook(sequence: 2), advanced = try f.poll(hook: oldHook)
            f.apply(advanced, hook: oldHook)
            try require(advanced.removedIDs.contains(f.key), "Prior native turn retained")
            try require(advanced.events.count == 1 && advanced.events[0].id == f.thread + ":" + next, "Latest turn missing")
            try require(f.liveJobs.count == 1 && f.liveJobs[0].event.id.hasSuffix(next), "Skipped terminal left old hook alive")
            try require(advanced.retiredObservations.contains { $0.key == f.hookKey && $0.session == oldHook.session }, "Superseded turn hook not sealed")
        }
        try run("new-start-without-terminal-does-not-seal-old-hook") { f in
            f.apply(try f.poll())
            let next = UUID().uuidString.lowercased()
            try f.append(f.event("task_started", turnID: next))
            let oldHook = f.hook(sequence: 2), advanced = try f.poll(hook: oldHook)
            f.apply(advanced, hook: oldHook)
            try require(advanced.retiredObservations.isEmpty,
                        "New start was incorrectly treated as explicit terminal evidence")
            try require(advanced.removedIDs.contains(f.key) && !advanced.removedIDs.contains(f.hookKey),
                        "New start incorrectly removed the prior independent hook")
            try require(f.liveJobs.contains { $0.event.source == f.hookSource && $0.event.id == f.id },
                        "Prior hook was sealed without terminal evidence")
            try require(advanced.events.count == 1 && advanced.events[0].id == f.thread + ":" + next,
                        "New native turn was not observed")
        }
        try run("partial-tail-retains-finite-lease-then-recovers") { f in
            f.apply(try f.poll())
            var policy = PolicySettings(); policy.leaseDuration = 30
            let power = PowerSnapshot(percent: 80, onAC: true)
            let initialSeen = f.engine.jobs[f.key]!.lastSeen
            _ = f.engine.evaluate(now: f.now.timeIntervalSince1970, power: power, settings: policy)
            try f.append("{\"type\":\"response_item\",\"payload\":{\"content\":\"Fixture only\"}}")
            let partial = try f.poll(); f.apply(partial)
            try require(partial.events.isEmpty && partial.expiredIDs.isEmpty && f.liveJobs.count == 1,
                        "Partial tail emitted a heartbeat or instantly withdrew an existing contact lease")
            try require(f.engine.jobs[f.key]?.lastSeen == initialSeen, "Catch-up refreshed contact without complete EOF")
            f.now = Date(timeIntervalSince1970: initialSeen + policy.leaseDuration + 1)
            let stillPartial = try f.poll(); f.apply(stillPartial)
            let expired = f.engine.evaluate(now: f.now.timeIntervalSince1970, power: power, settings: policy)
            try require(stillPartial.events.isEmpty && !expired.shouldHold && f.liveJobs.isEmpty,
                        "Prolonged catch-up bypassed the finite policy lease")
            try f.append("\n")
            let resumed = try f.poll(); f.apply(resumed)
            let recovered = f.engine.evaluate(now: f.now.timeIntervalSince1970, power: power, settings: policy)
            try require(resumed.events.count == 1 && resumed.events[0].phase == .running && recovered.shouldHold &&
                        f.liveJobs.count == 1 && f.engine.jobs[f.key]!.lastSeen > initialSeen, "Complete tail did not recover contact")
        }
        for fault in ["malformed", "truncated"] {
            try run(fault + "-latch-survives-missing-fd") { f in
                f.apply(try f.poll())
                if fault == "malformed" { try f.append("invalid-json\n") }
                else { try f.replaceContents("") }
                let broken = try f.poll(); f.apply(broken)
                try require(broken.events.isEmpty && broken.expiredIDs.contains(f.key), "Fault did not expire contact")
                f.visible = false; f.apply(try f.poll())
                try f.replaceContents(f.header() + f.event("task_started"))
                f.visible = true
                let restored = try f.poll(); f.apply(restored)
                try require(restored.events.isEmpty && f.liveJobs.isEmpty, "Missing descriptor silently cleared scanner failure")
                f.apply(try f.poll(enabled: false))
                let rearmed = try f.poll(); f.apply(rearmed)
                try require(rearmed.events.count == 1 && f.liveJobs.count == 1, "Explicit monitoring reset failed")
            }
        }
        try run("terminal-file-disappearance-prunes-internal-state") { f in
            f.apply(try f.poll())
            try f.append(f.event("turn_aborted"))
            let ended = try f.poll(); f.apply(ended)
            try require(ended.events.first?.phase == .cancelled, "Cancellation not observed")
            f.visible = false
            let missing = try f.poll(); f.apply(missing)
            try require(missing.events.isEmpty && missing.expiredIDs.isEmpty && f.liveJobs.isEmpty, "Terminal disappearance resurrected activity")
            let disabled = try f.poll(enabled: false)
            try require(disabled.removedIDs.isEmpty, "Gone terminal remained in coordinator tracking")
            f.visible = true
            let returned = try f.poll(); f.apply(returned)
            try require(returned.events.allSatisfy { $0.phase.isTerminal } && f.liveJobs.isEmpty, "Reopened completed file became active")
        }
        if !failures.isEmpty { throw Failure.assertion(failures.joined(separator: "\n")) }
        print("Passed \(passed) coordinator scenarios; owned fixtures only, no native power operations.")
    }
}
'''


def command(args, timeout=120):
    result = subprocess.run(args, cwd=REPO, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug-path", type=Path, help="Existing SwiftPM arm64-apple-macosx/debug directory")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="longhaul-codex-monitor-tests-"))
    os.chmod(work, 0o700)
    success = False
    try:
        debug = args.debug_path
        if debug is None:
            scratch = work / "build"
            command(["swift", "build", "--scratch-path", str(scratch), "--target", "LonghaulBridge"])
            debug = scratch / "arm64-apple-macosx/debug"
        objects = []
        for target in ["LonghaulCore", "LonghaulBridge", "CLonghaulSupport"]:
            directory = debug / (target + ".build")
            # Exclude copied outputs such as 'File.swift 2.o' in reused caches.
            found = sorted(directory.glob("*.swift.o")) + sorted(directory.glob("*.c.o"))
            if not found:
                raise RuntimeError("Missing current objects for " + target)
            objects.extend(map(str, found))
        source, binary = work / "Fixture.swift", work / "codex-monitor-fixture"
        source.write_text(HARNESS)
        command(["swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                 "-I", str(debug / "Modules"), "-I", str(debug / "CLonghaulSupport.build"),
                 str(REPO / "App/Services/CodexActivityMonitor.swift"), str(source), *objects,
                 "-framework", "AppKit", "-framework", "IOKit", "-o", str(binary)])
        print(command([str(binary), str(work)], timeout=30), end="")
        success = True
    finally:
        if success:
            shutil.rmtree(work)  # Only disposable files created by this invocation.
        else:
            print("Retained failing fixture:", work)


if __name__ == "__main__":
    main()
