# Release status: v1.0.0

Updated 2026-09-23. Longhaul v1.0.0 is published as a signed and notarized
DMG and ZIP with a verified Homebrew cask. This checklist distinguishes the
completed release checks from the physical scenarios that remain unqualified.

| Gate | State | Required evidence |
| --- | --- | --- |
| Source and icon license | Passed inventory | GPL-3.0-only; original icon generator and component inventory in LICENSE-STATUS.md. |
| Public documentation/privacy cleanup | Passed | 122 staged files reviewed; private history excluded; all local Markdown links resolve. Anonymous public source download byte-matches the reviewed commit. |
| Identified candidate commit and matching version | Passed | Release tag `v1.0.0` and embedded source identity both resolve to `a45fca770096e947657ea5d816b17a47a91276a5`; version 1.0.0, build 1, arm64. |
| Refactor and regression validation | Passed | Clean local suite and native Release build; [GitHub CI](https://github.com/Kian-hdr/longhaul/actions/runs/34250069012) passed the full suite, native build and source checks from the identified commit. |
| Native slider repair | Passed local UI check | Tick-mark line removed; final release app must retain it. |
| Candidate Developer ID signature and nested contents | Passed | Strict nested signatures, hardened runtime, secure timestamps, version/source/arm64, matching license/icon and cache/privacy checks. |
| Notarization | Passed | Apple accepted the app ZIP (`5a51806c-72f9-4dca-b76a-599b124fc70b`) and final signed DMG (`9bca3de3-96ff-4dd5-95cb-d41f17a2b1e3`). |
| Stapling and Gatekeeper | Passed | The app and DMG have validated tickets; strict signature, Gatekeeper, mounted-app and disk-image integrity checks passed. |
| Final installation and launch | Passed on this Mac | Controlled direct installation and Homebrew installation each launched version 1.0.0; the native Activity view resumed protection for active jobs and `pmset` showed Longhaul's sleep assertion. The installed main binary matched the DMG. |
| Published bytes and checksums | Passed | Draft downloads and anonymous public DMG download matched `SHA256SUMS`; DMG SHA-256 `9816ecb8942b0ec28a22e83cfcdee6f55d38a55cfd10bed448bc80f0d4a109a2`, ZIP `528973d46770151046d9e0c648f14a59ecb7d839d11d0d9b626459246aaead77`. |
| Homebrew Cask | Passed for audit and install | `kian-hdr/apps/longhaul` passed style and strict online audit, installed the public DMG, launched, and resumed protection. Uninstall was not exercised during active protected work. |
| GitHub private vulnerability reporting | Passed | Repository reporting enabled and verified through GitHub API. |

The [published release](https://github.com/Kian-hdr/longhaul/releases/tag/v1.0.0)
contains `Longhaul-1.0.0-arm64.dmg`, `Longhaul-1.0.0-arm64.zip`, `SHA256SUMS`,
and matching source. The Homebrew cask is in
[`Kian-hdr/homebrew-tap`](https://github.com/Kian-hdr/homebrew-apps/blob/main/Casks/longhaul.rb).
Mac App Store distribution is not part of this release.

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
