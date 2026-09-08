# Agent coordination scope

Longhaul includes an optional cooperative reservation prototype. It is separate
from task detection and power protection. The implementation and adapter contract
are documented in [coordination-prototype.md](coordination-prototype.md).

A participating executor can reserve declared app, browser, foreground or
clipboard resources, validate its permit immediately before each short action,
and yield to explicit human priority. The state machine does not intercept native
Codex Computer Use, inspect arbitrary JavaScript to infer its targets, or stop an
agent that bypasses the cooperative contract.

A production adapter would need authenticated participant identity, actual
execution ownership, bounded messages, fresh observations after waiting, and
reconciliation of unknown in-flight actions before conflicting work resumes.
Hook coverage of an outer tool call would not by itself prove per-action
cancellation or control of every native path. Missing or untrusted hooks must
remain an explicit coverage gap.

Mission Control Spaces organize windows; they do not create separate process or
input sessions. Dedicated remote workers or guest operating systems are different
architectures and need their own compatibility, resource and lifecycle testing.
No virtual-machine, native hook-enforcement or automatic human-input claim is
part of Longhaul v1.0.0. Reservation tickets alone do not create a power hold.

The ordinary agent setup and task workflow is in [agent-task.md](agent-task.md).
It uses supported lifecycle reports or foreground command supervision and does
not depend on the coordination prototype.
