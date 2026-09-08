# Installation, setup and removal

## Install an official binary

Requires macOS 26+ on Apple silicon. Open the
[official release page](https://github.com/Kian-hdr/longhaul/releases) and download
`Longhaul-1.0.0-arm64.zip` and `SHA256SUMS` from the same v1.0.0 release.
The binary is not available until the release gates in [STATUS.md](STATUS.md) pass.
Do not disable Gatekeeper to substitute a development build.

In the directory containing both downloads, verify the bytes before extraction:

```sh
shasum -a 256 -c SHA256SUMS
```

Only continue if the ZIP matches. Extract the ZIP and verify the extracted app:

```sh
codesign --verify --deep --strict --verbose=2 Longhaul.app
spctl --assess --type execute --verbose=2 Longhaul.app
codesign -dv --verbose=4 Longhaul.app
```

The expected bundle identifier is `space.exlumina.longhaul`; the official signer is
`Developer ID Application: Kian Konrad Tajbakhsh (HZWY8HT54D)`. Gatekeeper must
accept the app. A checksum checks consistency with the published file; it does not
replace signature and Gatekeeper checks. Retain quarantine metadata. Do not use
`xattr` to bypass an assessment failure.

Drag the verified app into Applications, then open it. For an update, keep the lid
open, pause protection, wait for owned lid-session cleanup, quit Longhaul and
preserve a copy of the previous app before replacement. Do not kill the helpers
or replace a running app that protects work. Resume protection after verifying the
new installed version and reporting status. Preserve existing preferences.

## Connect work

Automatic protection and qualified native Codex monitoring are enabled by default.
Use Integrations to inspect discovered profiles and actual reporting. Install the
Longhaul hooks for each intended Codex profile, preserving unrelated definitions.
Review and trust the exact definitions through Codex's supported `/hooks` or host
settings flow. File presence alone does not prove trust or delivery. Never merge
profiles, copy authentication or edit private trust stores. Let active tasks finish
before a host restart if configuration reload is needed; native monitoring may
already cover qualified running tasks.

The installed command helper also exposes the same checked hook installer for
AI-assisted setup:

```sh
/Applications/Longhaul.app/Contents/Resources/bin/longhaul profiles
/Applications/Longhaul.app/Contents/Resources/bin/longhaul hooks status --profile ABSOLUTE_PROFILE_PATH
/Applications/Longhaul.app/Contents/Resources/bin/longhaul hooks install --profile ABSOLUTE_PROFILE_PATH
```

Replace the placeholder with a discovered actual profile. `profiles` finds safe
`.codex*` directories with `config.toml` under the current home; custom profile
locations may require an explicit verified path. `hooks remove --profile PATH`
removes only exact managed groups. JSON `trustVerified: false` is deliberate:
installation cannot inspect or grant host trust. Do not use a different `--root`
mailbox unless the app is deliberately configured to use that same mailbox.

Install the optional command tool from Integrations. It creates
`~/.local/bin/longhaul`, pointing into the installed app. Add that directory to your
shell's PATH if needed, or invoke the bundled tool directly:

```sh
/Applications/Longhaul.app/Contents/Resources/bin/longhaul run -- python3 my_job.py
```

The app must be running with protection enabled. The wrapper reports the process
it starts; work that detaches from it needs an explicit lifecycle adapter.

Blender setup preserves the managed add-on and preferences before enabling it.
Save work and close Blender before setup; verify a small render after reopening.
Resolve monitoring is opt-in and depends on an actual local scripting connection.
Nodebay is optional; an unavailable companion leaves menu-bar access available.

Login launch, notifications and closed-lid mode are separate settings. Existing
choices are preserved during updates. Native notification permission and Focus
remain controlled by macOS. If a menu-bar item is hidden, inspect the system's
menu-bar settings rather than resetting global preferences.

## Verify automatic on and off

Start a disposable task using the intended integration. Confirm that Activity
shows fresh work and active protection. Finish the task and observe release after
the completion grace, provided no other eligible job or manual session remains.
`longhaul status` prints reported jobs; it does not itself prove an OS assertion.
For an independent power check use `pmset -g assertions` and locate Longhaul's
assertion. Keep the lid open for this test. Physical lid/battery qualification is
a separate procedure in [lid-qualification-probe.md](lid-qualification-probe.md).

## Remove or disconnect

Finish work that depends on Longhaul. With the lid open, pause, confirm cleanup,
then remove managed hooks and the command link using Integrations. Disconnect
Nodebay and disable login launch/unregister the optional companion through the
app before quitting. Move the app to Trash using Finder.

Keep `~/Library/Application Support/Longhaul` until useful recovery files have
been reviewed and backed up. Do not erase saved scenes or job outputs as an
uninstall step. Blender add-on removal is manual in Blender preferences so newer
unrelated preferences are preserved. See [ownership and removal rules](integration-removal.md).
There is no published Homebrew cask or Mac App Store version.
