import AppKit

@MainActor @Observable
final class ResolveBridge {
    var enabled = false
    var status = "Off"
    private var process: Process?
    private var logHandle: FileHandle?
    private var lastAttempt = Date.distantPast
    private var wasRunning = false
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let runner = LocalProcess()
    private let root: URL
    private let resources: URL?
    init(root: URL, resources: URL?) {
        self.root = root; self.resources = resources
    }
    var python: URL? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { stop(); status = "Off" }
        else { lastAttempt = .distantPast; task = Task { await refresh() } }
    }
    func refresh() async {
        guard enabled else { return }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.blackmagic-design.DaVinciResolve") == true }
        if !running { stopChild(); status = "Waiting for Resolve"; wasRunning = false; return }
        if !wasRunning { lastAttempt = .distantPast; wasRunning = true }
        if process?.isRunning == true { status = "Monitoring Resolve exports"; return }
        guard Date().timeIntervalSince(lastAttempt) > 60 else { return }
        lastAttempt = Date()
        guard let python, let script = resources?.appendingPathComponent("resolve/longhaul_resolve.py") else { status = "Python 3 is required"; return }
        status = "Checking scripting access…"
        do {
            let probe = try await runner.run(python, arguments: [script.path, "--probe"], timeout: 10)
            guard enabled else { return }
            guard probe.status == 0 else { status = "Unavailable: Resolve has not granted local scripting"; return }
            let log = root.appendingPathComponent("resolve-bridge.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            let child = Process(); child.executableURL = python; child.arguments = [script.path]
            var environment = ProcessInfo.processInfo.environment; environment["LONGHAUL_DATA_DIR"] = root.path
            child.environment = environment; child.standardInput = FileHandle.nullDevice
            child.standardOutput = handle; child.standardError = handle
            try child.run(); process = child; logHandle = handle
            status = "Monitoring Resolve exports"
        } catch { status = "Scripting check failed: \(error.localizedDescription)" }
    }
    func stop() {
        enabled = false; task?.cancel(); task = nil
        stopChild()
    }
    private func stopChild() {
        if let process, process.isRunning { process.terminate() }
        process = nil; try? logHandle?.close(); logHandle = nil
    }
}
