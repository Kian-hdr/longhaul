# Longhaul

Native macOS 26+, Apple silicon utility. Follow Build macOS Apps together with apple-native-macos-design. Use release-macos-app before distribution work. Read README.md and docs/STATUS.md before changes.

Use `script/build_and_run.sh` for the local app build/run loop and `swift test` for LonghaulCore. Do not stop unrelated apps or tasks. Power and integration tests must be bounded, reversible and separately recorded from unit/UI tests. Never claim closed-lid or locked desktop operation from an idle-sleep assertion.

Keep credentials, conversations, personal paths and private runtime evidence out of tracked files. Never expose arbitrary privileged execution. Preserve OS emergency handling. Never silently push, publish, choose a governing license, or uninstall Amphetamine.

Keep docs/STATUS.md current with implementation and test evidence. Build products and runtime state are not source. No app update during protected work without controlled release of owned power holds.
