# Verification guide

The current release verdict belongs in [STATUS.md](STATUS.md). This document
identifies what each layer can establish and how to reproduce checks. Test inputs
must stay disposable; simulated power scenarios must not change real sleep policy.

## Deterministic and integration checks

```sh
swift test
swift build --product longhaul
python3 script/test_hooks.py .build/debug/longhaul
bash script/test_integration_setup.sh
bash script/test_runtime_io.sh
python3 script/test_lid_probe_runner.py
python3 script/test_lid_session_runner.py
python3 script/test_lid_session_verifier.py
python3 script/check_source.py
```

App-service fixtures may require the Swift build output directory; inspect their
usage before running. Build with `./script/build_and_run.sh --build-only` while an
installed app is protecting work. Never kill production helpers to exercise a
failure fixture. Fixture builds inject fake sensors and writes at compile time;
there is no production environment switch that simulates power safety.

| Layer | What passing checks establish | Separate acceptance |
| --- | --- | --- |
| Policy/mailbox | Identity, terminal guards, finite leases, battery thresholds and persisted checkpoint reconciliation under supplied inputs. | Real sensors, I/O delays, process lifecycle and OS assertions. |
| Hook/setup fixtures | Payload filtering, generated definitions, backups, exact ownership, unrelated-hook preservation and rejection paths. | Codex's exact trust, configuration reload and actual task delivery. |
| Helper-process fixtures | Tested death/stall/expiry/policy interleavings with fake native writes. | Physical lid behavior and native-call failure modes. |
| Evidence verifiers | Captures missing required timing, grants, workload or cleanup are rejected. | Truth and completeness of a new physical capture. |
| Signed build | Consistent bundle contents and verified signature. | Notarization, Gatekeeper, downloaded install and launch. |

## Native acceptance

On the supported system, run a disposable supervised command and observe the
actual Longhaul assertion. Verify pause, resume, overlapping work, natural task
completion and grace-period release. Check the real intended agent integration;
an installed hook file or native process alone is insufficient.

Use the running app to inspect Activity, History, Recovery, General, Integrations
and About, including the original icon and license. Verify the actual menu-bar
item, keyboard routes, persisted settings and optional companion fallback.
Changing controls must not stop independent worker reporting.

Checkpoint tests must match request/job/session identity. Confirm saved files
exist and reopen in the source application before claiming restore. Late valid
saves can remain useful even when a request expired; an acknowledgement is not
proof of exact computation resumption.

Physical lid/battery and unattended tests are distinct from this matrix. Follow
[lid-qualification-probe.md](lid-qualification-probe.md) with an attended disposable
workload. Do not induce real thermal emergencies or battery depletion to make a
release claim. Record uncovered conditions instead.
