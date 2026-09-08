# Install and configure Longhaul on my Mac

Install Longhaul from its official release and configure it to turn sleep
protection on for my supported active agent tasks and off when they finish.
Complete the setup autonomously within my existing access, preserving current
work, preferences and unrelated integrations. Do not bypass OS or agent-host
security controls. Report any actual authentication or compatibility blocker.

## Get the verified app

1. Read the current README, installation guide, privacy policy and release status
   at `https://github.com/Kian-hdr/longhaul`. Verify this is an Apple silicon Mac
   running macOS 26 or later. Preserve any existing installed app before replacing
   it. If it protects work, keep the lid open, pause it, confirm owned-session
   cleanup and quit before replacement; do not kill helpers or restart my tasks.
2. Inspect `https://github.com/Kian-hdr/longhaul/releases/tag/v1.0.0`. Download
   `Longhaul-1.0.0-arm64.zip` and `SHA256SUMS` from that same official release into
   a fresh local directory. Verify that these exact assets actually exist. A
   source-only release or pending notarization is not a usable signed installer;
   report the missing binary rather than inventing a URL or substituting an
   unsigned build. Do not use an unofficial mirror or a curl-to-shell installer.
3. Check `shasum -a 256 -c SHA256SUMS` in the download directory. Extract only after
   the ZIP matches. Verify the extracted app with `codesign --verify --deep
   --strict --verbose=2 Longhaul.app`, `spctl --assess --type execute --verbose=2
   Longhaul.app`, and `codesign -dv --verbose=4 Longhaul.app`. The expected bundle
   ID is `space.exlumina.longhaul`, the version is `1.0.0`, and the official signer
   is `Developer ID Application: Kian Konrad Tajbakhsh (HZWY8HT54D)`. Gatekeeper
   must accept it. A hash is not a substitute for these signature checks.
4. Install the verified app at `/Applications/Longhaul.app` and launch it. Confirm
   the running app's version and native window. Preserve quarantine metadata;
   never remove it to bypass rejection, disable Gatekeeper, change SIP or unlock
   my desktop. Preserve the previous app as a rollback copy.

## Configure real task reporting

5. Use the installed helper at
   `/Applications/Longhaul.app/Contents/Resources/bin/longhaul` for all setup calls.
   Inspect `--help`. Keep Automatic protection and native Codex monitoring enabled
   unless I have explicitly paused or disabled them. Confirm current settings
   through the app; do not infer a power hold from a saved preference.
6. Discover actual local Codex profiles with `longhaul profiles`, invoking the
   full bundled path if the optional command link is not installed. This command
   finds suitable `.codex*` directories under the current home with `config.toml`.
   Inspect the actual current `CODEX_HOME` configuration if a custom profile is
   used; do not assume discovery is exhaustive or create a fake profile. Keep
   credentials, account state, transcripts and runtime stores separate. Do not
   copy authentication or merge profiles.
7. For each intended existing profile, substitute its actual absolute path in
   these commands and inspect their JSON results:

   ```sh
   /Applications/Longhaul.app/Contents/Resources/bin/longhaul hooks status --profile ABSOLUTE_PROFILE_PATH
   /Applications/Longhaul.app/Contents/Resources/bin/longhaul hooks install --profile ABSOLUTE_PROFILE_PATH
   /Applications/Longhaul.app/Contents/Resources/bin/longhaul hooks status --profile ABSOLUTE_PROFILE_PATH
   ```

   Use this installer rather than hand-writing `hooks.json`. It backs up and
   preserves unrelated definitions and refuses ambiguous modified groups. Do not
   use `--root` for ordinary setup: installed hooks must target the same mailbox
   as the app. Report a refusal without overwriting unfamiliar configuration.
8. Review and trust the exact nine generated definitions through Codex's supported
   `/hooks` or host settings flow. Use an available documented host configuration
   interface only for the exact reviewed definitions. Never edit internal trust
   databases, forge hashes or broadly trust unrelated hooks. The helper reports
   `trustVerified: false` because filesystem inspection cannot establish host
   trust. File installation, trust, runtime delivery and active protection are
   separate checks. If a mandatory host interaction is unavailable, describe the
   exact remaining step and continue independent checks.
9. Native lifecycle monitoring is on by default for qualified Codex Desktop
   format 0.153.4 and can detect already-running tasks without restarting them.
   Inspect each profile's reporting and Activity for fresh protected work. An
   unsupported version or unverifiable writer remains a coverage gap. Do not
   restart active Codex tasks merely to reload hook settings; defer any necessary
   host restart until work is complete. Large existing logs can need bounded
   catch-up time before activity is established.
10. For other CLI agents, use `longhaul run -- COMMAND ARGS` around the real
    foreground task. Do not claim automatic detection of arbitrary AI software,
    a detached process, or useful work from an idle interactive shell. Install
    the optional `~/.local/bin/longhaul` link through Integrations if useful;
    preserve an existing unrelated command. The full bundled path works without
    editing shell configuration. Read `docs/agent-task.md` for task completion
    and real checkpoint acknowledgement semantics.

## Verify and finish

11. Keep the lid open and run a short disposable supervised task. Confirm a fresh
    Activity row and actual Longhaul protection, optionally corroborating its
    assertion with `pmset -g assertions`. Let the task finish, then observe release
    after the completion grace, normally two minutes, if no other eligible work
    or manual session remains. `longhaul status` is mailbox evidence only. Also
    verify a real task from the intended Codex profile when feasible. Do not
    fabricate success from setup files or simulated events.
12. Preserve my existing battery threshold and feature choices. New installations
    default Battery auto-release to 20%, adjustable from 1% to 100% or Off.
    Closed-lid mode is initially off and experimental. Enabling it needs an open
    lid and active reporting. One attended AC test is recorded; physical battery
    and overnight operation are not qualified. Off removes numeric withdrawal,
    not OS warnings, thermal checks, known-sensor requirements, manual sleep or
    lease expiry. Do not change global SleepDisabled, trigger physical sleep,
    drain the battery or claim locked-desktop Computer Use works.
13. Configure optional Blender, Resolve, Nodebay, login launch or notifications
    only where relevant to my requested work. Preserve existing add-ons and
    settings. Longhaul works independently of Nodebay. Unavailable integrations
    must stay labeled unavailable. Do not uninstall another keep-awake utility
    as an incidental setup step.
14. Report the installed version, verified signature/checksum, discovered profiles,
    hook installation and trust state, actual task detection, assertion behavior,
    preserved settings and remaining gaps. Keep private paths and logs local.
    Do not call setup complete while a required detection or installation step is
    still unresolved.
