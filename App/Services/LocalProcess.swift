import Foundation

struct LocalProcessResult: Sendable { let status: Int32; let output: String }

actor LocalProcess {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) async throws -> LocalProcessResult {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("Longhaul-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning && ContinuousClock.now < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ProcessFailure.timeout
        }
        process.waitUntilExit(); try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: log); defer { try? reader.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > 16_384 { try reader.seek(toOffset: size - 16_384) }
        return LocalProcessResult(status: process.terminationStatus, output: String(decoding: try reader.read(upToCount: 16_384) ?? Data(), as: UTF8.self))
    }
    enum ProcessFailure: LocalizedError {
        case timeout
        var errorDescription: String? { "The integration did not finish in time. Longhaul stopped its setup process." }
    }
}
