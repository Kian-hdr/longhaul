# Release engineering

The direct-download target is Longhaul v1.0.0 for macOS 26+ / arm64. The source
license is GPL-3.0-only. The current acceptance state is in [STATUS.md](STATUS.md).
Homebrew and Mac App Store distribution are separate, unqualified channels.

## Source and assets

Publish an identified source commit with the matching `v1.0.0` tag. Keep original
source, icon generator/assets, integrations, tests, build scripts and the complete
license together. Inspect the final staged selection for secrets, personal paths,
private runtime history and generated output. Never stage `private-evidence`,
recovery files, build caches, local sessions or signing credentials.

Keep version/build, tag, asset name and source consistent. CI uses least privilege;
untrusted contribution code must not receive signing credentials. License duties
and component provenance are recorded in [LICENSE-STATUS.md](../LICENSE-STATUS.md).

## Build, sign and notarize

1. Run the applicable tests from the identified release source. Record actual
   outcomes, toolchain and architecture coverage.
2. Build with `script/build_and_run.sh --build-only`. Stage a fresh Release copy
   with `script/package_local.sh`, an explicit `SIGNING_IDENTITY` and a new
   `LONGHAUL_STAGE_DIR`. Do not replace an app while it holds protected work.
3. Inspect bundle version, arm64 architecture, minimum OS, icon, license,
   integrations, CLI, relay and entitlements. Verify inside-out Developer ID
   signatures, hardened runtime and secure timestamps.
4. Submit the exact package using an existing protected notary credential. Wait
   for **Accepted**, inspect the submission result, staple the app and validate
   its ticket. No credential values belong in source or logs.
5. Produce `Longhaul-1.0.0-arm64.zip` containing the stapled app. Assess the final
   extracted app through Gatekeeper, then perform a real install/launch check.
6. Generate `SHA256SUMS` from final bytes, upload the immutable assets and download
   them again to verify the manifest. Publish matching source and release notes
   with the closed-lid experimental scope intact.

Do not publish an unnotarized binary under the official release filename. Missing
credentials block the binary gate; a successful signature is not notarization.
Do not overwrite a versioned public artifact to repair it. Issue a new version.

For the combined local pipeline, `script/release.sh` requires a clean committed
worktree, `SIGNING_IDENTITY`, an existing `NOTARY_PROFILE`, a fresh
`LONGHAUL_STAGE_DIR` and a fresh `LONGHAUL_RELEASE_DIR`. It runs
`script/test_all.sh`, packages and calls `script/notarize.sh`, then records
`SOURCE_COMMIT`. The app also embeds `LonghaulSourceCommit` in its metadata.
These scripts do not create or overwrite a GitHub release; final downloaded
installation and launch still need validation.

## Update and rollback

Keep the lid open, pause Longhaul, wait for accepted owned-session cleanup and
quit before replacing a live installation. Preserve a recoverable previous app.
After install, verify the installed signature/version and actual reporting before
resuming protection. Keep preferences, recovery files and unrelated integrations.

## Optional future channels

`script/make_cask.py` can generate a draft from explicit version, URL and SHA-256.
It is not a publication or installation test. Publish a cask only after hosted
byte verification and fresh install/uninstall/reinstall checks. Never add a zap
rule that erases a user's saved recovery artifacts.

Mac App Store readiness is not claimed. It needs its own entitlement, sandbox,
API, privacy, packaging and distribution review rather than reusing a Developer ID
package. See [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [GitHub release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github).
