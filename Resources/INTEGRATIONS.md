# Longhaul integrations

Automatic protection follows fresh task reports. An open application or a hook
file alone does not establish activity. The app must remain running and Automatic
protection must be on. Check Activity for a fresh job and actual protection.

## Codex

Native monitoring is enabled by default for the qualified Codex Desktop 0.153.4
format. It verifies native process ancestry, process incarnation and writable log
identity, then extracts lifecycle fields while discarding conversation data. It
can detect an already-running task without restarting Codex. Unsupported formats,
inaccessible processes and unverifiable writers remain visible coverage limits.

Use `longhaul profiles` to discover suitable local profiles. The bundled CLI also
provides `hooks status|install|remove --profile ABSOLUTE_PROFILE_PATH`; all paths
must refer to actual profiles. The installer and native UI share one checked
implementation. Its JSON reports `trustVerified: false`, not a host trust result.

In Integrations, install Longhaul's nine lifecycle hooks separately for each
intended profile. Existing unrelated hooks are preserved with a backup. Trust the
exact installed definitions through Codex's supported `/hooks` or host settings
flow. Do not edit internal trust databases. A changed definition requires fresh
host trust. Existing sessions may need to reload hooks; do not restart active work
just to complete setup. Verify reporting with a real task after setup.

Hooks report UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Stop,
Interrupt, SubagentStart, SubagentStop and SessionEnd. A Stop can be provisional
when Codex continues the turn. Confirmed native terminal evidence supersedes a
stale hook claim. Hook liveness has a finite fallback when terminal delivery is
missed; a living Codex process is not new evidence of useful work. Native monitoring
and hooks complement each other, and neither covers arbitrary agent software.

## Other command-line agents and jobs

Install the command tool in Integrations, then launch the actual foreground work:

```sh
longhaul run -- COMMAND ARGS
```

It supervises the command, reports running/terminal state and returns its exit
status. Detached children need explicit lifecycle reporting. Merely opening an
agent's interactive shell does not prove that a task is actively progressing;
prefer its bounded task command. `longhaul status` lists mailbox reports, not
independent proof of an OS power hold.

## Creative applications and companion

- Blender: install the included `longhaul_blender` add-on for the intended version,
  after saving and closing Blender. Verify an actual small render. Checkpoints are
  scene copies; single-frame render resumption is not promised.
- Resolve: enable the optional local scripting bridge only where its connection
  succeeds. Unavailable means unavailable; real export/recovery is not qualified.
- Nodebay: optional signed local companion for controls and supported worker jobs.
  It is not required for Longhaul to work.

Ordinary protection prevents idle sleep. Optional closed-lid protection is
experimental, subject to the chosen battery cutoff, native conditions and fresh
leases. It does not unlock the desktop. See the repository's installation,
privacy and closed-lid qualification documentation before relying on it.
