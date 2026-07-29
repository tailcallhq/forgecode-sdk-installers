import Darwin
import Foundation

public struct RuntimeStoreReceipt: Codable, Equatable, Sendable {
    public static let format = 1

    public let formatVersion: Int
    public let version: RuntimeReleaseVersion
    public let architecture: RuntimeArchitecture
    public let archiveSHA256: String
    public let executableSHA256: String

    public init(
        version: RuntimeReleaseVersion,
        architecture: RuntimeArchitecture,
        archiveSHA256: String,
        executableSHA256: String
    ) {
        formatVersion = Self.format
        self.version = version
        self.architecture = architecture
        self.archiveSHA256 = archiveSHA256
        self.executableSHA256 = executableSHA256
    }
}

public protocol RuntimeStoreManaging: Sendable {
    func cached(version: RuntimeReleaseVersion, architecture: RuntimeArchitecture) throws -> InstalledRuntime?
    func current(architecture: RuntimeArchitecture) throws -> InstalledRuntime?
    func makePrivateTemporaryDirectory() throws -> URL
    func installStagedRuntime(
        executableURL: URL,
        receipt: RuntimeStoreReceipt,
        temporaryDirectory: URL
    ) throws -> InstalledRuntime
}

public final class RuntimeStore: RuntimeStoreManaging, @unchecked Sendable {
    private static let mutationLock = NSRecursiveLock()
    public struct CommitHooks: Sendable {
        public let afterDestinationMove: @Sendable () throws -> Void
        public let beforeActivationRename: @Sendable () throws -> Void

        public init(
            afterDestinationMove: @escaping @Sendable () throws -> Void = {},
            beforeActivationRename: @escaping @Sendable () throws -> Void = {}
        ) {
            self.afterDestinationMove = afterDestinationMove
            self.beforeActivationRename = beforeActivationRename
        }
    }

    public let rootURL: URL
    private let fileManager: FileManager
    private let validator: any RuntimeExecutableValidating
    private let commitHooks: CommitHooks
    private let lease: RuntimeStoreLease
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let recoveryLock = NSLock()
    private var completedColdRecovery = false
    private var storeLockDepth = 0
    private var storeLeaseToken: RuntimeStoreLease.Token?

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        validator: any RuntimeExecutableValidating = MachORuntimeValidator(),
        commitHooks: CommitHooks = CommitHooks(),
        lease: RuntimeStoreLease? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.validator = validator
        self.commitHooks = commitHooks
        self.lease = lease ?? RuntimeStoreLease(rootURL: self.rootURL)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    public static func defaultRoot(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let library = libraryDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Application Support/ForgeCode/runtime", isDirectory: true)
    }

    public func cached(version: RuntimeReleaseVersion, architecture: RuntimeArchitecture) throws -> InstalledRuntime? {
        try withStoreLock {
            try ensureRoot()
            let versionDirectory = versionsURL.appendingPathComponent(version.rawValue, isDirectory: true)
            try ensureManagedDirectory(versionDirectory, recoverCorrupt: true)
            let directory = versionDirectory.appendingPathComponent(architecture.rawValue, isDirectory: true)
            return try validateOrRecover(
                directory: directory,
                expectedVersion: version,
                expectedArchitecture: architecture
            )
        }
    }

    public func current(architecture: RuntimeArchitecture) throws -> InstalledRuntime? {
        try withStoreLock {
        try ensureRoot()
        let pointer = currentPointerURL
        guard try itemExistsNoFollow(pointer) else {
            return try recoverCurrent(architecture: architecture)
        }
        do {
            let data = try readRegularFileNoFollow(pointer, maximumBytes: 128, permissionsMustBePrivate: true)
            guard var value = String(data: data, encoding: .utf8) else {
                throw RuntimeInstallerError.untrustedStoreItem("invalid current pointer")
            }
            if value.hasSuffix("\n") { value.removeLast() }
            guard !value.contains("\n"), !value.contains("\r"), let version = RuntimeReleaseVersion(rawValue: value) else {
                throw RuntimeInstallerError.untrustedStoreItem("current pointer is not an exact release version")
            }
            guard let runtime = try cached(version: version, architecture: architecture) else {
                try removeItemNoFollow(pointer)
                return try recoverCurrent(architecture: architecture)
            }
            return runtime
        } catch let error as RuntimeInstallerError {
            if case .untrustedStoreItem = error {
                try removeItemNoFollow(pointer)
                return try recoverCurrent(architecture: architecture)
            }
            throw error
        }
        }
    }

    public func makePrivateTemporaryDirectory() throws -> URL {
        try withStoreLock {
        try ensureRoot()
        let template = temporaryURL.appendingPathComponent("install.XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard mkdtemp(&bytes) != nil else {
            throw RuntimeFilesystemError.posix(errno, operation: "create private runtime staging directory", path: template)
        }
        let path = String(cString: bytes)
        guard chmod(path, 0o700) == 0 else {
            try? fileManager.removeItem(atPath: path)
            throw RuntimeFilesystemError.posix(errno, operation: "protect runtime staging directory", path: path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    public func installStagedRuntime(
        executableURL: URL,
        receipt: RuntimeStoreReceipt,
        temporaryDirectory: URL
    ) throws -> InstalledRuntime {
        try withStoreLock {
        try ensureRoot()
        try checkCancellation()
        let standardizedTemporary = temporaryDirectory.standardizedFileURL
        let standardizedExecutable = executableURL.standardizedFileURL
        guard standardizedTemporary.deletingLastPathComponent() == temporaryURL.standardizedFileURL,
              standardizedExecutable == standardizedTemporary.appendingPathComponent("forge3")
        else { throw RuntimeInstallerError.untrustedStoreItem("staging path is outside the private runtime store") }
        try validatePrivateDirectory(standardizedTemporary, label: "staging directory")
        try validateRegularFileNoFollow(standardizedExecutable, label: "staged executable")
        let executableHash = try RuntimeSHA256.hexDigest(ofFile: standardizedExecutable)
        guard executableHash == receipt.executableSHA256 else {
            throw RuntimeInstallerError.checksumMismatch(expected: receipt.executableSHA256, actual: executableHash)
        }
        try validator.validate(executableURL: standardizedExecutable, expectedArchitecture: receipt.architecture)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standardizedExecutable.path)

        let receiptURL = standardizedTemporary.appendingPathComponent("receipt.json")
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try validateRegularFileNoFollow(receiptURL, label: "staged receipt")
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)

        let versionDirectory = versionsURL.appendingPathComponent(receipt.version.rawValue, isDirectory: true)
        try ensureManagedDirectory(versionDirectory, recoverCorrupt: true)
        let destination = versionDirectory.appendingPathComponent(receipt.architecture.rawValue, isDirectory: true)

        if try itemExistsNoFollow(destination) {
            if let existing = try validateOrRecover(
                directory: destination,
                expectedVersion: receipt.version,
                expectedArchitecture: receipt.architecture
            ) {
                try removeItemNoFollow(standardizedTemporary)
                try activate(receipt.version)
                return existing
            }
        }

        try checkCancellation()
        var movedIntoStore = false
        do {
            try fileManager.moveItem(at: standardizedTemporary, to: destination)
            movedIntoStore = true
            try commitHooks.afterDestinationMove()
            try checkCancellation()
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            guard var installed = try validate(
                directory: destination,
                expectedVersion: receipt.version,
                expectedArchitecture: receipt.architecture,
                requireSealed: false
            ) else {
                throw RuntimeInstallerError.untrustedStoreItem("staging did not produce a valid runtime")
            }
            try checkCancellation()
            try sealInstalledRuntime(directory: destination)
            installed = try validate(
                directory: destination,
                expectedVersion: receipt.version,
                expectedArchitecture: receipt.architecture
            ) ?? installed
            try checkCancellation()
            try activate(receipt.version)
            return installed
        } catch {
            if movedIntoStore { try? removeRuntimeDirectoryNoFollow(destination) }
            throw error
        }
        }
    }

    private var versionsURL: URL { rootURL.appendingPathComponent("versions", isDirectory: true) }
    private var temporaryURL: URL { rootURL.appendingPathComponent("tmp", isDirectory: true) }
    private var currentPointerURL: URL { rootURL.appendingPathComponent("current") }

    private func ensureRoot() throws {
        try validateManagedPathComponents(for: rootURL)
        try validatePrivateCreationBoundary(for: rootURL)
        try ensureManagedDirectory(rootURL, recoverCorrupt: false)
        try ensureManagedDirectory(versionsURL, recoverCorrupt: false)
        try ensureManagedDirectory(temporaryURL, recoverCorrupt: false)
        try performColdRecoveryOnce()
    }

    /// Validate the closest existing ancestor controlled by the current user.
    /// System paths such as `/var -> /private/var` may legitimately contain a
    /// root-owned symlink, but no user-controlled component at or below this
    /// private boundary may be a symlink or unsafe directory.
    private func validatePrivateCreationBoundary(for url: URL) throws {
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/", !(try itemExistsNoFollow(candidate)) {
            candidate.deleteLastPathComponent()
        }
        guard candidate.path != "/" else { return }
        try validatePrivateDirectory(candidate, label: "runtime store parent")
    }

    private func ensureManagedDirectory(_ directory: URL, recoverCorrupt: Bool) throws {
        if try itemExistsNoFollow(directory) {
            do {
                try validatePrivateDirectory(directory, label: "runtime store directory")
            } catch {
                guard recoverCorrupt else { throw error }
                try removeItemNoFollow(directory)
                try createPrivateDirectory(directory)
            }
        } else {
            try createPrivateDirectory(directory)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        if directory != rootURL, directory != parent, !(try itemExistsNoFollow(parent)) {
            try createPrivateDirectory(parent)
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "create runtime store directory", path: directory.path)
        }
    }

    private func validatePrivateDirectory(
        _ directory: URL,
        label: String,
        exactPermissions: mode_t? = nil
    ) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "inspect runtime store directory", path: directory.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0,
              exactPermissions.map({ info.st_mode & 0o777 == $0 }) ?? true
        else { throw RuntimeInstallerError.untrustedStoreItem("insecure \(label) \(directory.path)") }
    }

    private func validateRegularFileNoFollow(
        _ url: URL,
        label: String,
        exactPermissions: mode_t? = nil
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              exactPermissions.map({ info.st_mode & 0o777 == $0 }) ?? true
        else { throw RuntimeInstallerError.untrustedStoreItem("unsafe \(label) \(url.path)") }
    }

    private func validateOrRecover(
        directory: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedArchitecture: RuntimeArchitecture
    ) throws -> InstalledRuntime? {
        guard try itemExistsNoFollow(directory) else { return nil }
        do {
            return try validate(
                directory: directory,
                expectedVersion: expectedVersion,
                expectedArchitecture: expectedArchitecture
            )
        } catch {
            try removeRuntimeDirectoryNoFollow(directory)
            return nil
        }
    }

    private func validate(
        directory: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedArchitecture: RuntimeArchitecture,
        requireSealed: Bool = true
    ) throws -> InstalledRuntime? {
        guard try itemExistsNoFollow(directory) else { return nil }
        try validatePrivateDirectory(
            directory,
            label: "runtime directory",
            exactPermissions: requireSealed ? 0o500 : 0o700
        )
        let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
        guard Set(contents) == Set(["forge3", "receipt.json"]) else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime directory contains unexpected files")
        }

        let executable = directory.appendingPathComponent("forge3")
        let receiptURL = directory.appendingPathComponent("receipt.json")
        try validateRegularFileNoFollow(
            executable,
            label: "runtime executable",
            exactPermissions: requireSealed ? 0o500 : 0o700
        )
        try validateRegularFileNoFollow(
            receiptURL,
            label: "runtime receipt",
            exactPermissions: requireSealed ? 0o400 : 0o600
        )

        let data = try readRegularFileNoFollow(receiptURL, maximumBytes: 4_096, permissionsMustBePrivate: true)
        let receipt: RuntimeStoreReceipt
        do {
            receipt = try decoder.decode(RuntimeStoreReceipt.self, from: data)
        } catch {
            throw RuntimeInstallerError.untrustedStoreItem("receipt is invalid")
        }
        guard receipt.formatVersion == RuntimeStoreReceipt.format,
              receipt.version == expectedVersion,
              receipt.architecture == expectedArchitecture,
              isLowercaseSHA256(receipt.archiveSHA256),
              isLowercaseSHA256(receipt.executableSHA256)
        else { throw RuntimeInstallerError.untrustedStoreItem("receipt identity does not match its path") }
        let executableIdentity = try RuntimeExecutableIdentityValidator.capture(
            executable,
            expectedSHA256: receipt.executableSHA256
        )
        try validator.validate(executableURL: executable, expectedArchitecture: expectedArchitecture)
        try RuntimeExecutableIdentityValidator.validate(executable, expected: executableIdentity)
        return InstalledRuntime(
            version: expectedVersion,
            architecture: expectedArchitecture,
            executableURL: executable,
            executableIdentity: executableIdentity
        )
    }

    private func activate(_ version: RuntimeReleaseVersion) throws {
        try checkCancellation()
        let temporaryPointer = rootURL.appendingPathComponent(".current.\(UUID().uuidString)")
        defer { try? removeItemNoFollow(temporaryPointer) }
        try Data("\(version.rawValue)\n".utf8).write(to: temporaryPointer, options: .withoutOverwriting)
        try validateRegularFileNoFollow(temporaryPointer, label: "temporary current pointer")
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPointer.path)
        try commitHooks.beforeActivationRename()
        try checkCancellation()

        if try itemExistsNoFollow(currentPointerURL) {
            var info = stat()
            guard lstat(currentPointerURL.path, &info) == 0 else {
                throw RuntimeFilesystemError.posix(errno, operation: "inspect current runtime pointer", path: currentPointerURL.path)
            }
            if (info.st_mode & S_IFMT) != S_IFREG {
                try removeItemNoFollow(currentPointerURL)
            }
        }
        let result = rename(temporaryPointer.path, currentPointerURL.path)
        guard result == 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "atomically activate forge3", path: currentPointerURL.path)
        }
    }

    private func readRegularFileNoFollow(
        _ url: URL,
        maximumBytes: Int,
        permissionsMustBePrivate: Bool
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeInstallerError.untrustedStoreItem("could not safely open \(url.lastPathComponent)")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (!permissionsMustBePrivate || info.st_mode & 0o022 == 0),
              info.st_size >= 0,
              info.st_size <= maximumBytes
        else { throw RuntimeInstallerError.untrustedStoreItem("invalid \(url.lastPathComponent)") }
        let dataCount = Int(info.st_size)
        var data = Data(count: dataCount)
        var total = 0
        while total < dataCount {
            let remaining = dataCount - total
            let readCount = data.withUnsafeMutableBytes { buffer in
                read(descriptor, buffer.baseAddress!.advanced(by: total), remaining)
            }
            guard readCount > 0 else {
                throw RuntimeInstallerError.untrustedStoreItem("truncated \(url.lastPathComponent)")
            }
            total += readCount
        }
        return data
    }

    private func itemExistsNoFollow(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw RuntimeFilesystemError.posix(errno, operation: "inspect runtime store item", path: url.path)
    }

    private func removeItemNoFollow(_ url: URL) throws {
        guard try itemExistsNoFollow(url) else { return }
        try fileManager.removeItem(at: url)
    }

    private func sealInstalledRuntime(directory: URL) throws {
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "open installed runtime directory for sealing",
                path: directory.path
            )
        }
        defer { close(directoryDescriptor) }
        try setManagedMode(
            directoryDescriptor: directoryDescriptor,
            name: "forge3",
            expectedType: S_IFREG,
            mode: 0o500,
            operation: "seal installed runtime executable"
        )
        try setManagedMode(
            directoryDescriptor: directoryDescriptor,
            name: "receipt.json",
            expectedType: S_IFREG,
            mode: 0o400,
            operation: "seal installed runtime receipt"
        )
        guard fchmod(directoryDescriptor, 0o500) == 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "seal installed runtime directory",
                path: directory.path
            )
        }
    }

    private func removeRuntimeDirectoryNoFollow(_ directory: URL) throws {
        guard try itemExistsNoFollow(directory) else { return }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0
        else {
            try removeItemNoFollow(directory)
            return
        }
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "open managed runtime directory for removal",
                path: directory.path
            )
        }
        defer { close(directoryDescriptor) }
        for name in ["forge3", "receipt.json"] {
            var childInfo = stat()
            let result = name.withCString {
                fstatat(directoryDescriptor, $0, &childInfo, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                if errno == ENOENT { continue }
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "inspect managed runtime item before removal",
                    path: directory.appendingPathComponent(name).path
                )
            }
            guard (childInfo.st_mode & S_IFMT) == S_IFREG,
                  childInfo.st_uid == geteuid(),
                  childInfo.st_nlink == 1,
                  childInfo.st_mode & 0o022 == 0
            else {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "refusing to unseal an unmanaged runtime item at \(directory.appendingPathComponent(name).path)"
                )
            }
            let childDescriptor = name.withCString {
                openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard childDescriptor >= 0 else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "open managed runtime item for removal",
                    path: directory.appendingPathComponent(name).path
                )
            }
            let chmodResult = fchmod(childDescriptor, name == "forge3" ? 0o700 : 0o600)
            close(childDescriptor)
            guard chmodResult == 0 else {
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "unseal managed runtime item for removal",
                    path: directory.appendingPathComponent(name).path
                )
            }
        }
        guard fchmod(directoryDescriptor, 0o700) == 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "unseal managed runtime directory for removal",
                path: directory.path
            )
        }
        try removeItemNoFollow(directory)
    }

    private func setManagedMode(
        directoryDescriptor: Int32,
        name: String,
        expectedType: mode_t,
        mode: mode_t,
        operation: String
    ) throws {
        var info = stat()
        let statResult = name.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              (info.st_mode & S_IFMT) == expectedType,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0
        else {
            throw RuntimeInstallerError.untrustedStoreItem(
                "refusing to change permissions on unmanaged runtime item \(name)"
            )
        }
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: operation, path: name)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: operation, path: name)
        }
    }

    private func recoverCurrent(architecture: RuntimeArchitecture) throws -> InstalledRuntime? {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: versionsURL.path)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "enumerate installed runtimes", path: versionsURL.path)
        }
        let versions = names.compactMap(RuntimeReleaseVersion.init(rawValue:)).sorted(by: >)
        for version in versions {
            if let runtime = try cached(version: version, architecture: architecture) {
                try activate(version)
                return runtime
            }
        }
        return nil
    }

    private func performColdRecoveryOnce() throws {
        recoveryLock.lock()
        if completedColdRecovery {
            recoveryLock.unlock()
            return
        }
        completedColdRecovery = true
        recoveryLock.unlock()
        do {
            try cleanSafeStaleArtifacts()
        } catch {
            recoveryLock.lock()
            completedColdRecovery = false
            recoveryLock.unlock()
            throw error
        }
    }

    private func cleanSafeStaleArtifacts() throws {
        let temporaryNames: [String]
        do {
            temporaryNames = try fileManager.contentsOfDirectory(atPath: temporaryURL.path)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "enumerate runtime staging artifacts", path: temporaryURL.path)
        }
        for name in temporaryNames where name.hasPrefix("install.") {
            let artifact = temporaryURL.appendingPathComponent(name)
            if try isSafeStaleArtifact(artifact, expectedType: S_IFDIR) {
                try removeItemNoFollow(artifact)
            }
        }
        let rootNames: [String]
        do {
            rootNames = try fileManager.contentsOfDirectory(atPath: rootURL.path)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "enumerate runtime store artifacts", path: rootURL.path)
        }
        for name in rootNames where name.hasPrefix(".current.") {
            let artifact = rootURL.appendingPathComponent(name)
            if try isSafeStaleArtifact(artifact, expectedType: S_IFREG) {
                try removeItemNoFollow(artifact)
            }
        }
    }

    private func isSafeStaleArtifact(_ url: URL, expectedType: mode_t) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw RuntimeFilesystemError.posix(errno, operation: "inspect stale runtime artifact", path: url.path)
        }
        guard (info.st_mode & S_IFMT) == expectedType,
              info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0
        else { return false }
        let staleBefore = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        let modificationTime = TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return modificationTime <= staleBefore
    }

    private func validateManagedPathComponents(for url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var enteredUserBoundary = false
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if errno == ENOENT { break }
                throw RuntimeFilesystemError.posix(errno, operation: "inspect runtime path component", path: current.path)
            }
            if info.st_uid == geteuid() { enteredUserBoundary = true }
            if (info.st_mode & S_IFMT) == S_IFLNK, enteredUserBoundary {
                throw RuntimeInstallerError.untrustedStoreItem("runtime store path contains a symbolic link at \(current.path)")
            }
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        do {
            if storeLockDepth == 0 {
                storeLeaseToken = try lease.acquire(.exclusiveMutation)
            }
            storeLockDepth += 1
            defer {
                storeLockDepth -= 1
                if storeLockDepth == 0 {
                    storeLeaseToken?.release()
                    storeLeaseToken = nil
                }
            }
            return try body()
        } catch {
            throw RuntimeFilesystemError.wrapping(
                error,
                operation: "manage forge3 runtime store",
                path: rootURL.path
            )
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw RuntimeInstallerError.cancelled }
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }
}
