import Foundation
import Darwin

/// Checked, user-owned filesystem operations shared by integration setup surfaces.
public enum IntegrationFileAccess {
    public static let maximumConfigBytes = 1_048_576
    public struct FileSnapshot: Equatable {
        public let bytes: Data
        let identity: FileIdentity
    }
    public struct FileIdentity: Equatable {
        let device: Int32, inode: UInt64, mode: UInt16, links: UInt16, owner: UInt32
        let size: Int64, modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; links = value.st_nlink; owner = value.st_uid
            size = value.st_size; modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    public struct LinkSnapshot: Equatable { let identity: FileIdentity; public let destination: String? }
    public static func safeRegular(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1 && value.st_mode & 0o022 == 0
    }
    public static func read(_ directory: Int32, name: String) throws -> FileSnapshot? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw IntegrationSetupError.unsafeProfile }
        defer { close(descriptor) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, safeRegular(before), before.st_size >= 0, before.st_size <= maximumConfigBytes else { throw IntegrationSetupError.unsafeProfile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: maximumConfigBytes + 1) ?? Data()
        guard fstat(descriptor, &after) == 0, FileIdentity(before) == FileIdentity(after), bytes.count == before.st_size else { throw IntegrationSetupError.changedDuringSetup }
        return .init(bytes: bytes, identity: .init(before))
    }
    public static func linkSnapshot(_ directory: Int32, name: String) throws -> LinkSnapshot? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }; throw IntegrationSetupError.unsafeProfile
        }
        guard info.st_uid == getuid() else { throw IntegrationSetupError.unsafeProfile }
        guard info.st_mode & S_IFMT == S_IFLNK else { return .init(identity: .init(info), destination: nil) }
        var bytes = [CChar](repeating: 0, count: 4_097)
        let count = readlinkat(directory, name, &bytes, bytes.count - 1)
        guard count >= 0, count < bytes.count - 1 else { throw IntegrationSetupError.unsafeProfile }
        var after = stat()
        guard fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(info) == FileIdentity(after) else { throw IntegrationSetupError.changedDuringSetup }
        let text = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .init(identity: .init(info), destination: text)
    }
    public static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"), !url.pathComponents.contains("..") else { throw IntegrationSetupError.unsafeProfile }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            for component in url.pathComponents.dropFirst() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { throw posixError() }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { if errno == ENOENT { throw IntegrationSetupError.notFound }; throw IntegrationSetupError.unsafeProfile }
                close(descriptor); descriptor = next
            }
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o022 == 0 else { throw IntegrationSetupError.unsafeProfile }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    public static func existingDirectory(_ url: URL) throws -> Int32? {
        do { return try directory(url) } catch IntegrationSetupError.notFound { return nil }
    }
    public static func sameDirectory(_ url: URL, descriptor: Int32) throws -> Bool {
        let current = try directory(url); defer { close(current) }
        var a = stat(), b = stat()
        guard fstat(descriptor, &a) == 0, fstat(current, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    public static func lock(_ directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, ".longhaul-setup.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw IntegrationSetupError.unsafeProfile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, safeRegular(info), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw IntegrationSetupError.changedDuringSetup
        }
        return descriptor
    }
    public static func writeNew(_ bytes: Data, directory: Int32, name: String) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var completed = false
        defer { close(descriptor); if !completed { _ = unlinkat(directory, name, 0) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard fsync(directory) == 0 else { throw posixError() }
        completed = true
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

public enum IntegrationSetupError: LocalizedError {
        case missingCLI, unsafeProfile, invalidConfig, modifiedHooks, changedDuringSetup, missingBlender, blenderFailed(String), commandExists, notFound
        public var errorDescription: String? {
            switch self {
            case .missingCLI: "Longhaul's bundled command tool is missing. Reinstall the app."
            case .unsafeProfile: "The integration location is unsafe: a symlink, shared-write location, unexpected file type or ownership was found. No configuration changes were made."
            case .invalidConfig: "Existing hooks are malformed or exceed the supported size. No configuration changes were made."
            case .modifiedHooks: "Modified or combined Longhaul hook entries need manual review in Codex /hooks. No hook definitions were changed."
            case .changedDuringSetup: "The integration changed during setup or another setup is running. Retry after the other writer finishes."
            case .missingBlender: "Blender was not found in Applications. Install Blender 5 or later first."
            case .blenderFailed(let output): "Blender setup failed: \(output.suffix(2000))"
            case .commandExists: "A different command already exists at ~/.local/bin/longhaul. It was left unchanged."
            case .notFound: "The integration directory does not exist."
            }
        }
    }
