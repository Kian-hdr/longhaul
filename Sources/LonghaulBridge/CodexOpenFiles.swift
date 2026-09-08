import Foundation
import Darwin
import CLonghaulSupport

public struct CodexNativeHost: Codable, Sendable, Equatable {
    public let appPID: Int32
    public let appBirth: UInt64
    public let codexExecutableURL: URL
    public init(appPID: Int32, appBirth: UInt64, codexExecutableURL: URL) {
        self.appPID = appPID; self.appBirth = appBirth; self.codexExecutableURL = codexExecutableURL
    }
}
public struct CodexOpenFilesIssue: Codable, Sendable, Equatable {
    public let kind: String
    public let pid: Int32?
    public let code: Int32?
    public init(kind: String, pid: Int32? = nil, code: Int32? = nil) { self.kind = kind; self.pid = pid; self.code = code }
}
public struct CodexOpenFile: Codable, Sendable, Equatable {
    public var pid: Int32
    public var processBirth: UInt64
    public var appPID: Int32?
    public var appBirth: UInt64?
    public var executablePath: String
    public var fd: Int32
    public var path: String
    public var device: UInt32
    public var inode: UInt64
    public var ownerUID: UInt32
    public var mode: UInt16
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var openFlags: UInt32
    public var isWritable: Bool
}
public struct CodexOpenFilesSnapshot: Codable, Sendable, Equatable {
    public var observedAt: Double
    public var complete: Bool
    public var issues: [CodexOpenFilesIssue]
    public var processCount: Int
    public var matchedProcessCount: Int
    public var files: [CodexOpenFile]
}

/// Read-only ownership evidence. Open descriptors establish process/file linkage,
/// not active work; a separate bounded lifecycle parser must determine activity.
public enum CodexOpenFiles {
    public struct Limits: Sendable {
        public var maximumProcesses: Int
        public var maximumFDsPerProcess: Int
        public var maximumFilesPerProcess: Int
        public var maximumFiles: Int
        public var maximumHosts: Int
        public var processBudgetMilliseconds: Int
        public var totalBudgetSeconds: Double
        public init(maximumProcesses: Int = 2048, maximumFDsPerProcess: Int = 4096,
                    maximumFilesPerProcess: Int = 512, maximumFiles: Int = 512,
                    maximumHosts: Int = 16, processBudgetMilliseconds: Int = 250, totalBudgetSeconds: Double = 2) {
            self.maximumProcesses = maximumProcesses; self.maximumFDsPerProcess = maximumFDsPerProcess
            self.maximumFilesPerProcess = maximumFilesPerProcess; self.maximumFiles = maximumFiles
            self.maximumHosts = maximumHosts; self.processBudgetMilliseconds = processBudgetMilliseconds
            self.totalBudgetSeconds = totalBudgetSeconds
        }
        var valid: Bool {
            (1...8192).contains(maximumProcesses) && (1...16384).contains(maximumFDsPerProcess) &&
                (1...2048).contains(maximumFilesPerProcess) && (1...2048).contains(maximumFiles) &&
                (1...64).contains(maximumHosts) && (1...2000).contains(processBudgetMilliseconds) &&
                totalBudgetSeconds.isFinite && (0.01...10).contains(totalBudgetSeconds)
        }
    }
    struct ProcessMetadata: Equatable {
        let pid: Int32, parentPID: Int32
        let birth: UInt64
        let executablePath: String
    }
    static func process(_ pid: Int32) -> (ProcessMetadata?, Int32) {
        var value = longhaul_process_metadata()
        let error = longhaul_inspect_process(pid, &value)
        guard error == 0 else { return (nil, error) }
        return (.init(pid: value.pid, parentPID: value.parent_pid, birth: value.birth,
                      executablePath: string(&value.executable_path)), 0)
    }
    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
    private static func issues(_ result: longhaul_discovery_result, pid: Int32?) -> [CodexOpenFilesIssue] {
        [(UInt32(LONGHAUL_DISCOVERY_UNAVAILABLE), "unavailable"),
         (UInt32(LONGHAUL_DISCOVERY_TRUNCATED), "limitReached"),
         (UInt32(LONGHAUL_DISCOVERY_CHANGED), "identityChanged"),
         (UInt32(LONGHAUL_DISCOVERY_TIMED_OUT), "timeBudgetReached"),
         (UInt32(LONGHAUL_DISCOVERY_ITEM_ERROR), "descriptorUnavailable")]
            .compactMap { flag, label in result.status & flag == 0 ? nil : .init(kind: label, pid: pid, code: result.error_code == 0 ? nil : result.error_code) }
    }
    /// Generic metadata seam for tests and explicit process inspection. It does
    /// not label a process native or read any open file's contents.
    public static func inspectProcess(pid: Int32, expectedBirth: UInt64, limits: Limits = .init()) -> CodexOpenFilesSnapshot {
        let start = LidQualificationIO.monotonicSeconds()
        var snapshot = CodexOpenFilesSnapshot(observedAt: start, complete: false, issues: [], processCount: 1, matchedProcessCount: 0, files: [])
        guard limits.valid else { snapshot.issues = [.init(kind: "invalidLimits")]; return snapshot }
        let (metadata, error) = process(pid)
        guard let metadata, metadata.birth == expectedBirth else {
            snapshot.issues = [.init(kind: "processUnavailableOrChanged", pid: pid, code: error)]; return snapshot
        }
        var values = [longhaul_open_file_metadata](repeating: longhaul_open_file_metadata(), count: limits.maximumFilesPerProcess)
        let result = values.withUnsafeMutableBufferPointer {
            longhaul_process_open_files(pid, expectedBirth, UInt32(limits.maximumFDsPerProcess), $0.baseAddress,
                                        UInt32($0.count), UInt32(limits.processBudgetMilliseconds))
        }
        snapshot.issues = issues(result, pid: pid)
        let (after, afterError) = process(pid)
        guard after == metadata else {
            snapshot.issues.append(.init(kind: "processUnavailableOrChanged", pid: pid, code: afterError)); return snapshot
        }
        for index in 0..<Int(result.count) {
            var value = values[index]
            snapshot.files.append(.init(pid: pid, processBirth: expectedBirth, appPID: nil, appBirth: nil,
                executablePath: metadata.executablePath, fd: value.fd, path: string(&value.path), device: value.device,
                inode: value.inode, ownerUID: value.owner_uid, mode: value.mode, size: value.size,
                modifiedSeconds: value.modified_seconds, modifiedNanoseconds: value.modified_nanoseconds,
                openFlags: value.open_flags, isWritable: value.writable != 0))
        }
        snapshot.complete = snapshot.issues.isEmpty
        return snapshot
    }
    /// Pure path shape check. The caller must supply canonical profile roots.
    public static func isRolloutPath(_ path: String, profileRoots: [String]) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 4096,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return false }
        return profileRoots.contains { root in
            root.hasPrefix("/") && !root.contains("\0") && root != "/" &&
                URL(fileURLWithPath: root).standardizedFileURL.path == root && path.hasPrefix(root + "/sessions/")
        }
    }
    static func nativeExecutableShape(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.standardizedFileURL.path == url.path,
              url.lastPathComponent == "codex" else { return false }
        let resources = url.deletingLastPathComponent(), contents = resources.deletingLastPathComponent()
        return resources.lastPathComponent == "Resources" && contents.lastPathComponent == "Contents" &&
            contents.deletingLastPathComponent().pathExtension == "app"
    }
    /// Bounded ancestry walk with explicit cycle/reuse rejection. Lookup is
    /// injected only for deterministic tests; discovery uses live libproc data.
    static func ancestryReaches(_ candidate: ProcessMetadata, host: CodexNativeHost,
                               lookup: (Int32) -> ProcessMetadata?) -> Bool {
        guard candidate.pid != host.appPID, host.appPID > 1, host.appBirth != 0 else { return false }
        var seen: Set<Int32> = [candidate.pid], current = candidate
        for _ in 0..<16 {
            let parent = current.parentPID
            guard parent > 1, !seen.contains(parent), let value = lookup(parent) else { return false }
            seen.insert(parent)
            if parent == host.appPID { return value.birth == host.appBirth }
            current = value
        }
        return false
    }
    private static func liveAncestry(_ candidate: ProcessMetadata, host: CodexNativeHost) -> Bool {
        var observed: [ProcessMetadata] = []
        let matches = ancestryReaches(candidate, host: host) { pid in
            guard let item = process(pid).0 else { return nil }
            observed.append(item); return item
        }
        return matches && observed.allSatisfy { process($0.pid).0 == $0 } && process(candidate.pid).0 == candidate
    }
    public static func discover(nativeHosts: [CodexNativeHost], profileRoots: [String], limits: Limits = .init()) -> CodexOpenFilesSnapshot {
        let start = LidQualificationIO.monotonicSeconds()
        var snapshot = CodexOpenFilesSnapshot(observedAt: start, complete: false, issues: [], processCount: 0, matchedProcessCount: 0, files: [])
        guard limits.valid, nativeHosts.count <= limits.maximumHosts, profileRoots.count <= 16, !profileRoots.isEmpty,
              profileRoots.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") && $0.utf8.count < 4096 }) else {
            snapshot.issues = [.init(kind: "invalidLimitsOrProfiles")]; return snapshot
        }
        let roots = profileRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        var hosts: [CodexNativeHost] = []
        for host in nativeHosts {
            let url = host.codexExecutableURL
            let appURL = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard nativeExecutableShape(url), url.resolvingSymlinksInPath().path == url.path,
                  Bundle(url: appURL)?.bundleIdentifier == "com.openai.codex",
                  ProcessIdentity.isSame(pid: host.appPID, birth: host.appBirth) else {
                snapshot.issues.append(.init(kind: "nativeHostUnavailable", pid: host.appPID)); continue
            }
            hosts.append(host)
        }
        guard !hosts.isEmpty else { snapshot.issues.append(.init(kind: "noVerifiedNativeHost")); return snapshot }
        var pids = [Int32](repeating: 0, count: limits.maximumProcesses)
        let listed = pids.withUnsafeMutableBufferPointer { longhaul_user_processes($0.baseAddress, UInt32($0.count)) }
        snapshot.issues += issues(listed, pid: nil)
        var seen: Set<Int32> = []
        for pid in pids.prefix(Int(listed.count)) where pid > 1 && seen.insert(pid).inserted {
            if LidQualificationIO.monotonicSeconds() - start > limits.totalBudgetSeconds {
                snapshot.issues.append(.init(kind: "timeBudgetReached")); break
            }
            snapshot.processCount += 1
            let (candidate, error) = process(pid)
            guard let candidate else {
                if snapshot.issues.count < 128 { snapshot.issues.append(.init(kind: "processUnavailable", pid: pid, code: error)) }
                continue
            }
            let possible = hosts.filter { $0.codexExecutableURL.path == candidate.executablePath }
            guard !possible.isEmpty else { continue }
            guard let host = possible.first(where: { liveAncestry(candidate, host: $0) }) else {
                // Same bundled binary can be launched manually or by a diagnostic.
                // Such processes are deliberately outside native-host coverage.
                continue
            }
            snapshot.matchedProcessCount += 1
            let result = inspectProcess(pid: pid, expectedBirth: candidate.birth, limits: limits)
            snapshot.issues += result.issues
            guard liveAncestry(candidate, host: host) else {
                snapshot.issues.append(.init(kind: "nativeAncestryChanged", pid: pid)); continue
            }
            for var file in result.files where file.isWritable && file.ownerUID == getuid() && isRolloutPath(file.path, profileRoots: roots) {
                if snapshot.files.count >= limits.maximumFiles {
                    snapshot.issues.append(.init(kind: "fileLimitReached", pid: pid)); break
                }
                file.appPID = host.appPID; file.appBirth = host.appBirth
                snapshot.files.append(file)
            }
        }
        snapshot.files.sort { $0.pid == $1.pid ? $0.fd < $1.fd : $0.pid < $1.pid }
        snapshot.complete = snapshot.issues.isEmpty
        return snapshot
    }
}
