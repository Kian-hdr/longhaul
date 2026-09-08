#!/usr/bin/env python3
"""Synthetic evidence tests. Never calls the native clock, power log or selector."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from verify_lid_continuity import verify


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="longhaul-continuity-verifier-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backend = dict(serviceFound=True, openResult=0, callResult=0, closeResult=0)
        self.journal = [dict(event="enable-result", time=100, backend=self.backend)]
        for n in range(1, 121):
            closed = 10 <= n <= 50
            sample = dict(time=100+n*.25, powerKnown=True, ownerScanComplete=True, knownOwners=[],
                          inspection=dict(snapshot=dict(lidClosed=closed, clamshellCausesSleep=not closed, sleepDisabled=False)),
                          power=dict(onAC=True, discharging=False, percent=60, thermalLevel=0, warningLevel=1))
            self.journal.append(dict(event="heartbeat", sample=sample))
        self.journal += [dict(event="session-ended", note="Stop: sessionExpired; failures: ; elapsed: 30; full interval: true."),
                         dict(event="cleanup-result", time=131, backend=self.backend)]
        self.parent = [dict(event="final-observation", cleanupRequired=False,
                            sample=dict(time=132, ownerScanComplete=True, knownOwners=[],
                                        inspection=dict(snapshot=dict(lidClosed=False, sleepDisabled=False))))]
        self.work = []
        chain = bytes(32)
        for index in range(201):
            chain = hashlib.sha256(chain+index.to_bytes(8, "big")).digest()
            self.work.append(dict(index=index, continuous=99+index*.2, wall=1000+index*.2, digest=chain.hex()))
        self.work[-1].update(completed=True, requestedSeconds=40, startedContinuous=99)
        self.power = dict(command=["/usr/bin/pmset", "-g", "log"], capturedAt=1050,
                          records=[dict(wall=900, kind="Wake")])

    def check(self, duration=30):
        for name, value in [("watchdog.jsonl", self.journal), ("parent.jsonl", self.parent), ("work.jsonl", self.work)]:
            (self.root/name).write_text("".join(json.dumps(r)+"\n" for r in value))
        (self.root/"cleanup-result.json").write_text(json.dumps(self.backend))
        (self.root/"cleanup-attempt.json").write_text("{}")
        (self.root/"power.json").write_text(json.dumps(self.power))
        return verify(self.root, self.root/"work.jsonl", self.root/"power.json", duration)

    def test_positive_fixture_is_narrow(self):
        result = self.check()
        self.assertTrue(result["disposableWorkloadContinuityVerified"])
        self.assertIn("native Codex and unattended use unverified", result["scope"])

    def test_open_lid_run_rejected(self):
        for row in self.journal:
            if "sample" in row: row["sample"]["inspection"]["snapshot"]["lidClosed"] = False
        with self.assertRaisesRegex(ValueError, "sampled lid closure"): self.check()

    def test_reopening_required(self):
        for row in self.journal:
            if "sample" in row and row["sample"]["time"] > 112.5:
                row["sample"]["inspection"]["snapshot"].update(lidClosed=True, clamshellCausesSleep=False)
        with self.assertRaisesRegex(ValueError, "Reopening"): self.check()

    def test_sleep_event_rejected(self):
        self.power["records"].append(dict(wall=1008, kind="Sleep"))
        with self.assertRaisesRegex(ValueError, "recorded sleep"): self.check()

    def test_workload_gap_rejected(self):
        for row in self.work[50:]: row["continuous"] += 5
        with self.assertRaisesRegex(ValueError, "continuity gap"): self.check()

    def test_corrupt_output_rejected(self):
        self.work[50]["digest"] = "invalid"
        with self.assertRaisesRegex(ValueError, "output chain"): self.check()

    def test_monitor_gap_rejected(self):
        self.journal = [row for i, row in enumerate(self.journal) if not 20 <= i <= 25]
        with self.assertRaisesRegex(ValueError, "monitor gap"): self.check()

    def test_failed_clear_rejected(self):
        self.journal[-1]["backend"] = dict(self.backend, callResult=-1)
        with self.assertRaisesRegex(ValueError, "not accepted"): self.check()

    def test_early_termination_rejected(self):
        self.journal[-2]["note"] = "Stop: userStopped; failures: ; full interval: false."
        with self.assertRaisesRegex(ValueError, "qualification interval"): self.check()

    def test_inadequate_history_rejected(self):
        self.power["records"] = []
        with self.assertRaisesRegex(ValueError, "does not cover"): self.check()

    def test_charger_discharge_rejected(self):
        self.journal[30]["sample"]["power"]["discharging"] = True
        with self.assertRaisesRegex(ValueError, "qualified range"): self.check()

    def test_other_controller_rejected(self):
        (self.root/"owner-conflict").touch()
        with self.assertRaisesRegex(ValueError, "ownership conflict"): self.check()

    def test_missing_final_observation_rejected(self):
        self.work[-1].pop("completed")
        with self.assertRaisesRegex(ValueError, "final workload observation"): self.check()

    def test_sleep_after_last_regular_sample_rejected(self):
        self.work[-1]["continuous"] += 173
        self.work[-1]["wall"] += 173
        with self.assertRaisesRegex(ValueError, "continuity gap"): self.check()

    def test_sixty_second_fixture_requires_sixty_second_coverage(self):
        with self.assertRaisesRegex(ValueError, "bounded qualification interval"):
            self.check(duration=60)
        tail = self.journal[-2:]
        sample = copy.deepcopy(self.journal[-3]["sample"])
        self.journal = self.journal[:-2]
        for n in range(121, 241):
            extra = copy.deepcopy(sample); extra["time"] = 100+n*.25
            self.journal.append(dict(event="heartbeat", sample=extra))
        self.journal += tail
        self.journal[-1]["time"] = 161
        self.parent[-1]["sample"]["time"] = 162
        self.work = []; chain = bytes(32)
        for index in range(401):
            chain = hashlib.sha256(chain+index.to_bytes(8, "big")).digest()
            self.work.append(dict(index=index, continuous=99+index*.2, wall=1000+index*.2, digest=chain.hex()))
        self.work[-1].update(completed=True, requestedSeconds=80, startedContinuous=99)
        self.power["capturedAt"] = 1100
        self.assertEqual(self.check(duration=60)["probeDuration"], 60)


if __name__ == "__main__":
    unittest.main()
