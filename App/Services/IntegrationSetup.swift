import Foundation
import Darwin
import LonghaulBridge

typealias CodexProfile = LonghaulBridge.CodexProfile
typealias IntegrationInstallationState = LonghaulBridge.IntegrationInstallationState
typealias IntegrationInstallationStatus = LonghaulBridge.IntegrationInstallationStatus

struct ManagedBlenderAddonStatus: Identifiable, Sendable {
    var id: String { url.path }
    let version: String
    let url: URL
    let status: IntegrationInstallationStatus
}

actor IntegrationSetup {
    private let runner = LocalProcess()
    private let home: URL
    private let bundledCLI: URL
    private let mailbox: URL
    private let testingBeforeCommit: (@Sendable () throws -> Void)?
    /// Path injection and the commit seam are for isolated filesystem fixtures.
    /// Production callers use the default app bundle, home and mailbox paths.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundledCLI: URL? = nil,
         mailbox: URL? = nil, testingBeforeCommit: (@Sendable () throws -> Void)? = nil) {
        // Keep the supplied path: Foundation standardization can reintroduce
        // macOS's /var symlink even when a caller supplied /private/var.
        self.home = home
        self.bundledCLI = bundledCLI ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("bin/longhaul")
        self.mailbox = mailbox ?? home.appendingPathComponent("Library/Application Support/Longhaul")
        self.testingBeforeCommit = testingBeforeCommit
    }

    func installCommandTool(cli: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw SetupError.missingCLI }
        let location = home.appendingPathComponent(".local/bin")
        let directory = try IntegrationFileAccess.directory(location, create: true)
        defer { close(directory) }
        let lock = try IntegrationFileAccess.lock(directory); defer { close(lock) }
        if let current = try IntegrationFileAccess.linkSnapshot(directory, name: "longhaul") {
            guard current.destination == cli.path else { throw SetupError.commandExists }
            return "Command tool is installed at ~/.local/bin/longhaul."
        }
        guard try IntegrationFileAccess.sameDirectory(location, descriptor: directory) else { throw SetupError.changedDuringSetup }
        guard symlinkat(cli.path, directory, "longhaul") == 0 else { throw SetupError.commandExists }
        _ = fsync(directory)
        return "Command tool installed at ~/.local/bin/longhaul. Add ~/.local/bin to your shell's PATH if needed."
    }

    func commandToolStatus(cli: URL? = nil) throws -> IntegrationInstallationStatus {
        let expected = cli ?? bundledCLI
        guard let directory = try IntegrationFileAccess.existingDirectory(home.appendingPathComponent(".local/bin")) else {
            return .init(state: .notInstalled, detail: "The optional command link is not installed.")
        }
        defer { close(directory) }
        guard let current = try IntegrationFileAccess.linkSnapshot(directory, name: "longhaul") else {
            return .init(state: .notInstalled, detail: "The optional command link is not installed.")
        }
        guard current.destination == expected.path else {
            return .init(state: .needsAttention, detail: "A different file or link uses ~/.local/bin/longhaul. Longhaul will leave it unchanged.")
        }
        return .init(state: .installed, detail: "The command link points to this app's bundled CLI.", managedCount: 1)
    }

    func removeCommandTool(cli: URL? = nil) throws -> String {
        let expected = cli ?? bundledCLI
        let location = home.appendingPathComponent(".local/bin")
        guard let directory = try IntegrationFileAccess.existingDirectory(location) else { return "The command link is not installed." }
        defer { close(directory) }
        let lock = try IntegrationFileAccess.lock(directory); defer { close(lock) }
        guard let original = try IntegrationFileAccess.linkSnapshot(directory, name: "longhaul") else { return "The command link is not installed." }
        guard original.destination == expected.path else { return "A different file or command link exists. It was left unchanged." }
        let backupDirectory = try IntegrationFileAccess.directory(mailbox.appendingPathComponent("recovery"), create: true)
        defer { close(backupDirectory) }
        let backup = "command-link-\(UUID().uuidString).backup"
        guard symlinkat(expected.path, backupDirectory, backup) == 0 else { throw IntegrationFileAccess.posixError() }
        guard fsync(backupDirectory) == 0 else { throw IntegrationFileAccess.posixError() }
        try testingBeforeCommit?()
        do {
            guard try IntegrationFileAccess.sameDirectory(location, descriptor: directory),
                  try IntegrationFileAccess.linkSnapshot(directory, name: "longhaul") == original else { throw SetupError.changedDuringSetup }
        } catch { throw SetupError.changedDuringSetup }
        guard unlinkat(directory, "longhaul", 0) == 0 else { throw IntegrationFileAccess.posixError() }
        _ = fsync(directory)
        return "Command link removed. Its recoverable link copy is in Longhaul's recovery folder."
    }

    func installBlender(resources: URL, root: URL) async throws -> String {
        let executable = URL(fileURLWithPath: "/Applications/Blender.app/Contents/MacOS/Blender")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SetupError.missingBlender }
        let result = try await runner.run(executable, arguments: ["--background", "--python-exit-code", "1", "--python", resources.appendingPathComponent("blender/install.py").path, "--", resources.path, root.path], timeout: 60)
        guard result.status == 0, result.output.contains("LONGHAUL_SETUP_OK") else { throw SetupError.blenderFailed(result.output) }
        return "Blender integration installed and enabled. Recovery backups are in Longhaul's local data folder. It starts with your next Blender launch."
    }

    func managedBlenderAddons() throws -> [ManagedBlenderAddonStatus] {
        let root = home.appendingPathComponent("Library/Application Support/Blender")
        guard let parent = try IntegrationFileAccess.existingDirectory(root) else { return [] }
        defer { close(parent) }
        let versions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        guard versions.count <= 32 else { throw SetupError.unsafeProfile }
        var result: [ManagedBlenderAddonStatus] = []
        for version in versions {
            let target = version.appendingPathComponent("scripts/addons/longhaul_blender")
            guard let directory = try IntegrationFileAccess.existingDirectory(target) else { continue }
            defer { close(directory) }
            let marker = try IntegrationFileAccess.read(directory, name: "LONGHAUL-INTEGRATION")
            let managed = marker?.bytes == Data("Managed Longhaul integration, version 1\n".utf8)
            let payloads = try ["__init__.py", "longhaul_common.py"].allSatisfy { name in
                guard let value = try IntegrationFileAccess.read(directory, name: name) else { return false }
                return !value.bytes.isEmpty
            }
            let status = IntegrationInstallationStatus(state: managed && payloads ? .installed : .needsAttention,
                detail: managed && payloads ? "Managed add-on files found. Enablement and runtime behavior must be checked in Blender." : "The Longhaul add-on folder is incomplete or unrecognized. It was left unchanged.", managedCount: managed && payloads ? 1 : 0)
            result.append(.init(version: version.lastPathComponent, url: target, status: status))
        }
        guard try IntegrationFileAccess.sameDirectory(root, descriptor: parent) else { throw SetupError.changedDuringSetup }
        return result
    }

    func blenderStatus() throws -> IntegrationInstallationStatus {
        let addons = try managedBlenderAddons()
        guard !addons.isEmpty else { return .init(state: .notInstalled, detail: "No managed Longhaul add-on was found in Blender's standard user add-on folders.") }
        let count = addons.filter { $0.status.state == .installed }.count
        if addons.contains(where: { $0.status.state == .needsAttention }) {
            return .init(state: .needsAttention, detail: "An incomplete or unrecognized Longhaul add-on folder needs review in Blender.", managedCount: count)
        }
        return .init(state: .installed, detail: "Managed files found for \(count) Blender version(s). Check Add-ons settings to confirm enablement.", managedCount: count)
    }

    private var hookInstaller: CodexHookInstaller {
        CodexHookInstaller(home: home, bundledCLI: bundledCLI, mailbox: mailbox,
                           testingBeforeCommit: testingBeforeCommit)
    }
    func profiles() -> [CodexProfile] { (try? hookInstaller.profiles()) ?? [] }
    func hookStatus(profile: URL, cli: URL? = nil, mailbox: URL? = nil) throws -> IntegrationInstallationStatus {
        try hookInstaller.hookStatus(profile: profile, cli: cli, mailbox: mailbox)
    }
    func installHooks(profile: URL, cli: URL, mailbox: URL) throws -> String {
        try hookInstaller.installHooks(profile: profile, cli: cli, mailbox: mailbox)
    }
    func removeHooks(profile: URL) throws -> String { try hookInstaller.removeHooks(profile: profile) }
    func removeHooks(profile: URL, cli: URL, mailbox: URL) throws -> String {
        try hookInstaller.removeHooks(profile: profile, cli: cli, mailbox: mailbox)
    }
    typealias SetupError = IntegrationSetupError
}
