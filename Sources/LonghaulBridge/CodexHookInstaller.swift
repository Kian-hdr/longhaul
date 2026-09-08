import Foundation
import Darwin

public struct CodexProfile: Identifiable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }
    public init(url: URL) { self.url = url }
}

public enum IntegrationInstallationState: String, Codable, Sendable {
    case notInstalled = "Not installed"
    case installed = "Installed"
    case needsTrust = "Installed / Needs trust"
    case needsAttention = "Needs attention"
}
public struct IntegrationInstallationStatus: Codable, Sendable {
    public let state: IntegrationInstallationState
    public let detail: String
    public var managedCount = 0
    public init(state: IntegrationInstallationState, detail: String, managedCount: Int = 0) {
        self.state = state; self.detail = detail; self.managedCount = managedCount
    }
}
/// One checked implementation for native UI and CLI hook setup. Trust belongs
/// to Codex; installing definitions never claims host approval or live reporting.
public struct CodexHookInstaller: Sendable {
    public typealias SetupError = IntegrationSetupError
    private let home: URL
    private let bundledCLI: URL
    private let mailbox: URL
    private let testingBeforeCommit: (@Sendable () throws -> Void)?
    private static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
    private static let marker = "Longhaul job protection"
    private static let maximumConfigBytes = 1_048_576


    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                bundledCLI: URL, mailbox: URL = Mailbox.defaultRoot,
                testingBeforeCommit: (@Sendable () throws -> Void)? = nil) {
        self.home = home; self.bundledCLI = bundledCLI; self.mailbox = mailbox
        self.testingBeforeCommit = testingBeforeCommit
    }
    public func profiles() throws -> [CodexProfile] {
        let parent = try IntegrationFileAccess.directory(home); defer { close(parent) }
        let entries = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        guard entries.count <= 16_384 else { throw SetupError.unsafeProfile }
        return entries
            .filter { url in
                guard url.lastPathComponent.hasPrefix(".codex"), let descriptor = try? IntegrationFileAccess.directory(url) else { return false }
                defer { close(descriptor) }
                var info = stat()
                return fstatat(descriptor, "config.toml", &info, AT_SYMLINK_NOFOLLOW) == 0 && IntegrationFileAccess.safeRegular(info)
            }.sorted { $0.path < $1.path }.map { CodexProfile(url: $0) }
    }

    public func hookStatus(profile: URL, cli: URL? = nil, mailbox: URL? = nil) throws -> IntegrationInstallationStatus {
        let descriptor = try IntegrationFileAccess.directory(profile); defer { close(descriptor) }
        guard let original = try IntegrationFileAccess.read(descriptor, name: "hooks.json") else {
            return .init(state: .notInstalled, detail: "Longhaul hooks are not installed in this profile.")
        }
        let config = try Self.config(original.bytes)
        let hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = Self.command(profile: profile, cli: cli ?? bundledCLI, mailbox: mailbox ?? self.mailbox)
        let owned = Self.events.map { event in (hooks[event] ?? []).filter { Self.owned($0, event: event, command: command) }.count }
        let ambiguous = hooks.contains { event, groups in groups.contains { Self.marked($0) && !Self.owned($0, event: event, command: command) } }
        if owned.allSatisfy({ $0 == 1 }) && !ambiguous {
            return .init(state: .needsTrust, detail: "All nine hook definitions are installed. Review their exact definitions in Codex /hooks; filesystem inspection cannot verify trust.", managedCount: 9)
        }
        if owned.reduce(0, +) > 0 || ambiguous {
            return .init(state: .needsAttention, detail: "Longhaul hooks are partial, duplicated or modified. Review the profile before reinstalling.", managedCount: owned.reduce(0, +))
        }
        return .init(state: .notInstalled, detail: "No exact Longhaul hook definitions were found.")
    }

    public func installHooks(profile: URL, cli: URL, mailbox: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw SetupError.missingCLI }
        let descriptor = try IntegrationFileAccess.directory(profile); defer { close(descriptor) }
        let lock = try IntegrationFileAccess.lock(descriptor); defer { close(lock) }
        let original = try IntegrationFileAccess.read(descriptor, name: "hooks.json")
        var config = try original.map { try Self.config($0.bytes) } ?? [:]
        var hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = Self.command(profile: profile, cli: cli, mailbox: mailbox)
        guard !hooks.contains(where: { event, groups in
            groups.contains { Self.marked($0) && !Self.owned($0, event: event, command: command) }
        }) else { throw SetupError.modifiedHooks }
        for event in Self.events {
            var groups = hooks[event] ?? []
            groups.removeAll { Self.owned($0, event: event, command: command) }
            groups.append(Self.group(event: event, command: command))
            hooks[event] = groups
        }
        config["hooks"] = hooks
        try commit(config, original: original, profile: profile, descriptor: descriptor, mailbox: mailbox)
        return "Hooks installed for \(profile.lastPathComponent). Review and trust them in Codex using /hooks. Existing tasks may need a new turn before detection begins."
    }

    public func removeHooks(profile: URL) throws -> String {
        try removeHooks(profile: profile, cli: bundledCLI, mailbox: mailbox)
    }
    public func removeHooks(profile: URL, cli: URL, mailbox: URL) throws -> String {
        let descriptor = try IntegrationFileAccess.directory(profile); defer { close(descriptor) }
        let lock = try IntegrationFileAccess.lock(descriptor); defer { close(lock) }
        guard let original = try IntegrationFileAccess.read(descriptor, name: "hooks.json") else { return "Longhaul hooks are not installed in this profile." }
        var config = try Self.config(original.bytes)
        var hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = Self.command(profile: profile, cli: cli, mailbox: mailbox)
        var removed = 0
        for event in Self.events {
            let previous = hooks[event] ?? []
            let remaining = previous.filter { !Self.owned($0, event: event, command: command) }
            removed += previous.count - remaining.count
            if remaining.count != previous.count {
                if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
            }
        }
        guard removed > 0 else { return "No exact Longhaul-owned hook groups were found. The profile was left unchanged; review any modified Longhaul entries in Codex /hooks." }
        config["hooks"] = hooks
        try commit(config, original: original, profile: profile, descriptor: descriptor, mailbox: mailbox)
        let remaining = hooks.values.flatMap { $0 }.contains(where: Self.marked)
        return "Removed \(removed) exact Longhaul hook group(s). A backup is in Longhaul's recovery folder. Other hooks were preserved." + (remaining ? " Modified or combined Longhaul entries remain for manual review." : "")
    }

    private func commit(_ config: [String: Any], original: IntegrationFileAccess.FileSnapshot?, profile: URL, descriptor: Int32, mailbox: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= Self.maximumConfigBytes else { throw SetupError.invalidConfig }
        if let original {
            let recovery = try IntegrationFileAccess.directory(mailbox.appendingPathComponent("recovery"), create: true)
            defer { close(recovery) }
            try IntegrationFileAccess.writeNew(original.bytes, directory: recovery, name: "hooks-\(UUID().uuidString).backup")
        }
        let staging = ".longhaul-hooks-\(UUID().uuidString).tmp"
        try IntegrationFileAccess.writeNew(bytes, directory: descriptor, name: staging)
        defer { _ = unlinkat(descriptor, staging, 0) }
        try testingBeforeCommit?()
        do {
            guard try IntegrationFileAccess.sameDirectory(profile, descriptor: descriptor),
                  try IntegrationFileAccess.read(descriptor, name: "hooks.json") == original else { throw SetupError.changedDuringSetup }
        } catch { throw SetupError.changedDuringSetup }
        // Every Longhaul setup writer uses the same advisory lock. Re-read the
        // pinned profile and exact file immediately before atomic replacement.
        let result = original == nil
            ? renameatx_np(descriptor, staging, descriptor, "hooks.json", UInt32(RENAME_EXCL))
            : renameat(descriptor, staging, descriptor, "hooks.json")
        guard result == 0 else { throw SetupError.changedDuringSetup }
        guard fsync(descriptor) == 0 else { throw IntegrationFileAccess.posixError() }
    }

    private static func group(event: String, command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command,
                    "timeout": event == "Interrupt" || event == "SessionEnd" ? 3 : 5,
                    "statusMessage": marker, "additionalContextLimit": 600]]]
    }
    private static func command(profile: URL, cli: URL, mailbox: URL) -> String {
        IntegrationFileAccess.quote(cli.path) + " --root " + IntegrationFileAccess.quote(mailbox.path) + " hook " + IntegrationFileAccess.quote(profile.lastPathComponent)
    }
    private static func owned(_ value: [String: Any], event: String, command: String) -> Bool {
        events.contains(event) && NSDictionary(dictionary: value).isEqual(to: group(event: event, command: command))
    }
    private static func marked(_ value: [String: Any]) -> Bool {
        (value["hooks"] as? [[String: Any]] ?? []).contains { $0["statusMessage"] as? String == marker }
    }
    private static func config(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= maximumConfigBytes,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SetupError.invalidConfig }
        if let value = root["hooks"] {
            guard let hooks = value as? [String: [[String: Any]]], hooks.count <= 128 else { throw SetupError.invalidConfig }
            for (event, groups) in hooks {
                guard !event.isEmpty, event.utf8.count <= 180, groups.count <= 512 else { throw SetupError.invalidConfig }
                for group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]], !handlers.isEmpty, handlers.count <= 128 else { throw SetupError.invalidConfig }
                    for handler in handlers {
                        guard let type = handler["type"] as? String, !type.isEmpty,
                              type != "command" || handler["command"] is String else { throw SetupError.invalidConfig }
                    }
                }
            }
        }
        return root
    }

}
