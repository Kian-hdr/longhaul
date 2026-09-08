#!/usr/bin/env python3
"""Collect and assess an attended lid test. Never controls the lid or power policy.

Passing qualifies only the sampled disposable workload and conditions. It does
not qualify native Codex reporting, emergency handling or unattended operation.
"""
import argparse
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time


def require(condition, message):
    if not condition:
        raise ValueError(message)


def rows(path):
    data = Path(path).read_text()
    require(data.endswith("\n"), "Incomplete evidence file")
    return [json.loads(line) for line in data.splitlines()]


def continuous_clock():
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    lib.mach_continuous_time.restype = ctypes.c_uint64
    base = Timebase()
    require(lib.mach_timebase_info(ctypes.byref(base)) == 0 and base.denom, "Clock unavailable")
    return lambda: lib.mach_continuous_time() * base.numer / base.denom / 1e9


def workload(path, seconds):
    require(1 <= seconds <= 120, "Workload must be bounded to 1–120 seconds")
    clock = continuous_clock()
    start, chain, index = clock(), bytes(32), 0
    with open(path, "x", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        while True:
            finished = clock() - start >= seconds
            chain = hashlib.sha256(chain + index.to_bytes(8, "big")).digest()
            row = dict(index=index, continuous=clock(), wall=time.time(), digest=chain.hex())
            if finished:
                row.update(completed=True, requestedSeconds=seconds, startedContinuous=start)
            stream.write(json.dumps(row) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
            index += 1
            if finished:
                break
            time.sleep(0.2)
    return dict(samples=index, finalDigest=chain.hex())


def capture_power(path):
    output = subprocess.run(["/usr/bin/pmset", "-g", "log"], capture_output=True,
                            text=True, check=True, timeout=30).stdout
    records = []
    for line in output.splitlines():
        match = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4})\s+(Sleep|DarkWake|Wake)\s+\t(.*)$", line)
        if match:
            stamp, kind, detail = match.groups()
            records.append(dict(wall=dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S %z").timestamp(),
                                kind=kind, detail=detail.strip()))
    require(records, "No power history found; cannot establish coverage")
    result = dict(command=["/usr/bin/pmset", "-g", "log"], capturedAt=time.time(), records=records)
    with open(path, "x", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump(result, stream, indent=2)
    return dict(records=len(records))


def verify(probe, work, power, duration=30):
    require(duration in (30, 60), "Unsupported probe duration")
    journal = rows(Path(probe) / "watchdog.jsonl")
    parent = rows(Path(probe) / "parent.jsonl")
    samples = rows(work)
    history = json.loads(Path(power).read_text())
    require(len(samples) >= 2, "Missing workload observations")
    chain = bytes(32)
    for index, row in enumerate(samples):
        chain = hashlib.sha256(chain + index.to_bytes(8, "big")).digest()
        require(row["index"] == index and row["digest"] == chain.hex(), "Invalid workload output chain")
        require(all(math.isfinite(row[k]) for k in ("continuous", "wall")), "Invalid workload clock")
    for a, b in zip(samples, samples[1:]):
        require(0 < b["continuous"] - a["continuous"] <= 1, "Workload continuity gap")
        require(0 < b["wall"] - a["wall"] <= 1, "Wall-clock gap or change")
    completion = samples[-1]
    require(completion.get("completed") is True and not any(r.get("completed") for r in samples[:-1]),
            "Missing final workload observation")
    requested, started = completion["requestedSeconds"], completion["startedContinuous"]
    require(1 <= requested <= 120 and 0 <= samples[0]["continuous"] - started < 1 and
            requested <= completion["continuous"] - started <= requested + 1,
            "Workload duration was interrupted or unconfirmed")
    for name in ("enable-result", "cleanup-result"):
        result = [r for r in journal if r["event"] == name]
        require(len(result) == 1, "Expected exactly one " + name)
        backend = result[0]["backend"]
        require(backend.get("serviceFound") is True and
                all(backend.get(k) == 0 for k in ("openResult", "callResult", "closeResult")),
                "Native call was not accepted: " + name)
    receipts = json.loads((Path(probe) / "cleanup-result.json").read_text())
    require(receipts == next(r["backend"] for r in journal if r["event"] == "cleanup-result"),
            "Cleanup receipt does not match journal")
    require((Path(probe) / "cleanup-attempt.json").is_file(), "Missing cleanup intent")
    require(not (Path(probe) / "owner-conflict").exists(), "Unresolved ownership conflict")
    require(parent[-1]["event"] == "final-observation" and parent[-1].get("cleanupRequired") is False,
            "Parent did not confirm clear acceptance")
    final = parent[-1]["sample"]
    require(final["inspection"]["snapshot"]["lidClosed"] is False and
            final["inspection"]["snapshot"]["sleepDisabled"] is False and
            final["ownerScanComplete"] and not final["knownOwners"], "Final open-lid observation missing or unsafe")
    ended = [r for r in journal if r["event"] == "session-ended"]
    require(len(ended) == 1 and ended[0].get("note", "").startswith("Stop: sessionExpired; failures: ;") and
            "full interval: true." in ended[0]["note"], "Probe did not complete its qualification interval")
    heartbeats = [r["sample"] for r in journal if r["event"] == "heartbeat"]
    require(len(heartbeats) >= 3, "Missing native observations")
    require(duration - 1 <= heartbeats[-1]["time"] - heartbeats[0]["time"] <= duration + 2,
            "Native observations do not cover the bounded qualification interval")
    for a, b in zip(heartbeats, heartbeats[1:]):
        require(0 < b["time"] - a["time"] <= 1, "Native monitor gap")
    require(next(r["time"] for r in journal if r["event"] == "enable-result") < heartbeats[0]["time"] and
            next(r["time"] for r in journal if r["event"] == "cleanup-result") > heartbeats[-1]["time"],
            "Native calls do not enclose observation interval")
    closed = [s for s in heartbeats if s["inspection"]["snapshot"]["lidClosed"] is True]
    require(closed and closed[-1]["time"] - closed[0]["time"] >= 10,
            "At least 10 seconds of sampled lid closure required")
    start, end = closed[0]["time"], closed[-1]["time"]
    require(any(s["time"] < start and s["inspection"]["snapshot"]["lidClosed"] is False for s in heartbeats),
            "Open lid not observed before closure")
    require(any(s["time"] > end and s["inspection"]["snapshot"]["lidClosed"] is False for s in heartbeats),
            "Reopening not observed before cleanup")
    for s in heartbeats:
        r, p = s["inspection"]["snapshot"], s["power"]
        require(s["powerKnown"] and s["ownerScanComplete"] and not s["knownOwners"], "Unknown power or competing owner")
        require(r["sleepDisabled"] is False and p["onAC"] and not p["discharging"] and
                p["percent"] >= 30 and p["thermalLevel"] == 0 and p["warningLevel"] == 1,
                "Conditions left the qualified range")
        if start <= s["time"] <= end:
            require(r["lidClosed"] is True and r["clamshellCausesSleep"] is False,
                    "Lid closure was not continuous")
    require(samples[0]["continuous"] < heartbeats[0]["time"] and
            samples[-1]["continuous"] > final["time"] >
            next(r["time"] for r in journal if r["event"] == "cleanup-result"),
            "Workload does not cover native observation and cleanup interval")
    require(history["command"] == ["/usr/bin/pmset", "-g", "log"] and
            history["capturedAt"] >= samples[-1]["wall"] + 2, "Power history must be captured after the completed workload")
    require(history["records"] and min(r["wall"] for r in history["records"]) <= samples[0]["wall"],
            "Power history does not cover the test")
    require(not any(r["kind"] == "Sleep" and samples[0]["wall"] - 1 <= r["wall"] <= history["capturedAt"]
                    for r in history["records"]), "macOS recorded sleep during the test")
    return dict(disposableWorkloadContinuityVerified=True, closedSeconds=end-start,
                probeDuration=duration,
                workloadSamples=len(samples), nativeSamples=len(heartbeats),
                cleanup="Call accepted; hidden shared state and future sleep remain unverified",
                scope="One attended AC-powered disposable workload; native Codex and unattended use unverified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    worker = sub.add_parser("workload"); worker.add_argument("output"); worker.add_argument("--seconds", type=int, default=60)
    capture = sub.add_parser("capture-power"); capture.add_argument("output")
    check = sub.add_parser("verify"); check.add_argument("probe"); check.add_argument("workload"); check.add_argument("power")
    check.add_argument("--duration", type=int, choices=(30, 60), default=30)
    args = parser.parse_args()
    try:
        if args.command == "workload": result = workload(args.output, args.seconds)
        elif args.command == "capture-power": result = capture_power(args.output)
        else: result = verify(args.probe, args.workload, args.power, args.duration)
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, "UNVERIFIED: " + str(error) + "\n")


if __name__ == "__main__":
    main()
