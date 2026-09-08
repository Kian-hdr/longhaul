# Release status: v1.0.0

Updated 2026-09-08. The reviewed source is public and GitHub CI passed. A signed
v1.0.0 candidate exists, but the downloadable binary is **not yet release-ready**.
This is the current checklist; older private development logs are not release evidence.

| Gate | State | Required evidence |
| --- | --- | --- |
| Source and icon license | Passed inventory | GPL-3.0-only; original icon generator and component inventory in LICENSE-STATUS.md. |
| Public documentation/privacy cleanup | Passed | 122 staged files reviewed; private history excluded; all local Markdown links resolve. Anonymous public source download byte-matches the reviewed commit. |
| Identified candidate commit and matching version | Passed | Candidate source `a45fca770096e947657ea5d816b17a47a91276a5`; embedded source identity; version 1.0.0, build 1, arm64. Release remains a draft without binary assets. |
| Refactor and regression validation | Passed | Clean local suite and native Release build; [GitHub CI](https://github.com/Kian-hdr/longhaul/actions/runs/34250069012) passed the full suite, native build and source checks from the identified commit. |
| Native slider repair | Passed local UI check | Tick-mark line removed; final release app must retain it. |
| Candidate Developer ID signature and nested contents | Passed | Strict nested signatures, hardened runtime, secure timestamps, version/source/arm64, matching license/icon and cache/privacy checks. Final notarized archive checks still remain. |
| Notarization | Blocked | A working notary credential/profile is required; no acceptance claimed. |
| Stapling and Gatekeeper | Blocked | Candidate assessment explicitly rejects Unnotarized Developer ID. Accepted notarization and a stapled ticket are still required. |
| Final installation and launch | Blocked | The test Mac is locked; controlled pause/update and final native UI checks require manual unlock. The installed development build retains the verified slider repair. |
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
records. Existing protected lifecycle guards are preserved; unlock before an
update, since already locked records may remain unreadable until then. This does
not alter global macOS security controls. Fresh physical
closed-lid qualification of this change is still separate.

## Current code validation

The identified candidate passed 162 Swift tests, hook lifecycle/public installer
fixtures, 105 integration checks, 19 runtime recovery checks plus FIFO, 15 finite
and 51 sustained helper-process scenarios, 14 app-service scenarios, 12 native
coordinator scenarios, and 101 evidence-verifier tests. The full clean suite and
native build also passed on GitHub's macOS 26 runner. These process tests use
isolated fixtures and do not perform native power mutations.

An initial local harness run found duplicate stale object files in an old build
cache. The full-suite entrypoint now uses fresh private SwiftPM scratch storage;
the clean rerun passed. Build guards were independently checked against a live
app destination, a disposable surviving helper and an unused destination.

## Earlier installed and physical validation

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
