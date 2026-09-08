import Testing
import Foundation
import Darwin
@testable import LonghaulBridge

@Test func openFileDiscoverySeparatesReadAndWriteDescriptors() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("rollout-fixture.jsonl").path
    let writer = open(path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
    #expect(writer >= 0); guard writer >= 0 else { return }; defer { close(writer) }
    let reader = open(path, O_RDONLY | O_CLOEXEC)
    #expect(reader >= 0); guard reader >= 0 else { return }; defer { close(reader) }
    let both = open(path, O_RDWR | O_CLOEXEC)
    #expect(both >= 0); guard both >= 0 else { return }; defer { close(both) }
    var info = stat(); #expect(fstat(writer, &info) == 0)
    let result = CodexOpenFiles.inspectProcess(pid: getpid(), expectedBirth: ProcessIdentity.birth(getpid()))
    let writeMetadata = try #require(result.files.first { $0.fd == writer })
    let readMetadata = try #require(result.files.first { $0.fd == reader })
    let bothMetadata = try #require(result.files.first { $0.fd == both })
    #expect(writeMetadata.isWritable)
    #expect(!readMetadata.isWritable)
    #expect(bothMetadata.isWritable)
    #expect(writeMetadata.inode == UInt64(info.st_ino))
    #expect(writeMetadata.device == UInt32(bitPattern: info.st_dev))
    #expect(writeMetadata.ownerUID == getuid())
    var actualPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    #expect(fcntl(writer, F_GETPATH, &actualPath) == 0)
    #expect(writeMetadata.path == String(decoding: actualPath.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    #expect(writeMetadata.processBirth == ProcessIdentity.birth(getpid()))
    #expect(writeMetadata.appPID == nil) // generic observation is never labeled native.
    // Metadata contains no file bytes, prompts, environment or credential fields.
    let encoded = try JSONEncoder().encode(result)
    #expect(!encoded.isEmpty)
}

@Test func openFileDiscoveryRejectsWrongBirthAndBoundsOutput() throws {
    let birth = ProcessIdentity.birth(getpid())
    let wrong = CodexOpenFiles.inspectProcess(pid: getpid(), expectedBirth: birth + 1)
    #expect(!wrong.complete)
    #expect(wrong.files.isEmpty)
    #expect(!wrong.issues.isEmpty)
    let bounded = CodexOpenFiles.inspectProcess(pid: getpid(), expectedBirth: birth,
        limits: .init(maximumFDsPerProcess: 1, maximumFilesPerProcess: 1))
    #expect(!bounded.complete)
    #expect(bounded.files.count <= 1)
    #expect(bounded.issues.contains { $0.kind == "limitReached" })
    let invalid = CodexOpenFiles.inspectProcess(pid: getpid(), expectedBirth: birth,
        limits: .init(maximumFDsPerProcess: 0))
    #expect(!invalid.complete && invalid.files.isEmpty)
    let absent = CodexOpenFiles.inspectProcess(pid: Int32.max, expectedBirth: birth)
    #expect(!absent.complete && absent.files.isEmpty)
}

@Test func rolloutDiscoveryConfinementAndNativeShape() {
    let roots = ["/private/fixture/.codex", "/private/fixture/.codex-work"]
    #expect(CodexOpenFiles.isRolloutPath("/private/fixture/.codex/sessions/2026/09/08/rollout-one.jsonl", profileRoots: roots))
    #expect(CodexOpenFiles.isRolloutPath("/private/fixture/.codex-work/sessions/2026/09/08/rollout-two.jsonl", profileRoots: roots))
    for path in ["/private/fixture/.codex-other/sessions/rollout-x.jsonl", "/private/fixture/.codex/auth.json",
                 "/private/fixture/.codex/sessions/../rollout-x.jsonl", "/private/fixture/.codex/sessions/rollout-x.txt",
                 "/private/fixture/.codex/sessions/name.jsonl", "relative/sessions/rollout-x.jsonl"] {
        #expect(!CodexOpenFiles.isRolloutPath(path, profileRoots: roots))
    }
    #expect(CodexOpenFiles.nativeExecutableShape(URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/codex")))
    #expect(!CodexOpenFiles.nativeExecutableShape(URL(fileURLWithPath: "/usr/local/bin/codex")))
    #expect(!CodexOpenFiles.nativeExecutableShape(URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/codex")))
}

@Test func nativeAncestryRejectsManualLaunchCycleAndReusedHost() {
    typealias P = CodexOpenFiles.ProcessMetadata
    let host = CodexNativeHost(appPID: 20, appBirth: 200, codexExecutableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/codex"))
    let candidate = P(pid: 30, parentPID: 25, birth: 300, executablePath: host.codexExecutableURL.path)
    let parent = P(pid: 25, parentPID: 20, birth: 250, executablePath: "/fixture/helper")
    let native = P(pid: 20, parentPID: 1, birth: 200, executablePath: "/fixture/app")
    let chain = [25: parent, 20: native]
    #expect(CodexOpenFiles.ancestryReaches(candidate, host: host, lookup: { chain[Int($0)] }))
    let reused = P(pid: 20, parentPID: 1, birth: 201, executablePath: "/fixture/app")
    #expect(!CodexOpenFiles.ancestryReaches(candidate, host: host, lookup: { $0 == 20 ? reused : parent }))
    let cycle = P(pid: 25, parentPID: 30, birth: 250, executablePath: "/fixture/helper")
    #expect(!CodexOpenFiles.ancestryReaches(candidate, host: host, lookup: { $0 == 25 ? cycle : candidate }))
    #expect(!CodexOpenFiles.ancestryReaches(candidate, host: host, lookup: { _ in nil }))
    let direct = P(pid: 30, parentPID: 1, birth: 300, executablePath: host.codexExecutableURL.path)
    #expect(!CodexOpenFiles.ancestryReaches(direct, host: host, lookup: { _ in native }))
}

@Test func discoveryWithoutVerifiedNativeHostIsExplicitlyUnavailable() {
    let result = CodexOpenFiles.discover(nativeHosts: [], profileRoots: ["/private/fixture/.codex"])
    #expect(!result.complete && result.files.isEmpty)
    #expect(result.issues.contains { $0.kind == "noVerifiedNativeHost" })
}
