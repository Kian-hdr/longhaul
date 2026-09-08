# Release status: v1.0.0

Updated 2026-09-08. Public-source preparation is in progress. A signed local
candidate exists, but the v1.0.0 downloadable binary is **not yet release-ready**.
This is the current checklist; older private development logs are not release evidence.

| Gate | State | Required evidence |
| --- | --- | --- |
| Source and icon license | Passed inventory | GPL-3.0-only; original icon generator and component inventory in LICENSE-STATUS.md. |
| Public documentation/privacy cleanup | Prepared | Final staged-file and link review before push. |
| Identified release commit and matching version | Pending | Release owner records final source and bundle identity. |
| Refactor and regression validation | Pending | Final integrated suites and build from release source. |
| Native slider repair | Passed local UI check | Tick-mark line removed; final release app must retain it. |
| Final Developer ID signature and nested contents | Pending | Validate exact release app, hardened runtime and timestamp. |
| Notarization | Blocked | A working notary credential/profile is required; no acceptance claimed. |
| Stapling and Gatekeeper | Pending | Accepted ticket and assessment of final distributable. |
| Clean installation and launch | Pending | Verify real installation path for the final downloaded/extracted artifact. |
| Published bytes and checksums | Pending | Download hosted ZIP and compare SHA-256 to the release manifest. |
| GitHub private vulnerability reporting | Passed | Repository reporting enabled and verified through GitHub API. |

The intended release assets are `Longhaul-1.0.0-arm64.zip` and `SHA256SUMS` with
source at the matching `v1.0.0` tag. Homebrew and Mac App Store distribution are not
part of this release. Do not publish an unsigned or unnotarized replacement asset
under the official binary name.

## Refactor changes

Settings are split into focused sections, preserving bindings and the slider
without tick marks. App and CLI now share one checked Codex hook installer;
`profiles` and `hooks status|install|remove` support AI-assisted setup without
hand-editing hooks or claiming host trust.

A release audit reproduced a lock-sensitive mailbox defect: with the screen
locked, newly written records using the unless-open file-protection option
could not be reopened, even by the writer. Atomic metadata files with private
permissions remained readable. The app now uses that policy for its runtime
records. This does not alter global macOS security controls. Fresh physical
closed-lid qualification of this change is still separate.

## Existing bounded validation

The preceding local candidate passed 162 Swift tests, 51 simulated helper-process
scenarios, 14 app-service scenarios and 86 sustained-evidence verifier tests.
Signed local build, installed signature and artifact comparisons passed. These
results precede the final release refactor and must not be presented as its tests.

Native checks covered automatic Codex detection, supervised command completion,
actual idle assertion acquisition/release, settings persistence and the battery
cutoff controls. A real small Blender render and saved-scene reopen passed during
development. The updated slider was checked in the installed app without the
unwanted tick-mark row. These are local results on macOS 26.6.2 / Apple silicon,
not a clean-account or multi-OS matrix.

One attended AC session passed with 113.34 seconds of observed lid closure,
97.92 seconds of closed-lid work inside a completed 120-second disposable workload,
and reopening before accepted cleanup. Two native Codex task logs advanced during
closure. See [qualification](lid-qualification-probe.md) for interpretation.

## Supported scope and open coverage

Ordinary task-driven idle protection is the main supported behavior. Native Codex
monitoring is qualified for format 0.153.4; hooks require exact host trust. Other
agent commands need the command wrapper or a specific adapter.

Closed-lid mode is explicitly experimental. Physical battery operation, overnight
operation, simultaneous helper death, real emergency depletion/thermal behavior,
and locked desktop automation remain unqualified. Shared runtime state has no
kernel-owned lease. These limitations must remain in the app and release notes.

Real Resolve export/recovery, comprehensive VoiceOver/keyboard/contrast testing,
actual login launch and macOS versions beyond the tested system remain open
coverage. Passing tests, signing or notarization does not establish these behaviors.
