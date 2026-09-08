#!/usr/bin/env python3
"""Exercise the real app service with an isolated fake CLI, never native power writes.

By default build only LonghaulBridge in disposable scratch storage. A caller may
provide --debug-path to reuse freshly built SwiftPM Bridge/Core/C object files.
The fake child imports the protocol and reads continuous time/process identity;
it never invokes native power inspection, assertions, sleep, or selector writes.
"""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin
import LonghaulBridge
import LonghaulCore

enum FixtureError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@main @MainActor struct Entry {
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LONGHAUL_LID_APP_TEST_ROOT"]!) }
    static var mode: String { ProcessInfo.processInfo.environment["LONGHAUL_LID_APP_TEST_MODE"]! }
    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]) }
    static var now: Double { LidQualificationIO.monotonicSeconds() }
    static var logURL: URL { root.appendingPathComponent("grants.jsonl") }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw FixtureError.failed(message) }
    }
    static func pause(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
    static func wait(_ message: String, seconds: Double = 3, until condition: () -> Bool) async throws {
        let deadline = now + seconds
        while !condition(), now < deadline { try await pause(0.01) }
        try require(condition(), "Timed out: " + message)
    }
    static func grants() -> [LidSessionGrant] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(LidSessionGrant.self, from: Data($0)) }
    }
    static func evaluate(_ service: LidProtectionService, work: Bool = true, eligible: Bool = true,
                         timestamp: Double? = nil, command: URL? = nil) {
        service.evaluate(workPresent: work, eligible: eligible, evaluatedAt: timestamp ?? now,
                         executable: command ?? executable)
    }

    // The only implementation of the fake child. There is no production runner
    // entry point in this binary and no native power call anywhere in this file.
    static func child() throws {
        _ = alarm(25)
        let fd = Darwin.open(logURL.path, O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FixtureError.failed("Could not open fake grant log") }
        defer { Darwin.close(fd) }
        var reportSequence: UInt64 = 0
        var previousGrant: UInt64 = 0
        func encodedStatus(_ grant: LidSessionGrant, _ state: LidSessionStatus.State) throws -> Data {
            reportSequence += 1
            var data = try JSONEncoder().encode(LidSessionStatus(identity: grant.identity,
                sequence: reportSequence, observedAt: now, state: state,
                reason: "Fake child fixture", leaseExpiresAt: state == .active ? grant.expiresAt : nil))
            data.append(10); return data
        }
        while let line = readLine() {
            let grant = try JSONDecoder().decode(LidSessionGrant.self, from: Data(line.utf8))
            try require(grant.identity.isValid && grant.sequence > previousGrant, "Invalid app grant identity/sequence")
            try require(grant.evaluatedAt <= now && grant.expiresAt - grant.evaluatedAt <= 10, "Grant deadline was rewritten")
            previousGrant = grant.sequence
            let data = Data((line + "\n").utf8)
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            try require(written == data.count, "Fake grant log write failed")
            if grant.kind == .revoke {
                var statuses = try encodedStatus(grant, .stopping)
                statuses.append(try encodedStatus(grant, .stopped))
                FileHandle.standardOutput.write(statuses)
                return
            }
            if mode == "remote-stop-work-gap" || (mode == "setting-change-before-eof" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-eof").path)) {
                var statuses = try encodedStatus(grant, .active)
                statuses.append(try encodedStatus(grant, .stopping))
                statuses.append(try encodedStatus(grant, .stopped))
                FileHandle.standardOutput.write(statuses)
                let deadline = now + 3
                while !FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-eof").path), now < deadline { usleep(1000) }
                return
            }
            if mode == "terminal-burst" {
                var statuses = try encodedStatus(grant, .starting)
                statuses.append(try encodedStatus(grant, .active))
                statuses.append(try encodedStatus(grant, .stopping))
                statuses.append(try encodedStatus(grant, .stopped))
                FileHandle.standardOutput.write(statuses)
                try Data().write(to: root.appendingPathComponent("burst-sent"))
                return
            }
            if mode == "active-invalid-eof" {
                var statuses = try encodedStatus(grant, .active)
                statuses.append(Data("invalid status\n".utf8))
                FileHandle.standardOutput.write(statuses)
                return
            }
            if mode == "revoke-before-active" {
                let deadline = now + 3
                while !FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-active").path), now < deadline {
                    usleep(1000)
                }
            }
            FileHandle.standardOutput.write(try encodedStatus(grant, .active))
        }
    }

    static func fixture() async throws {
        let service = LidProtectionService()
        switch mode {
        case "setting-change-before-eof":
            evaluate(service)
            try await wait("stopped report before EOF") { service.state == .stopped }
            service.rearm()
            try Data().write(to: root.appendingPathComponent("allow-eof"))
            try await pause(0.15)
            evaluate(service)
            try await wait("explicit rearm survives EOF") { service.active && grants().count == 2 }
            try require(grants()[0].identity != grants()[1].identity, "New attempt reused stopped session")
            service.revoke(reason: "Fixture finished")
            try await wait("new attempt cleanup") { service.state == .stopped }
        case "custom-cutoff-grants":
            service.evaluate(workPresent: true, eligible: true, evaluatedAt: now, executable: executable,
                             batteryPolicy: .init(cutoffPercent: 37))
            try await wait("custom cutoff active") { service.active }
            service.evaluate(workPresent: true, eligible: true, evaluatedAt: now, executable: executable,
                             batteryPolicy: .init(cutoffEnabled: false, cutoffPercent: 37))
            try await wait("cutoff off acknowledged") { grants().count == 2 && service.detail.contains("off") }
            let rows = grants()
            try require(rows[0].version == 2 && rows[0].effectiveBatteryPolicy?.cutoffPercent == 37,
                        "Selected cutoff was not carried by original grant")
            try require(rows[1].effectiveBatteryPolicy?.cutoffEnabled == false && rows[1].identity == rows[0].identity,
                        "Turning cutoff off lost policy or restarted session")
            service.revoke(reason: "Fixture finished")
            try await wait("custom cutoff cleanup") { service.state == .stopped }
        case "setting-change-during-cleanup":
            evaluate(service)
            try await wait("initial setting session") { service.active }
            evaluate(service, eligible: false)
            service.rearm()
            try await wait("setting cleanup") { service.state == .stopped }
            try await pause(0.1)
            evaluate(service)
            try await wait("explicit setting rearm after cleanup") { service.active && grants().count == 3 }
            try require(grants()[0].identity != grants()[2].identity, "Clean rearm reused stopped identity")
            service.revoke(reason: "Fixture finished")
            try await wait("rearmed cleanup") { service.state == .stopped }
        case "invalid-cutoff":
            service.evaluate(workPresent: true, eligible: true, evaluatedAt: now, executable: executable,
                             batteryPolicy: .init(cutoffEnabled: false, cutoffPercent: 101))
            try await pause(0.1)
            try require(grants().isEmpty && !service.active, "Invalid cutoff launched protection")
        case "terminal-burst":
            evaluate(service)
            // Hold the consumer so terminal status and EOF are queued together.
            let deadline = now + 3
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("burst-sent").path), now < deadline {
                usleep(1000)
            }
            try await wait("terminal report before EOF") { service.state == .stopped }
            try await pause(0.15)
            try require(!service.active && service.state == .stopped, "EOF reordered or revived terminal protection")
            evaluate(service)
            try await pause(0.15)
            try require(grants().count == 1, "Finished same work episode automatically relaunched")
        case "active-invalid-eof":
            evaluate(service)
            try await wait("failed status channel") { service.state == .cleanupRequired }
            try await pause(0.15)
            try require(!service.active, "Delayed active report revived failed transport")
            service.rearm(); evaluate(service)
            try await pause(0.15)
            try require(grants().count == 1 && !service.active, "Cleanup debt was rearmed")
        case "no-timer-renewal":
            evaluate(service)
            try await wait("first active report") { service.active }
            let first = grants().first!
            try await pause(10.2)
            try require(grants().count == 1, "Transport renewed without a completed policy evaluation")
            try require(!service.active, "Expired grant still appears active")
            try require(service.expiresAt == first.expiresAt, "App extended the original deadline")
            evaluate(service)
            try await wait("expired session cleanup") { service.state == .stopped }
            try require(grants().map(\.kind) == [.renew, .revoke], "Expired session accepted another renewal")
        case "delayed-evaluation":
            evaluate(service, timestamp: now - 3)
            try await pause(0.15)
            try require(grants().isEmpty && !service.active, "Delayed policy launched a child")
            evaluate(service)
            try await pause(0.15)
            try require(grants().isEmpty, "Delayed-policy failure was automatically retried")
            service.rearm(); evaluate(service)
            try await wait("explicit rearm") { service.active }
            evaluate(service, timestamp: now - 3)
            try await wait("delayed renewal revocation") { service.state == .stopped }
            try require(grants().map(\.kind) == [.renew, .revoke], "Delayed evaluation issued a new grant")
        case "normal-revoke":
            evaluate(service)
            try await wait("active lifecycle") { service.active }
            evaluate(service)
            try await wait("second fresh grant") { grants().count == 2 }
            evaluate(service, work: false, eligible: false)
            try require(!service.active && service.state == .stopping, "Local revoke left protection active")
            try await wait("normal stopped lifecycle") { service.state == .stopped }
            try await pause(0.1)
            try require(grants().map(\.kind) == [.renew, .renew, .revoke], "Unexpected grant lifecycle")
            evaluate(service, work: false, eligible: false)
            evaluate(service)
            try await wait("new work episode") { service.active && grants().count == 4 }
            let rows = grants()
            try require(rows[0].identity.sessionID != rows[3].identity.sessionID, "New work reused old session identity")
            evaluate(service, work: false, eligible: false)
            try await wait("new episode cleanup") { service.state == .stopped }
        case "revoke-before-active":
            evaluate(service)
            try await wait("first queued grant") { grants().count == 1 }
            service.revoke(reason: "Fixture user pause")
            try Data().write(to: root.appendingPathComponent("allow-active"))
            let deadline = now + 3
            while service.state != .stopped, now < deadline {
                try require(!service.active, "Queued active report overrode local revoke")
                try await pause(0.005)
            }
            try require(service.state == .stopped && !service.active, "Revoked session did not stop")
            try require(grants().map(\.kind) == [.renew, .revoke], "Revoke was reordered in transport")
        case "power-interruption":
            evaluate(service)
            try await wait("power fixture active") { service.active }
            evaluate(service, work: true, eligible: false)
            try await wait("unsafe power release") { service.state == .stopped }
            try await pause(0.1)
            evaluate(service, work: true, eligible: true)
            try await pause(0.15)
            try require(grants().map(\.kind) == [.renew, .revoke] && !service.active,
                        "Power recovery automatically restarted the same work episode")
        case "power-interruption-work-gap":
            evaluate(service)
            try await wait("gap fixture active") { service.active }
            evaluate(service, work: true, eligible: false)
            try await wait("gap fixture stopped") { service.state == .stopped }
            try await pause(0.1)
            evaluate(service, work: false, eligible: false)
            evaluate(service)
            try await pause(0.15)
            try require(grants().map(\.kind) == [.renew, .revoke] && !service.active,
                        "A no-work snapshot silently rearmed an interrupted session")
            service.rearm(); evaluate(service)
            try await wait("explicit rearm after gap") { service.active && grants().count == 3 }
            evaluate(service, work: false, eligible: false)
            try await wait("rearmed fixture stopped") { service.state == .stopped }
        case "remote-stop-work-gap":
            evaluate(service)
            try await wait("remote stop before EOF") { service.state == .stopped }
            // Work briefly disappears while the helper's terminal reports are
            // consumed, before EOF retires the transport.
            evaluate(service, work: false, eligible: false)
            try Data().write(to: root.appendingPathComponent("allow-eof"))
            try await pause(0.15)
            evaluate(service, work: false, eligible: false)
            evaluate(service)
            try await pause(0.15)
            try require(grants().count == 1 && !service.active && service.state == .stopped,
                        "Work disappearing before EOF erased failure or invalidated accepted cleanup")
        case "startup-failure":
            evaluate(service, command: root.appendingPathComponent("missing-executable"))
            try await wait("startup failure") { service.state == .unavailable }
            try require(!service.active && grants().isEmpty, "Startup failure claimed protection or cleanup debt")
            evaluate(service)
            try await pause(0.15)
            try require(grants().isEmpty, "Startup failure automatically retried")
        default: throw FixtureError.failed("Unknown fixture mode")
        }
        print("PASS " + mode)
    }

    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "lid-session" { try child() }
            else { try await fixture() }
        } catch {
            FileHandle.standardError.write(Data(("FAIL \(mode): \(error)\n").utf8)); exit(1)
        }
    }
}
'''


def command(args, timeout=120):
    result = subprocess.run(args, cwd=REPO, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug-path", type=Path, help="Existing SwiftPM arm64-apple-macosx/debug directory")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="longhaul-lid-app-service-tests-"))
    os.chmod(work, 0o700)
    succeeded = False
    try:
        debug = args.debug_path
        if debug is None:
            scratch = work / "build"
            command(["swift", "build", "--scratch-path", str(scratch), "--target", "LonghaulBridge"])
            debug = scratch / "arm64-apple-macosx/debug"
        objects = []
        for target in ["LonghaulCore", "LonghaulBridge", "CLonghaulSupport"]:
            target_objects = sorted((debug / (target + ".build")).glob("*.o"))
            if not target_objects:
                raise RuntimeError("No compiled objects for " + target)
            objects.extend(map(str, target_objects))
        source = work / "Harness.swift"
        source.write_text(HARNESS)
        binary = work / "lid-app-service-fixture"
        command(["swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                 "-I", str(debug / "Modules"), "-I", str(debug / "CLonghaulSupport.build"),
                 str(REPO / "App/Services/LidProtectionService.swift"), str(source), *objects,
                 "-framework", "AppKit", "-framework", "IOKit", "-o", str(binary)])
        scenarios = ["terminal-burst", "active-invalid-eof", "no-timer-renewal", "delayed-evaluation",
                     "normal-revoke", "revoke-before-active", "power-interruption", "power-interruption-work-gap",
                     "remote-stop-work-gap", "startup-failure", "custom-cutoff-grants",
                     "setting-change-during-cleanup", "setting-change-before-eof", "invalid-cutoff"]
        for mode in scenarios:
            root = work / mode
            root.mkdir(mode=0o700)
            environment = dict(os.environ, LONGHAUL_LID_APP_TEST_ROOT=str(root), LONGHAUL_LID_APP_TEST_MODE=mode)
            process = subprocess.Popen([str(binary)], env=environment, text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=20)
                if process.returncode:
                    raise RuntimeError(stdout + stderr)
                print(stdout.strip())
            finally:
                # This group contains only the disposable harness and its fake child.
                # Also retire a child left behind if its test parent failed first.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        succeeded = True
        print(f"Passed {len(scenarios)} app-service scenarios; no native power operations.")
    finally:
        if succeeded:
            shutil.rmtree(work)  # Only disposable files created by this invocation.
        else:
            print("Retained failing fixture:", work)


if __name__ == "__main__":
    main()
