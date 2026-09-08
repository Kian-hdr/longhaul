# Closed-lid qualification

Closed-lid protection is **experimental**. Ordinary idle protection has a separate
assertion and does not, by itself, establish lid-close behavior.

## Observed physical result

On 2026-09-08, one attended app-driven session on macOS 26.6.2 / Apple silicon
passed its bounded AC-power test:

- 113.34 seconds of continuously observed lid closure.
- 97.92 seconds of observed closed-lid work inside a completed 120-second hash workload.
- One 222.41-second hold, renewed by 108 original app grants.
- Reopening before one accepted cleanup, with no sleep in the covered OS history.
- Two native Codex task logs advanced during the closure.

This establishes progress during that capture, not uninterrupted execution of
every task. The detailed capture remains private because it contains local
runtime identities. The repository includes the verifiers and simulated fixtures
needed to assess future captures. Earlier failed runs were retained as failures;
a successful later run does not change their result.

## Current session policy

Enable closed-lid protection with the lid open. A session needs fresh supported
work, verified process identities, known battery sensors, nominal temperature and
no macOS battery warning. Production code permits battery or connected power.
Battery auto-release is adjustable from 1% to 100%, defaults to 20%, and can be
disabled while retaining the selected value. Protection continues at the cutoff
and withdraws below it. Off removes numeric percentage/estimated-runtime withdrawal
only. It does not override manual sleep or OS emergency handling.

Original version-2 grants carry the selected policy. Both helpers validate and
enforce the latest accepted grant; malformed policy fails closed. Grants last at
most ten seconds and helpers cannot renew themselves. Durable cleanup records
block re-admission when ownership or release is unresolved. Changing a cutoff
cannot clear an existing OS-emergency latch.

The mechanism is shared runtime state with no kernel-owned lease or exclusive
ownership. Simultaneous helper death, blocked native calls or other writers can
defeat software cleanup deadlines. The app does not repeatedly reassert against
system policy. See [mechanism details](closed-lid-alternatives.md).

## Reproducible qualification

Use a disposable workload, a ventilated desk, an available operator and a fresh
session. Capture native lid/power observations, original grants, task output,
cleanup receipts and OS power history. Keep private captures outside tracked source.
The operator must reopen before the planned protection window ends.

`script/verify_lid_session.py` checks sustained sessions. Its `--completed-job`
mode permits a test job to finish while other jobs still share the hold, but
requires at least 60 seconds of witnessed closed-lid work, a completed hash chain,
fresh native observations, grant coverage, reopening before cleanup and power
history through the final observation. Default mode additionally requires work
through cleanup. `--battery` requires a witnessed same-session transition and
closed-lid battery work; it cannot qualify an earlier AC-only capture.

`script/verify_lid_continuity.py` assesses the separate finite 30/60-second
qualification probe. That probe keeps its own AC/30% admission contract and does
not define the production app's configurable policy. Inspect script help before
collecting evidence. Do not invoke raw helper/probe commands as an installation step.

## Remaining limits

Physical battery operation, unplugging during closure, unattended overnight use,
all-task continuity, simultaneous helper death and real depletion/thermal behavior
have not been qualified. Locked desktop automation depends on the agent host and
is not provided by Longhaul. OS updates need requalification. A passed build,
simulation, signature or notarization cannot close these physical evidence gaps.
