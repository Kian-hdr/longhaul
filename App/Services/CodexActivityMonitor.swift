import Foundation
import LonghaulCore
import LonghaulBridge

struct CodexActivityBatch {
    var events: [JobEvent] = []
    var expiredIDs: [String] = []
    var removedIDs: [String] = []
    var retiredObservations: [(key: String, session: String)] = []
    var status = "Native activity monitoring is off."
}

/// Confined to RuntimeIO. Reads only files that current native hosts have open
/// for writing. No session content or file paths are persisted in Longhaul.
final class CodexActivityMonitor {
    private var scanners: [String: CodexRolloutActivityScanner] = [:]
    private var tracked: [String: JobEvent] = [:]
    private var trackedPaths: [String: String] = [:]
    private var expired = Set<String>()
    private var sequence = 0
    private var rotation = 0
    private var lastPoll = Date.distantPast
    private var lastStatus = "Checking native Codex activity…"
    private let discover: ([CodexNativeHost], [String]) -> CodexOpenFilesSnapshot
    init(discover: @escaping ([CodexNativeHost], [String]) -> CodexOpenFilesSnapshot = {
        CodexOpenFiles.discover(nativeHosts: $0, profileRoots: $1, limits: .init(maximumFiles: 64))
    }) { self.discover = discover }

    func poll(profiles: [URL], hosts: [CodexNativeHost], enabled: Bool,
              hooks: [String: (event: JobEvent, modified: Date)], now: Date) -> CodexActivityBatch {
        var result = CodexActivityBatch()
        guard enabled else {
            result.removedIDs = Array(tracked.keys)
            tracked.removeAll(); trackedPaths.removeAll(); expired.removeAll(); scanners.removeAll(); lastPoll = .distantPast
            return result
        }
        guard now.timeIntervalSince(lastPoll) >= 2 || now < lastPoll else {
            result.status = lastStatus; return result
        }
        lastPoll = now
        let discovered = discover(hosts, profiles.map(\.path))
        // Multiple writable descriptors for one inode do not create duplicate
        // jobs. Multiple possible writer processes are ambiguous and excluded.
        let grouped = Dictionary(grouping: discovered.files, by: \.path)
        let files = grouped.compactMap { _, values in
            Set(values.map { "\($0.pid):\($0.processBirth)" }).count == 1 ? values.first : nil
        }.sorted { $0.path < $1.path }
        let visiblePaths = Set(files.map(\.path))
        for key in scanners.keys where !visiblePaths.contains(key) && scanners[key]?.hasLatchedFailure == false { scanners.removeValue(forKey: key) }
        for key in tracked.keys.filter({ tracked[$0]?.phase.isTerminal == true && !visiblePaths.contains(trackedPaths[$0] ?? "") }) {
            tracked.removeValue(forKey: key); trackedPaths.removeValue(forKey: key); expired.remove(key)
        }
        var observed = Set<String>(), processedPaths = Set<String>(), pendingPaths = Set<String>()
        // Bound initial catch-up across many loaded tasks. Existing valid jobs
        // retain their ordinary lease until their round-robin observation.
        let count = min(files.count, 8)
        var unknown = !discovered.complete || grouped.count != files.count
        var catchingUp = false
        if !files.isEmpty {
            for offset in 0..<count {
                let file = files[(rotation + offset) % files.count]
                processedPaths.insert(file.path)
                guard let profile = profiles.first(where: { file.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/sessions/") }) else { unknown = true; continue }
                guard scanners[file.path] != nil || scanners.count < 128 else { unknown = true; continue }
                var scanner = scanners[file.path] ?? CodexRolloutActivityScanner()
                let activity = scanner.poll(url: URL(fileURLWithPath: file.path),
                                            writer: CodexRolloutWriter(pid: file.pid, birth: file.processBirth),
                                            expectedDevice: UInt64(file.device), expectedInode: file.inode, now: Date())
                scanners[file.path] = scanner
                guard let appPID = file.appPID, let appBirth = file.appBirth,
                      ProcessIdentity.isSame(pid: file.pid, birth: file.processBirth),
                      ProcessIdentity.isSame(pid: appPID, birth: appBirth) else { unknown = true; continue }
                if activity.state == .catchingUp {
                    catchingUp = true; pendingPaths.insert(file.path); continue
                }
                guard activity.state != .unknown, let thread = activity.threadID, let turn = activity.turnID,
                      file.path.hasSuffix(thread + ".jsonl") else { unknown = true; continue }
                let id = thread + ":" + turn
                let source = "Codex activity (\(profile.lastPathComponent))"
                let key = source + ":" + id
                let hookPrefix = "Codex (\(profile.lastPathComponent)):" + thread + ":"
                for (oldKey, oldHook) in hooks where oldKey.hasPrefix(hookPrefix) {
                    let oldTurn = String(oldKey.dropFirst(hookPrefix.count))
                    if oldTurn != turn && scanner.hasObservedTerminal(turnID: oldTurn) {
                        result.retiredObservations.append((oldKey, oldHook.event.session))
                    }
                }
                for previous in trackedPaths.keys.filter({ trackedPaths[$0] == file.path && $0 != key }) {
                    result.removedIDs.append(previous); tracked.removeValue(forKey: previous); trackedPaths.removeValue(forKey: previous); expired.remove(previous)
                }
                let hookKey = "Codex (\(profile.lastPathComponent)):" + id
                let hook = hooks[hookKey]
                guard CodexActivityPreference.useActivity(hook: hook?.event,
                    hookIsFresh: hook.map { abs(now.timeIntervalSince($0.modified)) < 120 } ?? false,
                    nativeIsTerminal: activity.state == .completed || activity.state == .cancelled,
                    hookOwnerMatches: hook.map { $0.event.pid == file.pid && $0.event.processBirth == file.processBirth && ProcessIdentity.isSame(pid: file.pid, birth: file.processBirth) } ?? true) else {
                    if tracked.removeValue(forKey: key) != nil { result.removedIDs.append(key); trackedPaths.removeValue(forKey: key); expired.remove(key) }
                    continue
                }
                if let hook {
                    if activity.state == .completed || activity.state == .cancelled {
                        result.retiredObservations.append((hookKey, hook.event.session))
                    } else if !hook.event.phase.isTerminal { result.removedIDs.append(hookKey) }
                }
                let phase: JobPhase = switch activity.state {
                case .running: .running
                case .completed: .completed
                case .cancelled: .cancelled
                default: .needsInput
                }
                sequence += 1
                var event = JobEvent(id: id, source: source, title: "Codex task " + String(thread.prefix(8)),
                                     phase: phase, sequence: sequence, session: id,
                                     pid: file.pid, processBirth: file.processBirth)
                event.evidenceAt = activity.updatedAt
                guard event.isValid else { unknown = true; continue }
                if !phase.isTerminal || tracked[key]?.phase != phase || tracked[key]?.evidenceAt != event.evidenceAt {
                    result.events.append(event); tracked[key] = event
                }
                trackedPaths[key] = file.path; observed.insert(key); expired.remove(key)
            }
            rotation = (rotation + count) % files.count
        }
        // Lose contact immediately for a missing writer. A parse failure on a
        // processed file also cannot keep refreshing its prior running turn.
        // A concurrently appended partial record does not renew contact, but
        // retains the existing bounded policy lease until catch-up or expiry.
        for (key, event) in tracked where !event.phase.isTerminal && !observed.contains(key) {
            let matchingFile = files.first { $0.path == trackedPaths[key] && $0.pid == event.pid && $0.processBirth == event.processBirth }
            if matchingFile == nil || matchingFile.map({ processedPaths.contains($0.path) && !pendingPaths.contains($0.path) }) == true {
                result.expiredIDs.append(key); expired.insert(key)
            }
        }
        let running = tracked.values.filter { !$0.phase.isTerminal && !expired.contains($0.source + ":" + $0.id) }.count
        result.status = unknown ? "Some native activity could not be verified; check live jobs below." :
            catchingUp ? "Reading native task lifecycle records…" :
            running > 0 ? "Native lifecycle reporting is active for \(running) \(running == 1 ? "task" : "tasks")." :
            "No additional active native tasks found. Hooks handle tasks that already report."
        lastStatus = result.status
        return result
    }
}
