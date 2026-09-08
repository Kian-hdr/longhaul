import Foundation
import CLonghaulSupport

public enum ProcessIdentity {
    public static func birth(_ pid: Int32) -> UInt64 { longhaul_process_birth(pid) }
    public static func isSame(pid: Int32, birth: UInt64) -> Bool { birth != 0 && Self.birth(pid) == birth }
    /// Kernel-reported executable path, including when launched through PATH or a symlink.
    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard longhaul_process_path(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static func codexAncestor() -> (pid: Int32, birth: UInt64)? {
        var pid = getppid()
        for _ in 0..<12 {
            guard pid > 1 else { break }
            if let path = executablePath(pid) {
                if URL(fileURLWithPath: path).lastPathComponent == "codex" {
                    let b = birth(pid); if b != 0 { return (pid, b) }
                }
            }
            pid = longhaul_parent_pid(pid)
        }
        return nil
    }
}
