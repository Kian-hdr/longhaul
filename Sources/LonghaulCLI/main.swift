import Foundation
import LonghaulCore
import LonghaulBridge
import Darwin

func readInput(limit: Int) throws -> Data {
    let data = try FileHandle.standardInput.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw Mailbox.BridgeError.tooLarge }
    return data
}

private let usage = """
Usage: longhaul [--root PATH] COMMAND
  run -- COMMAND [ARGS]              Supervise and report a foreground command
  profiles [--home ABSOLUTE_PATH]    Discover local .codex* profiles (JSON)
  hooks status|install|remove --profile ABSOLUTE_PATH
                                    Inspect or manage exact Longhaul hooks (JSON)
  status                            Read mailbox job reports (JSON)
  event | hook [PROFILE] | receipt  Consume integration JSON on stdin
  checkpoint-ack REQUEST --files ABSOLUTE_PATH [PATH...]
  lid-inspect                       Read native power observations (JSON)
Hook trust remains under Codex control. Installation does not prove live reporting.
"""

private func hookSetup(_ args: [String], root: URL) throws -> Int32 {
    func absolute(_ text: String) throws -> URL {
        guard text.hasPrefix("/"), !text.contains("\0"), text.utf8.count < 4096,
              !text.split(separator: "/").contains("..") else { throw CLIError.usage }
        return URL(fileURLWithPath: text)
    }
    guard let path = ProcessIdentity.executablePath(getpid()) else { throw IntegrationSetupError.missingCLI }
    let cli = URL(fileURLWithPath: path)
    var output: Any
    if args[0] == "profiles" {
        guard args.count == 1 || (args.count == 3 && args[1] == "--home") else { throw CLIError.usage }
        let home = try args.count == 3 ? absolute(args[2]) : FileManager.default.homeDirectoryForCurrentUser
        let installer = CodexHookInstaller(home: home, bundledCLI: cli, mailbox: root)
        output = try installer.profiles().map { ["name": $0.name, "path": $0.url.path] }
    } else {
        guard args.count == 4, ["status", "install", "remove"].contains(args[1]), args[2] == "--profile" else { throw CLIError.usage }
        let profile = try absolute(args[3])
        let installer = CodexHookInstaller(bundledCLI: cli, mailbox: root)
        let message: String?
        switch args[1] {
        case "install": message = try installer.installHooks(profile: profile, cli: cli, mailbox: root)
        case "remove": message = try installer.removeHooks(profile: profile)
        default: message = nil
        }
        let status = try installer.hookStatus(profile: profile)
        var record: [String: Any] = ["profile": profile.path, "hooksPath": profile.appendingPathComponent("hooks.json").path,
            "state": status.state.rawValue, "managedCount": status.managedCount, "detail": status.detail,
            "trustVerified": false, "qualifiedNativeCodexVersion": CodexRolloutActivityScanner.supportedCLIVersion]
        if let message { record["message"] = message }
        output = record
    }
    var data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10); FileHandle.standardOutput.write(data)
    return 0
}

func main() throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var root = Mailbox.defaultRoot
    if args.first == "--root", args.count > 2 { root = URL(fileURLWithPath: args[1]); args.removeFirst(2) }
    guard let command = args.first else { print(usage); return 0 }
    if ["--help", "-h", "help"].contains(command), args.count == 1 { print(usage); return 0 }
    if command == "profiles" || command == "hooks" { return try hookSetup(args, root: root) }
    let box = try Mailbox(root: root)
    switch command {
    case "lid-session":
        return LidSessionRunner.run(arguments: Array(args.dropFirst()), box: box)
    case "lid-session-watchdog":
        return LidSessionRunner.watchdog(arguments: Array(args.dropFirst()))
    case "lid-inspect":
        guard args.count == 1 else { throw CLIError.usage }
        return LidProbeRunner.inspect()
    case "lid-probe":
        return LidProbeRunner.run(arguments: Array(args.dropFirst()), box: box)
    case "lid-watchdog":
        return LidProbeRunner.watchdog(arguments: Array(args.dropFirst()))
    case "event":
        let event = try Mailbox.decoder().decode(JobEvent.self, from: readInput(limit: 65_536))
        try box.emit(event)
    case "receipt":
        let receipt = try Mailbox.decoder().decode(CheckpointReceipt.self, from: readInput(limit: 65_536))
        try box.write(receipt, folder: "receipts", key: receipt.requestID)
    case "checkpoint-ack":
        guard args.count >= 4, args[2] == "--files", args.count <= 35 else { throw CLIError.usage }
        let url = box.root.appendingPathComponent("requests").appendingPathComponent(Mailbox.key(args[1]) + ".json")
        let request = try box.read(CheckpointRequest.self, at: url)
        guard request.id == args[1] else { throw CLIError.usage }
        let paths = Array(args.dropFirst(3))
        for path in paths {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            guard path.hasPrefix("/"), a[.type] as? FileAttributeType == .typeRegular,
                  (a[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw CLIError.usage }
        }
        let receipt = CheckpointReceipt(requestID: request.id, jobID: request.jobID, source: request.source,
                                        session: request.session, savedPaths: paths,
                                        summary: "Application reported durable saved artifacts. Restore must be checked in the source application.", success: true)
        try box.write(receipt, folder: "receipts", key: receipt.requestID)
    case "status":
        var rows: [JobEvent] = []
        for url in try box.files(in: "events") {
            if let e = try? box.read(JobEvent.self, at: url) { rows.append(e) }
        }
        FileHandle.standardOutput.write(try Mailbox.encoder().encode(rows))
    case "run":
        guard let separator = args.firstIndex(of: "--"), separator + 1 < args.count else { throw CLIError.usage }
        let executable = args[separator + 1]
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = Array(args.dropFirst(separator + 1))
        task.standardInput = FileHandle.standardInput; task.standardOutput = FileHandle.standardOutput; task.standardError = FileHandle.standardError
        let id = UUID().uuidString
        var event = JobEvent(id: id, source: "Command", title: String(URL(fileURLWithPath: executable).lastPathComponent.prefix(120)), session: id, pid: getpid(), processBirth: ProcessIdentity.birth(getpid()))
        try task.run()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { if task.isRunning { kill(task.processIdentifier, SIGINT) } }
        terminate.setEventHandler { if task.isRunning { kill(task.processIdentifier, SIGTERM) } }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        func report(_ event: JobEvent) {
            do { try box.emit(event) }
            catch { FileHandle.standardError.write(Data("Longhaul could not report this job; sleep protection is unconfirmed. The command remains supervised.\n".utf8)) }
        }
        report(event)
        while task.isRunning {
            Thread.sleep(forTimeInterval: 1)
            event.sequence += 1
            if event.sequence % 10 == 0 { report(event) }
        }
        task.waitUntilExit()
        event.sequence += 1; event.phase = task.terminationReason == .uncaughtSignal ? .cancelled : task.terminationStatus == 0 ? .completed : .failed
        report(event)
        return task.terminationReason == .uncaughtSignal ? 128 + task.terminationStatus : task.terminationStatus
    case "watch-hook":
        guard args.count == 5, let pid = Int32(args[3]), let birth = UInt64(args[4]) else { throw CLIError.usage }
        let key = args[1], session = args[2]
        let path = box.root.appendingPathComponent("events").appendingPathComponent("." + Mailbox.key(key) + ".worker").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError.usage }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        defer { flock(fd, LOCK_UN) }
        // A missed terminal hook must not hold forever just because the app remains open.
        // New real hooks refresh evidenceAt. Worker heartbeats do not.
        // Long external work should use the explicit command/application integration.
        while ProcessIdentity.isSame(pid: pid, birth: birth) {
            guard let event = try? box.read(JobEvent.self, at: box.eventURL(key)),
                  let observed = event.evidenceAt, (-60...43_200).contains(Date().timeIntervalSince(observed)) else { break }
            guard (try? box.heartbeat(key: key, session: session)) == true else { break }
            Thread.sleep(forTimeInterval: 15)
        }
    case "hook":
        // Capture observation order before parsing or waiting on mailbox locks.
        let seq = Int(Date().timeIntervalSince1970 * 1_000_000)
        // The hook payload can contain prompts and tool output. Only select lifecycle fields are consumed.
        let bytes = try readInput(limit: 8_388_608)
        guard bytes.count <= 8_388_608, let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let session = payload["session_id"] as? String, let hook = payload["hook_event_name"] as? String else { throw CLIError.usage }
        let turn = payload["turn_id"] as? String ?? "session"
        let profile = args.count > 1 ? args[1] : "default"
        let source = "Codex (\(profile))"
        if hook == "SessionEnd" {
            for url in try box.files(in: "events") {
                guard var e = try? box.read(JobEvent.self, at: url), e.source == source,
                      e.id.hasPrefix(session + ":") else { continue }
                e.sequence = max(e.sequence + 1, seq)
                e.continuableHookStop = nil
                if !e.phase.isTerminal { e.phase = .cancelled }
                // Seal even a provisional Stop so a late tool cannot reopen it.
                try box.emitHook(e)
            }
            print("{}"); return 0
        }
        let agent = payload["agent_id"] as? String
        let id = session + ":" + turn + (agent.map { ":" + $0 } ?? "")
        let phase: JobPhase
        switch hook {
        case "Stop", "SessionEnd", "SubagentStop": phase = .completed
        case "Interrupt": phase = .cancelled
        case "PermissionRequest": phase = .needsInput
        case "PreToolUse": phase = .waiting
        case "SessionStart": print("{}"); return 0
        default: phase = .running
        }
        let owner = ProcessIdentity.codexAncestor()
        var event = JobEvent(id: id, source: source, title: "Codex task \(String(session.prefix(8)))", phase: phase,
                             sequence: seq, session: id, pid: owner?.pid, processBirth: owner?.birth, checkpointCapable: true)
        event.evidenceAt = Date()
        try box.emitHook(event, isStop: hook == "Stop" || hook == "SubagentStop")
        if !phase.isTerminal, let owner {
            let worker = Process(); worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            worker.arguments = ["--root", box.root.path, "watch-hook", source + ":" + id, id, String(owner.pid), String(owner.birth)]
            worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
            try worker.run()
        }
        let requests = try box.requests(for: event)
        if let request = requests.first, ["PreToolUse", "PostToolUse", "UserPromptSubmit"].contains(hook) {
            func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let ack = quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path) + " --root " + quote(box.root.path) + " checkpoint-ack " + quote(request.id) + " --files /absolute/path/to/saved-artifact /absolute/path/to/restart-record"
            let message = "Longhaul requests a recovery checkpoint before \(request.deadline.ISO8601Format()). Save current artifacts and a short restart record without committing, pushing or uploading. After the files are durably saved, run the following command with their actual absolute paths: \(ack). Never acknowledge unsaved progress. If saving is unsupported, say so; the request will expire as unconfirmed."
            let response: [String: Any] = ["hookSpecificOutput": ["hookEventName": hook, "additionalContext": message]]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: response))
        } else { print("{}") }
    default: throw CLIError.usage
    }
    return 0
}
enum CLIError: LocalizedError {
    case usage
    var errorDescription: String? { "Invalid arguments. Run longhaul --help for supported commands." }
}
do { exit(try main()) } catch {
    FileHandle.standardError.write(Data("Longhaul: \(error.localizedDescription)\n".utf8)); exit(1)
}
