# Integration status and removal

Longhaul integrations are optional. Removing an integration stops its future
reporting; it does not erase job outputs, saved scenes, checkpoints, recovery
copies or the app. Stop or finish affected work before disconnecting its reporting
if that work still depends on Longhaul for sleep protection.

## Codex hooks

`CodexHookInstaller.removeHooks(profile:)`, exposed through the app and
`longhaul hooks remove --profile ABSOLUTE_PROFILE_PATH`, removes only exact groups generated for
this app's bundled CLI, current profile name and Longhaul mailbox. Ownership is
the complete event, group and handler definition: command, type, timeout, status
message, context limit and absence of extra fields. A matching status message
alone is insufficient.

The nine recognized events are UserPromptSubmit, PreToolUse, PostToolUse,
PermissionRequest, Stop, Interrupt, SubagentStart, SubagentStop and SessionEnd.
Combined handlers, matcher-bearing groups, changed commands or paths, altered
timeouts, extra fields and unknown events are left for manual review. Exact
duplicates can all be removed. Reinstallation refuses ambiguous marked entries
instead of adding another handler alongside them.

Before a change, the original `hooks.json` bytes are saved to the configured
Longhaul mailbox's `recovery/hooks-<UUID>.backup`, with mode 0600. Newly created
recovery directories use mode 0700. Other JSON values are preserved, although
successful changes reformat JSON. No matches means the configuration remains
byte-for-byte unchanged. An empty `hooks` dictionary is retained; the entire
configuration file is never deleted.

Review the resulting definitions in Codex `/hooks`. For recovery, compare the
backup with the current file and restore only the desired entries. Do not replace
the whole current configuration with an older backup if other integrations or
settings have since changed.

Hook status distinguishes:

- **Not installed:** no exact or marked Longhaul definition was found.
- **Installed / Needs trust:** exactly one complete definition exists for every
  recognized event. This does not establish that Codex has trusted or run it.
- **Needs attention:** partial, duplicated, modified or combined definitions need
  review. Unsafe or malformed input throws an explanatory error for the UI.

Trust is not inferred from file presence or from undocumented Codex trust stores.
The status API makes no claim about active Codex tasks or runtime hook delivery.

## Command link

`removeCommandTool()` removes `~/.local/bin/longhaul` only when it is a symbolic
link whose stored destination exactly equals this app's bundled CLI path.
Regular files, relative links and links to another installation remain unchanged.
An owned dangling link can be removed. The app and bundled executable are never
removed by this operation; shell PATH configuration is never edited.

A recoverable symbolic-link copy is created at
`recovery/command-link-<UUID>.backup` before removal. To restore it, use Longhaul's
command-tool setup again after checking that the destination is free. Do not
overwrite a newer command that now occupies the path.

Status reports the presence and destination of the link. It does not execute the
CLI, check shell PATH, or prove that a moved or missing app can run.

## Blender

Blender removal is deliberately manual. In Blender's Add-ons preferences, disable
Longhaul and use the available removal control for that add-on. If files need
manual cleanup, quit Blender, preserve a copy and remove only the managed
`longhaul_blender` folder for the intended Blender version. Do not restore an old
whole `userpref.blend` over unrelated newer preferences. Keep useful saved scene
copies and other recovery files.

`managedBlenderAddons()` inspects standard user add-on locations beneath
`~/Library/Application Support/Blender/<version>/scripts/addons/longhaul_blender`.
A managed folder has the exact `LONGHAUL-INTEGRATION` version-1 marker and nonempty
regular `__init__.py` and `longhaul_common.py` files. Modified Python payloads are
not authenticated by this marker. The API reports an incomplete or unrecognized
folder as needing attention and refuses unsafe filesystem entries.

This is file discovery only. It does not read or change Blender preferences, start
Blender, establish that the add-on is enabled, or find custom script directories
such as a separately configured `BLENDER_USER_SCRIPTS`. `blenderStatus()` summarizes
these records for the settings UI. There is no scripted Blender uninstall API.

## Filesystem and concurrency boundaries

Hook configuration is limited to 1 MiB and validated as an object with bounded
event, group and handler collections. Setup refuses symlink components, unexpected
file types, hard-linked configuration files, foreign ownership and group/world
writable integration locations. It does not follow a symlink to reach a profile,
configuration or recovery directory.

Every Longhaul configuration writer holds a nonblocking advisory lock in the
target directory. The original file's bytes, device, inode, owner, link count,
mode, length and nanosecond modification/change times are checked before the
atomic replacement. Directory identity is checked too. A changed input causes a
refusal and leaves the newly observed configuration alone. Command removal uses
the corresponding identity and destination checks before unlinking its own link.

These checks protect cooperative setup and detect changes observed before commit.
An unrelated same-user process that ignores the advisory lock can still race the
final check and rename/unlink; this is not a filesystem compare-and-swap or a
security boundary against malicious same-user writers. Close competing settings
editors and retry if Longhaul reports a concurrent change. A private, persistent
`.longhaul-setup.lock` file may remain after setup; it carries no hook definitions.

## App API and validation

The shared `CodexHookInstaller` exposes profile discovery and hook setup/status/removal.
`IntegrationSetup` remains the app actor facade and also handles the command link
and Blender. The facade exposes `hookStatus(profile:cli:mailbox:)`,
`removeHooks(profile:cli:mailbox:)`, `commandToolStatus(cli:)`,
`removeCommandTool(cli:)`, `blenderStatus()` and `managedBlenderAddons()`.
Default CLI/mailbox arguments match the normal installed app. Callers using a
custom data directory must pass the same mailbox used at installation. The
explicit `removeHooks(profile:)` convenience method uses those normal defaults.

Statuses have `state`, `detail` and `managedCount`; Blender records additionally
have `version` and `url`. Calls are actor-isolated and throwing. The UI should
refresh status after an explicit setup or removal action and display refusal
messages without automatically retrying mutations.

Run the independent fixture harness with:

```sh
bash script/test_integration_setup.sh
```

It compiles these app service sources directly with Swift 6, avoiding the app and
SwiftPM build directories. It exercises exact hook ownership, unrelated-value
preservation, private backups, no-op removal, shell quoting, malformed input,
symlinks, hard links, FIFOs, permissions, oversized files, edit/replacement races,
advisory locking, foreign command preservation and Blender file discovery.
All mutations occur under a fresh private temporary directory. The harness never
runs a hook, the bundled CLI, Blender, Codex or Longhaul, and never mutates a real
user profile. Passing it establishes fixture behavior, not native UI acceptance,
Codex trust or Blender runtime behavior.
