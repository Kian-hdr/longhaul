import Foundation
import Darwin

/// Standalone filesystem fixtures. This does not launch Codex, Blender or Longhaul.
@main @MainActor
struct IntegrationSetupHarness {
    private static let fm = FileManager.default
    private static var checks = 0
    private static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private struct Fixture {
        let home: URL, profile: URL, cli: URL, mailbox: URL
        var hooks: URL { profile.appendingPathComponent("hooks.json") }
        var link: URL { home.appendingPathComponent(".local/bin/longhaul") }
        var recovery: URL { mailbox.appendingPathComponent("recovery") }
        var setup: IntegrationSetup { IntegrationSetup(home: home, bundledCLI: cli, mailbox: mailbox) }
        func racing(_ action: @escaping @Sendable () throws -> Void) -> IntegrationSetup {
            IntegrationSetup(home: home, bundledCLI: cli, mailbox: mailbox, testingBeforeCommit: action)
        }
    }

    static func main() async {
        do { try await run() }
        catch { print("Integration setup harness failed after \(checks) checks: \(error)"); exit(1) }
    }
    private static func run() async throws {
        // Foundation can preserve macOS's /var alias; use its real path so the
        // production code's deliberate no-symlink traversal is exercised.
        guard let canonical = realpath(fm.temporaryDirectory.path, nil) else { throw Failure(description: "Fixture temporary directory unavailable") }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("longhaul-integration-fixtures-\(UUID().uuidString)")
        free(canonical)
        try mkdir(root)
        defer { try? fm.removeItem(at: root) } // Only this harness's disposable fixtures.
        print("Checking exact hook ownership, preservation and backups")
        try await hooksAndPreservation(root)
        print("Checking malformed and unsafe integration locations")
        try await unsafeInputs(root)
        print("Checking concurrent changes and advisory locking")
        try await concurrentChanges(root)
        print("Checking command link ownership and removal (\(checks) checks passed)")
        try await commandLinks(root)
        print("Checking Blender managed-file discovery")
        try await blenderDiscovery(root)
        print("Integration setup harness passed: \(checks) checks; isolated fixtures only.")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        checks += 1
    }
    private static func mustFail(_ message: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch is IntegrationSetup.SetupError { checks += 1; return }
        throw Failure(description: "Expected refusal: \(message)")
    }
    private static func mustDetectChange(_ message: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch IntegrationSetup.SetupError.changedDuringSetup { checks += 1; return }
        throw Failure(description: "Expected concurrent-change refusal: \(message)")
    }
    private static func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw Failure(description: "Fixture chmod failed") }
    }
    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
    }
    private static func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private static func fixture(_ root: URL, _ name: String) throws -> Fixture {
        let home = root.appendingPathComponent(name)
        let profile = home.appendingPathComponent(".codex-personal")
        let cli = home.appendingPathComponent("Longhaul's App/bin/longhaul")
        let mailbox = home.appendingPathComponent("Library/Application Support/Longhaul's Data")
        try mkdir(profile); try mkdir(cli.deletingLastPathComponent())
        try write(Data("model = \"fixture\"\n".utf8), to: profile.appendingPathComponent("config.toml"))
        try write(Data("#!/bin/sh\nexit 0\n".utf8), to: cli)
        guard chmod(cli.path, 0o700) == 0 else { throw Failure(description: "Fixture executable chmod failed") }
        return Fixture(home: home, profile: profile, cli: cli, mailbox: mailbox)
    }
    private static func install(_ f: Fixture) async throws {
        _ = try await f.setup.installHooks(profile: f.profile, cli: f.cli, mailbox: f.mailbox)
    }
    private static func ownedGroup(_ f: Fixture, event: String) -> [String: Any] {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = quote(f.cli.path) + " --root " + quote(f.mailbox.path) + " hook " + quote(f.profile.lastPathComponent)
        return ["hooks": [["type": "command", "command": command, "timeout": ["Interrupt", "SessionEnd"].contains(event) ? 3 : 5,
                            "statusMessage": "Longhaul job protection", "additionalContextLimit": 600]]]
    }
    private static func mode(_ url: URL) throws -> Int {
        (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
    private static func backups(_ f: Fixture, prefix: String = "hooks-") throws -> [URL] {
        try fm.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func hooksAndPreservation(_ root: URL) async throws {
        let f = try fixture(root, "hooks")
        try check(try await f.setup.hookStatus(profile: f.profile).state == .notInstalled, "Absent hooks status")
        try check(await f.setup.profiles().map { $0.url.path } == [f.profile.path], "Only fixture profile discovered")
        let custom: [String: Any] = ["matcher": "Write", "hooks": [["type": "command", "command": "echo custom", "timeout": 7]]]
        let original: [String: Any] = ["customRoot": ["enabled": true, "values": [1, 2, 3]], "hooks": ["PreToolUse": [custom], "CustomEvent": [custom]]]
        try writeJSON(original, to: f.hooks)
        let originalBytes = try Data(contentsOf: f.hooks)
        try await install(f)
        let status = try await f.setup.hookStatus(profile: f.profile)
        try check(status.state == .needsTrust && status.managedCount == 9, "Installed definitions require runtime trust review")
        let after = try readJSON(f.hooks)
        let hooks = after["hooks"] as! [String: [[String: Any]]]
        for event in events {
            try check((hooks[event] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: ownedGroup(f, event: event)) }, "Exact shell-quoted definition for \(event)")
        }
        try check(NSDictionary(dictionary: hooks["PreToolUse"]![0]).isEqual(to: custom), "Unrelated PreToolUse preserved")
        try check(NSDictionary(dictionary: after["customRoot"] as! [String: Any]).isEqual(to: original["customRoot"] as! [String: Any]), "Unrelated root data preserved")
        let firstBackups = try backups(f)
        try check(firstBackups.count == 1 && (try Data(contentsOf: firstBackups[0])) == originalBytes, "Exact original bytes backed up")
        try check(try mode(firstBackups[0]) == 0o600 && mode(f.recovery) == 0o700, "Private backup permissions")
        try check(try mode(f.hooks) == 0o600, "Private installed config permissions")
        try await install(f)
        try check(try await f.setup.hookStatus(profile: f.profile).managedCount == 9, "Reinstall has no duplicate owned groups")
        _ = try await f.setup.removeHooks(profile: f.profile)
        try check(NSDictionary(dictionary: try readJSON(f.hooks)).isEqual(to: original), "Removal preserves every unrelated JSON value")
        try check(try await f.setup.hookStatus(profile: f.profile).state == .notInstalled, "Removal status")
        let noOpBytes = try Data(contentsOf: f.hooks)
        let countBefore = try backups(f).count
        _ = try await f.setup.removeHooks(profile: f.profile)
        try check(try Data(contentsOf: f.hooks) == noOpBytes && backups(f).count == countBefore, "No matches means byte-preserving no-op without backup")

        let ambiguous = try fixture(root, "ambiguous")
        try await install(ambiguous)
        var mixed = try readJSON(ambiguous.hooks)
        var mixedHooks = mixed["hooks"] as! [String: [[String: Any]]]
        let exact = ownedGroup(ambiguous, event: "PreToolUse")
        let handler = (exact["hooks"] as! [[String: Any]])[0]
        var changed = handler; changed["timeout"] = 99
        var otherPath = handler; otherPath["command"] = "echo Longhaul"
        var extra = exact; extra["matcher"] = "Write"
        var extended = handler; extended["extra"] = "preserve"
        let preserved: [[String: Any]] = [extra, ["hooks": [handler, ["type": "command", "command": "echo other"]]],
                                              ["hooks": [changed]], ["hooks": [otherPath]], ["hooks": [extended]]]
        mixedHooks["PreToolUse"] = [exact, exact] + preserved
        mixedHooks["UnknownEvent"] = [exact]
        mixed["hooks"] = mixedHooks
        try writeJSON(mixed, to: ambiguous.hooks)
        try check(try await ambiguous.setup.hookStatus(profile: ambiguous.profile).state == .needsAttention, "Duplicates and modified definitions need attention")
        let ambiguousBytes = try Data(contentsOf: ambiguous.hooks)
        try await mustFail("reinstall cannot add duplicate handlers around ambiguous definitions") { try await install(ambiguous) }
        try check(try Data(contentsOf: ambiguous.hooks) == ambiguousBytes, "Ambiguous reinstall leaves definitions unchanged")
        let message = try await ambiguous.setup.removeHooks(profile: ambiguous.profile)
        let remaining = try readJSON(ambiguous.hooks)["hooks"] as! [String: [[String: Any]]]
        try check(NSArray(array: remaining["PreToolUse"]!).isEqual(to: preserved), "Combined, matcher, modified timeout/path and extra fields survive")
        try check(NSArray(array: remaining["UnknownEvent"]!).isEqual(to: [exact]), "Unrecognized event survives")
        try check(message.contains("manual review"), "Remaining modified entries explained")
        try check(try await ambiguous.setup.hookStatus(profile: ambiguous.profile).managedCount == 0, "Only exact owned groups removed")

        let partial = try fixture(root, "partial")
        try writeJSON(["hooks": ["Stop": [ownedGroup(partial, event: "Stop")]]], to: partial.hooks)
        try check(try await partial.setup.hookStatus(profile: partial.profile).state == .needsAttention, "Partial integration needs attention")
        _ = try await partial.setup.removeHooks(profile: partial.profile)
        try check((try readJSON(partial.hooks)["hooks"] as! [String: Any]).isEmpty, "Empty hooks dictionary retained")
    }

    private static func unsafeInputs(_ root: URL) async throws {
        let invalid = ["{", "[]", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}",
                       "{\"hooks\":{\"Stop\":[{}]}}", "{\"hooks\":{\"Stop\":[{\"hooks\":[]}]}}",
                       "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":7}]}]}}"]
        for (index, raw) in invalid.enumerated() {
            let f = try fixture(root, "invalid-\(index)")
            let bytes = Data(raw.utf8); try write(bytes, to: f.hooks)
            try await mustFail("malformed config \(index)") { _ = try await f.setup.removeHooks(profile: f.profile) }
            try check(try Data(contentsOf: f.hooks) == bytes, "Malformed config unchanged \(index)")
            try await mustFail("malformed status \(index)") { _ = try await f.setup.hookStatus(profile: f.profile) }
        }
        let symlinkFile = try fixture(root, "symlink-file")
        let unrelated = symlinkFile.home.appendingPathComponent("unrelated.json")
        let sentinel = Data("{\"preserve\":true}".utf8); try write(sentinel, to: unrelated)
        try fm.createSymbolicLink(atPath: symlinkFile.hooks.path, withDestinationPath: unrelated.path)
        try await mustFail("symlink hook file") { _ = try await symlinkFile.setup.removeHooks(profile: symlinkFile.profile) }
        try check(try Data(contentsOf: unrelated) == sentinel, "Symlink target unchanged")
        let alias = symlinkFile.home.appendingPathComponent(".codex-alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: symlinkFile.profile.path)
        try await mustFail("symlink profile") { _ = try await symlinkFile.setup.removeHooks(profile: alias) }
        try check(await symlinkFile.setup.profiles().map { $0.url.path } == [symlinkFile.profile.path], "Profile listing skips symlink alias")
        let ancestor = root.appendingPathComponent("home-alias")
        try fm.createSymbolicLink(atPath: ancestor.path, withDestinationPath: symlinkFile.home.path)
        try await mustFail("symlink ancestor") { _ = try await symlinkFile.setup.removeHooks(profile: ancestor.appendingPathComponent(".codex-personal")) }

        let hardlink = try fixture(root, "hardlink")
        try write(sentinel, to: hardlink.hooks)
        try check(link(hardlink.hooks.path, hardlink.home.appendingPathComponent("shared.json").path) == 0, "Hardlink fixture created")
        try await mustFail("hardlinked hooks") { _ = try await hardlink.setup.removeHooks(profile: hardlink.profile) }
        try check(try Data(contentsOf: hardlink.hooks) == sentinel, "Hardlinked config unchanged")
        let writable = try fixture(root, "writable")
        try write(sentinel, to: writable.hooks); _ = chmod(writable.hooks.path, 0o666)
        try await mustFail("shared writable hooks") { _ = try await writable.setup.removeHooks(profile: writable.profile) }
        _ = chmod(writable.hooks.path, 0o600); _ = chmod(writable.profile.path, 0o777)
        try await mustFail("shared writable profile") { _ = try await writable.setup.removeHooks(profile: writable.profile) }
        _ = chmod(writable.profile.path, 0o700)
        let fifo = try fixture(root, "fifo")
        try check(mkfifo(fifo.hooks.path, 0o600) == 0, "FIFO fixture created")
        try await mustFail("FIFO hooks do not block") { _ = try await fifo.setup.removeHooks(profile: fifo.profile) }
        let directory = try fixture(root, "directory-file")
        try mkdir(directory.hooks)
        try await mustFail("hooks path is a directory") { _ = try await directory.setup.removeHooks(profile: directory.profile) }
        let large = try fixture(root, "oversized")
        let oversized = Data(repeating: 0x20, count: 1_048_577)
        try write(oversized, to: large.hooks)
        try await mustFail("oversized config") { _ = try await large.setup.removeHooks(profile: large.profile) }
        try check(try Data(contentsOf: large.hooks) == oversized, "Oversized config untouched")
        let backup = try fixture(root, "unsafe-backup")
        try await install(backup)
        let before = try Data(contentsOf: backup.hooks)
        try mkdir(backup.mailbox)
        let target = backup.home.appendingPathComponent("foreign-recovery"); try mkdir(target)
        try fm.createSymbolicLink(atPath: backup.recovery.path, withDestinationPath: target.path)
        try await mustFail("symlink recovery directory") { _ = try await backup.setup.removeHooks(profile: backup.profile) }
        try check(try Data(contentsOf: backup.hooks) == before, "Backup refusal preserves config")
        try check(try fm.contentsOfDirectory(atPath: target.path).isEmpty, "No write through recovery symlink")
    }

    private static func concurrentChanges(_ root: URL) async throws {
        let f = try fixture(root, "concurrent-edit"); try await install(f)
        let changed = Data("{\"newWriter\":true}".utf8)
        let setup = f.racing { try changed.write(to: f.hooks) }
        try await mustDetectChange("in-place hook edit") { _ = try await setup.removeHooks(profile: f.profile) }
        try check(try Data(contentsOf: f.hooks) == changed, "Concurrent file edit preserved")
        try check(try fm.contentsOfDirectory(atPath: f.profile.path).allSatisfy { !$0.hasPrefix(".longhaul-hooks-") }, "Staged file cleaned after refusal")

        let replacement = try fixture(root, "concurrent-replacement"); try await install(replacement)
        let staged = replacement.home.appendingPathComponent("other-hooks.json"); try write(changed, to: staged)
        let replacingSetup = replacement.racing {
            guard rename(staged.path, replacement.hooks.path) == 0 else { throw Failure(description: "Fixture rename failed") }
        }
        try await mustDetectChange("hook inode replaced") { _ = try await replacingSetup.removeHooks(profile: replacement.profile) }
        try check(try Data(contentsOf: replacement.hooks) == changed, "Concurrent replacement preserved")

        let moved = try fixture(root, "concurrent-directory"); try await install(moved)
        let alternate = moved.home.appendingPathComponent("replacement"); try mkdir(alternate)
        try write(changed, to: alternate.appendingPathComponent("hooks.json"))
        let displaced = moved.home.appendingPathComponent("old-profile")
        let movingSetup = moved.racing {
            try FileManager.default.moveItem(at: moved.profile, to: displaced)
            try FileManager.default.moveItem(at: alternate, to: moved.profile)
        }
        try await mustDetectChange("profile directory replaced") { _ = try await movingSetup.removeHooks(profile: moved.profile) }
        try check(try Data(contentsOf: moved.hooks) == changed, "Replacement profile untouched")

        let locked = try fixture(root, "locked"); try await install(locked)
        let descriptor = open(locked.profile.appendingPathComponent(".longhaul-setup.lock").path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure(description: "Fixture lock open failed") }
        defer { close(descriptor) }
        try check(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Fixture advisory lock held")
        try await mustDetectChange("another Longhaul setup holds lock") { _ = try await locked.setup.removeHooks(profile: locked.profile) }

        let absent = try fixture(root, "concurrent-create")
        let creatingSetup = absent.racing { try changed.write(to: absent.hooks) }
        try await mustDetectChange("config created while installing") { _ = try await creatingSetup.installHooks(profile: absent.profile, cli: absent.cli, mailbox: absent.mailbox) }
        try check(try Data(contentsOf: absent.hooks) == changed, "Concurrent creation not overwritten")
    }

    private static func commandLinks(_ root: URL) async throws {
        let f = try fixture(root, "command")
        try check(try await f.setup.commandToolStatus().state == .notInstalled, "Absent command status")
        _ = try await f.setup.installCommandTool(cli: f.cli)
        try check(try fm.destinationOfSymbolicLink(atPath: f.link.path) == f.cli.path, "Command link points at fixture bundled CLI")
        try check(try await f.setup.commandToolStatus().state == .installed, "Owned link installed status")
        _ = try await f.setup.installCommandTool(cli: f.cli)
        _ = try await f.setup.removeCommandTool()
        try check(try await f.setup.commandToolStatus().state == .notInstalled, "Owned link removed")
        let saved = try backups(f, prefix: "command-link-")
        try check(saved.count == 1 && (try fm.destinationOfSymbolicLink(atPath: saved[0].path)) == f.cli.path, "Recoverable command symlink retained")
        try check(fm.isExecutableFile(atPath: f.cli.path), "Bundled CLI untouched")
        _ = try await f.setup.removeCommandTool()
        try check(try backups(f, prefix: "command-link-").count == 1, "Repeated removal is no-op")
        try write(Data("foreign tool".utf8), to: f.link)
        try check(try await f.setup.commandToolStatus().state == .needsAttention, "Foreign regular command status")
        _ = try await f.setup.removeCommandTool()
        try check(try Data(contentsOf: f.link) == Data("foreign tool".utf8), "Foreign regular command preserved")
        try await mustFail("install cannot replace foreign command") { _ = try await f.setup.installCommandTool(cli: f.cli) }
        try fm.removeItem(at: f.link)
        try fm.createSymbolicLink(atPath: f.link.path, withDestinationPath: "../other-tool")
        _ = try await f.setup.removeCommandTool()
        try check(try fm.destinationOfSymbolicLink(atPath: f.link.path) == "../other-tool", "Foreign relative symlink preserved")

        let dangling = try fixture(root, "dangling-command")
        _ = try await dangling.setup.installCommandTool(cli: dangling.cli)
        try fm.removeItem(at: dangling.cli)
        _ = try await dangling.setup.removeCommandTool()
        try check(try await dangling.setup.commandToolStatus().state == .notInstalled, "Owned dangling command link can be removed")
        let racing = try fixture(root, "racing-command")
        _ = try await racing.setup.installCommandTool(cli: racing.cli)
        let latest = Data("new unrelated command".utf8)
        let racingSetup = racing.racing {
            try FileManager.default.removeItem(at: racing.link)
            try latest.write(to: racing.link)
        }
        try await mustDetectChange("command link replaced") { _ = try await racingSetup.removeCommandTool() }
        try check(try Data(contentsOf: racing.link) == latest, "Concurrent command preserved")
        let unsafe = try fixture(root, "unsafe-command")
        let bin = unsafe.home.appendingPathComponent(".local/bin")
        try mkdir(bin.deletingLastPathComponent())
        let foreignBin = unsafe.home.appendingPathComponent("foreign-bin"); try mkdir(foreignBin)
        try fm.createSymbolicLink(atPath: bin.path, withDestinationPath: foreignBin.path)
        try await mustFail("command bin symlink") { _ = try await unsafe.setup.removeCommandTool() }
        try check(try fm.contentsOfDirectory(atPath: foreignBin.path).isEmpty, "Foreign bin unchanged")
    }

    private static func blenderDiscovery(_ root: URL) async throws {
        let f = try fixture(root, "blender")
        try check(try await f.setup.blenderStatus().state == .notInstalled, "No Blender integration status")
        let blender = f.home.appendingPathComponent("Library/Application Support/Blender")
        let addon = blender.appendingPathComponent("5.0/scripts/addons/longhaul_blender")
        try mkdir(addon)
        try write(Data("Managed Longhaul integration, version 1\n".utf8), to: addon.appendingPathComponent("LONGHAUL-INTEGRATION"))
        try write(Data("# fixture addon".utf8), to: addon.appendingPathComponent("__init__.py"))
        try write(Data("# fixture common".utf8), to: addon.appendingPathComponent("longhaul_common.py"))
        let prefs = blender.appendingPathComponent("5.0/config/userpref.blend"); try mkdir(prefs.deletingLastPathComponent())
        let preferenceBytes = Data("unrelated Blender preferences".utf8); try write(preferenceBytes, to: prefs)
        let installed = try await f.setup.blenderStatus()
        try check(installed.state == .installed && installed.managedCount == 1, "Managed Blender files detected")
        try check(installed.detail.contains("confirm enablement"), "Filesystem presence does not claim Blender enabled")
        let records = try await f.setup.managedBlenderAddons()
        try check(records.count == 1 && records[0].version == "5.0" && records[0].url.path == addon.path, "Version-specific managed folder records")
        let incomplete = blender.appendingPathComponent("5.1/scripts/addons/longhaul_blender"); try mkdir(incomplete)
        try write(Data("not our marker".utf8), to: incomplete.appendingPathComponent("LONGHAUL-INTEGRATION"))
        try check(try await f.setup.blenderStatus().state == .needsAttention, "Unrecognized addon needs attention")
        try check(try await f.setup.managedBlenderAddons().count == 2, "Incomplete addon is reported")
        try check(try Data(contentsOf: prefs) == preferenceBytes, "Blender preferences never modified")
        let symlink = blender.appendingPathComponent("5.2/scripts/addons/longhaul_blender")
        try mkdir(symlink.deletingLastPathComponent())
        try fm.createSymbolicLink(atPath: symlink.path, withDestinationPath: addon.path)
        try await mustFail("Blender addon symlink") { _ = try await f.setup.managedBlenderAddons() }
        try check(try Data(contentsOf: prefs) == preferenceBytes, "Blender symlink refusal preserves preferences")
    }
}
