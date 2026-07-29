import Darwin
import Foundation

public struct RuntimePinnedLaunchHooks: Sendable {
    public let beforeFinalIdentityValidation: @Sendable () throws -> Void

    public init(
        beforeFinalIdentityValidation: @escaping @Sendable () throws -> Void = {}
    ) {
        self.beforeFinalIdentityValidation = beforeFinalIdentityValidation
    }
}

/// Pins the executable's parent directory and launches only its relative
/// basename. macOS 13 does not provide fexecve, so the final path identity
/// check and posix_spawn call are deliberately kept in this helper.
struct RuntimePinnedExecutable {
    let directoryDescriptor: Int32
    let basename: String
    let displayPath: String
    let expectedUserID: uid_t
    let expectedIdentity: RuntimeExecutableIdentity?

    init(
        url: URL,
        expectedUserID: uid_t = geteuid(),
        expectedIdentity: RuntimeExecutableIdentity? = nil
    ) throws {
        let executable = url.standardizedFileURL
        try Self.validatePathTraversal(to: executable, expectedUserID: expectedUserID)
        let directory = executable.deletingLastPathComponent()
        let basename = executable.lastPathComponent
        guard !basename.isEmpty,
              basename != ".",
              basename != "..",
              !basename.contains("/"),
              directory.appendingPathComponent(basename).standardizedFileURL == executable
        else {
            throw RuntimeInstallerError.untrustedStoreItem("invalid runtime executable path")
        }

        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "pin runtime executable parent directory",
                path: directory.path
            )
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == expectedUserID,
                  info.st_mode & 0o022 == 0
            else {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "runtime executable parent directory is not private and user-owned"
                )
            }
            self.directoryDescriptor = descriptor
            self.basename = basename
            displayPath = executable.path
            self.expectedUserID = expectedUserID
            self.expectedIdentity = expectedIdentity
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func close() {
        Darwin.close(directoryDescriptor)
    }

    private static func validatePathTraversal(to executable: URL, expectedUserID: uid_t) throws {
        let components = executable.pathComponents.dropFirst().dropLast()
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var enteredUserBoundary = false
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "inspect runtime executable path component",
                    path: current.path
                )
            }
            if info.st_uid == expectedUserID { enteredUserBoundary = true }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                if enteredUserBoundary {
                    throw RuntimeInstallerError.untrustedStoreItem(
                        "runtime executable path contains a symbolic link at \(current.path)"
                    )
                }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "runtime executable path component is not a directory at \(current.path)"
                )
            }
            if enteredUserBoundary, info.st_mode & 0o022 != 0 {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "runtime executable path component is not private at \(current.path)"
                )
            }
        }
    }

    func addDirectoryActions(to actions: inout posix_spawn_file_actions_t?) throws {
        try checkPOSIX(
            posix_spawn_file_actions_addfchdir_np(&actions, directoryDescriptor),
            operation: "pin child working directory"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&actions, directoryDescriptor),
            operation: "close child pinned-directory descriptor"
        )
    }

    func spawn(
        pid: inout pid_t,
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        argv: inout [UnsafeMutablePointer<CChar>?],
        envp: inout [UnsafeMutablePointer<CChar>?],
        hooks: RuntimePinnedLaunchHooks
    ) throws -> Int32 {
        try hooks.beforeFinalIdentityValidation()
        try validateCurrentFile()
        return posix_spawn(&pid, basename, &actions, &attributes, &argv, &envp)
    }

    func validateCurrentFile() throws {
        var info = stat()
        let result = basename.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedUserID,
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              info.st_mode & 0o100 != 0
        else {
            throw RuntimeInstallerError.untrustedStoreItem(
                "runtime executable is unsafe at the launch boundary"
            )
        }
        if let expectedIdentity {
            guard info.st_size == expectedIdentity.size,
                  UInt64(info.st_dev) == expectedIdentity.device,
                  UInt64(info.st_ino) == expectedIdentity.inode
            else {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "runtime executable identity changed at the launch boundary"
                )
            }
        }
    }

    private func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw RuntimeInstallerError.processFailure(
                "could not \(operation): \(String(cString: strerror(result)))"
            )
        }
    }
}

public final class RuntimeStoreLease: @unchecked Sendable {
    public enum Mode: Sendable {
        case sharedExecution
        case exclusiveMutation
    }

    public final class Token: @unchecked Sendable {
        public let descriptor: Int32
        private let lock = NSLock()
        private var released = false

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            release()
        }

        public func release() {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            lock.unlock()
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    public let rootURL: URL
    public var lockURL: URL { rootURL.appendingPathComponent(".execution-lease") }
    private static let creationLock = NSLock()

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func acquire(_ mode: Mode) throws -> Token {
        try ensurePrivateRootExists()
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "open runtime store lease",
                path: lockURL.path
            )
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  info.st_nlink == 1
            else {
                throw RuntimeInstallerError.untrustedStoreItem("runtime store lease is not a private regular file")
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "protect runtime store lease",
                    path: lockURL.path
                )
            }
            let operation = mode == .sharedExecution ? LOCK_SH : LOCK_EX
            while flock(descriptor, operation) != 0 {
                if errno == EINTR { continue }
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "acquire runtime store lease",
                    path: lockURL.path
                )
            }
            return Token(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func ensurePrivateRootExists() throws {
        Self.creationLock.lock()
        defer { Self.creationLock.unlock() }
        let standardized = rootURL.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var enteredUserBoundary = false
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if info.st_uid == geteuid() { enteredUserBoundary = true }
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    if enteredUserBoundary {
                        throw RuntimeInstallerError.untrustedStoreItem(
                            "runtime store path contains a symbolic link at \(current.path)"
                        )
                    }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw RuntimeInstallerError.untrustedStoreItem(
                        "runtime store path component is not a directory at \(current.path)"
                    )
                }
                if enteredUserBoundary, info.st_mode & 0o022 != 0 {
                    throw RuntimeInstallerError.untrustedStoreItem(
                        "runtime store path component is not private at \(current.path)"
                    )
                }
                continue
            }
            guard errno == ENOENT else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "inspect runtime store lease path",
                    path: current.path
                )
            }
            guard mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "create runtime store lease directory",
                    path: current.path
                )
            }
            enteredUserBoundary = true
        }
        var rootInfo = stat()
        guard lstat(rootURL.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              rootInfo.st_mode & 0o022 == 0
        else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime store root is not private and user-owned")
        }
        guard chmod(rootURL.path, 0o700) == 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "protect runtime store root",
                path: rootURL.path
            )
        }
    }
}
