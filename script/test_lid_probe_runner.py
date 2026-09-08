#!/usr/bin/env python3
"""Process simulations only. Compiles out native lid mutations and native sensors."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix="longhaul-lid-process-tests-"))
os.chmod(WORK, 0o700)
HARNESS = r'''
import Foundation
import Darwin
import LonghaulBridge
@main struct Entry {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "lid-watchdog" { exit(LidProbeRunner.watchdog(arguments: Array(args.dropFirst()))) }
        if args.first == "duration-matrix" {
            let ack = LidProbeRunner.acknowledgement
            precondition(LidProbeRunner.requestedDuration([ack]) == 30)
            for seconds in ["30", "60"] {
                precondition(LidProbeRunner.requestedDuration([ack, "--duration", seconds]) == Double(seconds))
                precondition(LidProbeRunner.requestedDuration(["--duration", seconds, ack]) == Double(seconds))
            }
            for invalid in [[], ["--duration", "60"], [ack, ack], [ack, "--duration"],
                            [ack, "--duration", "30", "--duration", "60"], [ack, "--unknown"]] {
                precondition(!LidProbeRunner.validArguments(invalid))
            }
            for seconds in ["0", "-1", "29", "31", "45", "61", "120", "NaN", "inf", "30.0", "060"] {
                precondition(!LidProbeRunner.validArguments([ack, "--duration", seconds]))
            }
            for seconds in [30.0, 60.0] {
                var wire = LidProbeRunner.Wire(kind: "authorize", token: UUID().uuidString, time: 100,
                    pid: 1001, birth: 11, parentPID: 1000, parentBirth: 10,
                    started: 100, deadline: 100 + seconds, duration: seconds,
                    directory: "/tmp/lid-probe-fixture", lockDirectory: "/tmp/private-fixture")
                func valid(_ candidate: LidProbeRunner.Wire) -> Bool {
                    LidProbeRunner.validAuthorization(candidate, parentPID: 1000, parentBirth: 10,
                        childPID: 1001, childBirth: 11, now: 101)
                }
                precondition(valid(wire))
                wire.deadline = 100 + seconds + 1; precondition(!valid(wire))
                wire.deadline = 100 + seconds; wire.duration = nil; precondition(!valid(wire))
                for invalid in [0.0, 29, 31, 61, .infinity, .nan] {
                    wire.duration = invalid; wire.deadline = 100 + invalid
                    precondition(!valid(wire))
                }
            }
            return
        }
        if args.first == "invalid-admission", args.count >= 2 {
            let box = try Mailbox(root: URL(fileURLWithPath: args[1]))
            exit(LidProbeRunner.run(arguments: Array(args.dropFirst(2)), box: box))
        }
        if args.first == "cleanup-matrix" {
            for published in [true, false] {
                let snapshot = LidRegistrySnapshot(lidClosed: false, clamshellCausesSleep: published, sleepDisabled: false)
                precondition(LidProbeRunner.cleanupDecision(mayHaveEnabled: true, registry: snapshot,
                    ownerScanComplete: true, knownOwners: []) == .clearSharedBit)
                precondition(LidProbeRunner.cleanupDecision(mayHaveEnabled: true, registry: snapshot,
                    ownerScanComplete: false, knownOwners: []) == .unresolved)
                precondition(LidProbeRunner.cleanupDecision(mayHaveEnabled: true, registry: snapshot,
                    ownerScanComplete: true, knownOwners: ["Other controller"]) == .unresolved)
                precondition(LidProbeRunner.cleanupDecision(mayHaveEnabled: false, registry: snapshot,
                    ownerScanComplete: true, knownOwners: []) == .unnecessary)
            }
            let unknown = LidRegistrySnapshot(lidClosed: nil, clamshellCausesSleep: nil, sleepDisabled: nil)
            precondition(LidProbeRunner.cleanupDecision(mayHaveEnabled: true, registry: unknown,
                ownerScanComplete: true, knownOwners: []) == .unresolved)
            return
        }
        if args.first == "identity", args.count == 3, let pid = Int32(args[1]), let birth = UInt64(args[2]) {
            exit(ProcessIdentity.isSame(pid: pid, birth: birth) ? 0 : 1)
        }
        if args.first == "lock-available", args.count == 2 {
            let fd = Darwin.open(args[1], O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { exit(2) }; defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(1) }
            let childPath = URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent(".lid-watchdog.lock").path
            let childLock = Darwin.open(childPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard childLock >= 0 else { exit(2) }; defer { Darwin.close(childLock) }
            exit(flock(childLock, LOCK_EX | LOCK_NB) == 0 ? 0 : 1)
        }
        guard (2...3).contains(args.count), args[0] == "fixture" else { exit(2) }
        let box = try Mailbox(root: URL(fileURLWithPath: args[1]))
        let duration = args.count == 3 ? ["--duration", args[2]] : []
        exit(LidProbeRunner.run(arguments: [LidProbeRunner.acknowledgement] + duration, box: box))
    }
}
'''


def command(args):
    result = subprocess.run(args, cwd=REPO, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def wait_for(predicate, label, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("Timed out: " + label)


def rows(path):
    if not path.exists():
        return []
    values = []
    for line in path.read_text().splitlines():
        try:
            values.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # A concurrent append may not yet be complete.
    return values


class Scenario:
    def __init__(self, name, executable, markers=(), duration=None):
        self.name, self.executable = name, executable
        self.root = WORK / name
        self.root.mkdir(mode=0o700)
        for marker in markers:
            (self.root / marker).touch(mode=0o600)
        environment = dict(os.environ, LONGHAUL_LID_TEST_DIR=str(self.root))
        self.output = open(self.root / "output.txt", "w+")
        args = [str(executable), "fixture", str(self.root / "mailbox")]
        if duration is not None:
            args.append(str(duration))
        self.parent = subprocess.Popen(args,
                                       env=environment, stdout=self.output, stderr=subprocess.STDOUT)
        self.child = None
        scenarios.append(self)
        wait_for(lambda: (self.root / "held").exists(), name + " fake enable")
        wait_for(lambda: bool(list((self.root / "mailbox").glob("lid-probe-*/watchdog.jsonl"))), name + " journal")
        self.directory = next((self.root / "mailbox").glob("lid-probe-*"))
        first = rows(self.directory / "watchdog.jsonl")[0]
        self.child = (first["pid"], first["birth"])

    def child_alive(self):
        return self.child and subprocess.run([str(self.executable), "identity", *map(str, self.child)],
                                             stdout=subprocess.DEVNULL).returncode == 0

    def signal_child(self, sig):
        if self.child_alive():
            os.kill(self.child[0], sig)

    def operations(self):
        return [entry["disabled"] for entry in rows(self.root / "mutations.jsonl")]

    def cleaned_once(self):
        wait_for(lambda: not (self.root / "held").exists(), self.name + " fake cleanup")
        wait_for(lambda: not self.child_alive(), self.name + " child exit")
        assert self.operations() == [True, False], (self.name, self.operations())
        time.sleep(0.15)
        assert self.operations() == [True, False], "Late re-enable or repeated cleanup"

    def lock_available(self):
        return subprocess.run([str(self.executable), "lock-available", str(self.root / "mailbox/.lid-probe.lock")],
                              stdout=subprocess.DEVNULL).returncode == 0

    def finish(self):
        if self.parent.poll() is None:
            self.parent.kill()
        self.parent.wait(timeout=3)
        self.signal_child(signal.SIGKILL)
        self.output.close()


scenarios = []
success = False
try:
    build = WORK / "build"
    command(["swift", "build", "--scratch-path", str(build), "--product", "longhaul"])
    debug = build / "arm64-apple-macosx/debug"
    harness = WORK / "Harness.swift"
    harness.write_text(HARNESS)
    executable = WORK / "lid-runner-simulation"
    objects = [str(path) for target in ["LonghaulCore", "LonghaulBridge", "CLonghaulSupport"]
               for path in (debug / (target + ".build")).glob("*.o")]
    command(["swiftc", "-D", "LONGHAUL_LID_PROBE_TESTING", "-parse-as-library", "-target", "arm64-apple-macos26.0",
             "-I", str(debug / "Modules"), "-I", str(debug / "CLonghaulSupport.build"),
             "Sources/LonghaulCLI/LidProbeRunner.swift", str(harness), *objects,
             "-framework", "AppKit", "-framework", "IOKit", "-o", str(executable)])

    def start(name, markers=(), duration=None):
        return Scenario(name, executable, markers, duration)

    command([str(executable), "duration-matrix"])
    invalid_root = WORK / "invalid-admission"
    invalid_root.mkdir(mode=0o700)
    environment = dict(os.environ, LONGHAUL_LID_TEST_DIR=str(invalid_root))
    for args in [[], ["--duration", "60"], ["--acknowledge-experimental-shared-state", "--duration", "61"]]:
        result = subprocess.run([str(executable), "invalid-admission", str(invalid_root / "mailbox"), *args],
                                env=environment, capture_output=True, timeout=3)
        assert result.returncode == 2
        assert not (invalid_root / "mutations.jsonl").exists()
        assert not list((invalid_root / "mailbox").glob("lid-probe-*"))
    print("PASS default30/explicit30/60 parsing, exact authenticated deadlines, invalid admission before mutation", flush=True)

    command([str(executable), "cleanup-matrix"])
    print("PASS pure cleanup matrix: both published values require one clear; unknown/co-owner states refuse", flush=True)

    s = start("normal-cap")
    assert s.parent.wait(timeout=11) == 0
    s.cleaned_once()
    operations = rows(s.root / "mutations.jsonl")
    assert 29 <= operations[-1]["time"] - operations[0]["time"] <= 31.5
    print("PASS normal 30-second cap, one fake enable/cleanup, no late re-enable", flush=True)

    s = start("explicit-60-cap", duration=60)
    assert s.parent.wait(timeout=19) == 0
    s.cleaned_once()
    operations = rows(s.root / "mutations.jsonl")
    assert 59 <= operations[-1]["time"] - operations[0]["time"] <= 61.5
    ended = next(r for r in rows(s.directory / "watchdog.jsonl") if r["event"] == "session-ended")
    assert "sessionExpired" in ended["note"] and "full interval: true" in ended["note"]
    print("PASS explicit60 cap, one balancing clear, full authenticated interval", flush=True)

    s = start("stale-registry", ("stale-true-after-enable", "stale-false-after-clear"), duration=30)
    assert s.parent.wait(timeout=11) == 0
    s.cleaned_once()
    journal = rows(s.directory / "watchdog.jsonl")
    active = [r for r in journal if r["event"] == "heartbeat"]
    assert active and all(r["sample"]["inspection"]["snapshot"]["clamshellCausesSleep"] for r in active)
    after = next(r for r in journal if r["event"] == "cleanup-observation")
    assert after["sample"]["inspection"]["snapshot"]["clamshellCausesSleep"] is False
    assert any(r["event"] == "session-ended" and "sessionExpired" in r["note"] for r in journal)
    print("PASS stale true after enable and stale false after clear: full duration, exactly one balancing clear", flush=True)

    s = start("early-unsafe-power")
    (s.root / "unsafe-power").touch(mode=0o600)
    assert s.parent.wait(timeout=4) == 3
    s.cleaned_once()
    ended = next(r for r in rows(s.directory / "watchdog.jsonl") if r["event"] == "session-ended")
    assert "full interval: false" in ended["note"]
    print("PASS early unsafe power balances once and reports incomplete qualification", flush=True)

    for name, marker, operations, remains_held in [
        ("clear-intent-death", "stall-before-clear-write", [True], True),
        ("clear-result-lost", "stall-after-clear-write", [True, False], False),
        ("clear-failed-result", "clear-reports-failure", [True, False], False),
    ]:
        s = start(name, (marker,))
        (s.root / "unsafe-power").touch(mode=0o600)
        assert s.parent.wait(timeout=4) == 3
        wait_for(lambda: not s.child_alive(), name + " child exit")
        assert (s.directory / "cleanup-attempt.json").exists()
        assert s.operations() == operations
        assert (s.root / "held").exists() is remains_held
        assert any(r.get("cleanupRequired") is True for r in rows(s.directory / "parent.jsonl"))
        time.sleep(0.15)
        assert s.operations() == operations, "Ambiguous or failed clear was retried"
        print("PASS " + name + ": durable cleanup debt, no blind retry", flush=True)

    s = start("clear-receipt-child-death", ("stall-after-clear-receipt",))
    (s.root / "unsafe-power").touch(mode=0o600)
    assert s.parent.wait(timeout=4) == 3
    s.cleaned_once()
    assert (s.directory / "cleanup-result.json").exists()
    assert any(r["event"] == "cleanup-no-retry" and r["cleanupRequired"] is False
               for r in rows(s.directory / "parent.jsonl"))
    print("PASS child death after durable clear receipt: parent recognizes acceptance without duplicate clear", flush=True)

    s = start("parent-death")
    s.parent.kill(); s.parent.wait(timeout=3)
    s.cleaned_once()
    print("PASS parent death after fake enable: child cleanup", flush=True)

    s = start("child-death")
    s.signal_child(signal.SIGKILL)
    assert s.parent.wait(timeout=4) == 3
    s.cleaned_once()
    print("PASS terminated child: confirmed-stop parent takeover", flush=True)

    s = start("child-stall")
    s.signal_child(signal.SIGSTOP)
    assert s.parent.wait(timeout=4) == 3
    s.cleaned_once()
    print("PASS stalled child: terminated before one parent cleanup", flush=True)

    s = start("inherited-lock")
    s.signal_child(signal.SIGSTOP)
    s.parent.kill(); s.parent.wait(timeout=3)
    assert s.child_alive(), "Stopped watchdog did not survive parent death"
    assert not s.lock_available(), "A new probe acquired admission while the watchdog remained alive"
    s.signal_child(signal.SIGCONT)
    s.cleaned_once()
    wait_for(s.lock_available, "lock release after child cleanup")
    print("PASS independent watchdog lock excludes new probe after parent death until cleanup/exit", flush=True)

    s = start("new-owner")
    (s.root / "competing-owner").touch(mode=0o600)
    assert s.parent.wait(timeout=4) == 3
    wait_for(lambda: not s.child_alive(), "conflict child exit")
    assert s.operations() == [True] and (s.root / "held").exists()
    assert (s.directory / "owner-conflict").exists()
    print("PASS new co-owner: sticky cleanupRequired, no blind clear", flush=True)

    s = start("unknown-owner")
    (s.root / "unknown-owner").touch(mode=0o600)
    assert s.parent.wait(timeout=4) == 3
    wait_for(lambda: not s.child_alive(), "unknown owner child exit")
    assert s.operations() == [True] and (s.root / "held").exists()
    assert (s.directory / "owner-conflict").exists()
    print("PASS unknown owner scan: cleanup debt and no clear", flush=True)

    s = start("simultaneous-death")
    os.kill(s.parent.pid, signal.SIGSTOP)
    s.signal_child(signal.SIGSTOP)
    s.signal_child(signal.SIGKILL)
    s.parent.kill(); s.parent.wait(timeout=3)
    wait_for(lambda: not s.child_alive(), "both processes exited")
    assert s.operations() == [True] and (s.root / "held").exists()
    assert any(r["event"] == "enable-may-be-attempted" for r in rows(s.directory / "parent.jsonl"))
    print("PASS evidence boundary: simultaneous death remains UNRESOLVED with cleanup intent", flush=True)
    print(f"{len(scenarios)} process scenarios plus duration/admission and cleanup matrices passed. Fake backend only; no native sensor/selector runner executed.", flush=True)
    success = True
finally:
    for scenario in scenarios:
        scenario.finish()
    if success:
        shutil.rmtree(WORK)  # All files here are disposable fixtures created by this script.
    else:
        print("Retained failed simulation evidence:", WORK, flush=True)
