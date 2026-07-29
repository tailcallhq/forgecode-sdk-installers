import Darwin
import Foundation

public enum RuntimeInstallationSecurityEvent: Sendable, Equatable {
    case refreshedAdHocQuarantinedStagedExecutable
}

public protocol RuntimeInstallationSecurityLogging: Sendable {
    func log(_ event: RuntimeInstallationSecurityEvent)
}

public protocol RuntimeInstallerValidationTracing: Sendable {
    func record(_ event: RuntimeInstallerValidationEvent)
}

public struct NoOpRuntimeInstallerValidationTracer: RuntimeInstallerValidationTracing {
    public init() {}
    public func record(_ event: RuntimeInstallerValidationEvent) {}
}

public protocol RuntimeInstallerProgressDeliveryHook: Sendable {
    func beforeDelivery(_ delivery: RuntimeInstallerProgressDelivery) async
}

public struct NoOpRuntimeInstallerProgressDeliveryHook: RuntimeInstallerProgressDeliveryHook {
    public init() {}
    public func beforeDelivery(_ delivery: RuntimeInstallerProgressDelivery) async {}
}

private final class RuntimeInstallerProgressChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (RuntimeInstallationPhase) async -> Void
    private let hook: any RuntimeInstallerProgressDeliveryHook
    private var tail: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    init(
        handler: @escaping @Sendable (RuntimeInstallationPhase) async -> Void,
        hook: any RuntimeInstallerProgressDeliveryHook
    ) {
        self.handler = handler
        self.hook = hook
    }

    func enqueue(_ delivery: RuntimeInstallerProgressDelivery) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let predecessor = tail
        let handler = self.handler
        let hook = self.hook
        let task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await hook.beforeDelivery(delivery)
            guard !Task.isCancelled else { return }
            await handler(delivery.phase)
        }
        tail = task
        tasks.append(task)
    }

    func close() async {
        let pending: Task<Void, Never>? = lock.withLock {
            closed = true
            return tail
        }
        await pending?.value
    }

    func cancelPending() {
        let pending: [Task<Void, Never>] = lock.withLock {
            closed = true
            return tasks
        }
        pending.forEach { $0.cancel() }
    }
}

public struct AppRuntimeInstallationSecurityLogger: RuntimeInstallationSecurityLogging {
    public init() {}

    public func log(_ event: RuntimeInstallationSecurityEvent) {
        switch event {
        case .refreshedAdHocQuarantinedStagedExecutable:
            AppLogger.shared.warning(
                "Applied the temporary pre-execution trust policy to a fully validated ad-hoc-signed forge3 artifact by refreshing its staged vnode without com.apple.quarantine"
            )
        }
    }
}

public protocol RuntimePreExecutionTrustPolicy: Sendable {
    func decision(for context: RuntimePreExecutionTrustContext) throws -> RuntimePreExecutionTrustDecision
}

public struct TemporaryAdHocRuntimeTrustPolicy: RuntimePreExecutionTrustPolicy {
    public init() {}

    public func decision(for context: RuntimePreExecutionTrustContext) throws -> RuntimePreExecutionTrustDecision {
        context.signatureClass == .adHoc && context.hasQuarantine
            ? .refreshRemovingQuarantine
            : .preserve
    }
}

public protocol RuntimeQuarantineManaging: Sendable {
    func hasQuarantine(
        at executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> Bool

    /// Atomically replaces the staged executable with a fresh same-directory
    /// vnode copied from a descriptor pinned to `expectedIdentity`. Only
    /// com.apple.quarantine is omitted; safe permissions and unrelated xattrs
    /// are retained. The returned identity describes the replacement vnode.
    func refreshExecutableRemovingQuarantine(
        from executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableIdentity
}

public struct DarwinRuntimeQuarantineManager: RuntimeQuarantineManaging {
    private static let quarantineName = "com.apple.quarantine"
    private let expectedUserID: uid_t

    public init(expectedUserID: uid_t = geteuid()) {
        self.expectedUserID = expectedUserID
    }

    public func hasQuarantine(
        at executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> Bool {
        let pinned = try Self.openPinnedSource(
            executableURL,
            expectedIdentity: expectedIdentity,
            expectedUserID: expectedUserID
        )
        defer {
            close(pinned.sourceDescriptor)
            close(pinned.directoryDescriptor)
        }
        let result = Self.quarantineName.withCString {
            fgetxattr(pinned.sourceDescriptor, $0, nil, 0, 0, 0)
        }
        if result >= 0 { return true }
        if errno == ENOATTR { return false }
        throw Self.failure("could not inspect quarantine on the pinned staged executable")
    }

    public func refreshExecutableRemovingQuarantine(
        from executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableIdentity {
        let pinned = try Self.openPinnedSource(
            executableURL,
            expectedIdentity: expectedIdentity,
            expectedUserID: expectedUserID
        )
        defer {
            close(pinned.sourceDescriptor)
            close(pinned.directoryDescriptor)
        }
        guard try Self.hasQuarantine(pinned.sourceDescriptor) else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the pinned staged executable no longer has com.apple.quarantine"
            )
        }

        let temporaryName = ".forge3-quarantine-refresh.\(UUID().uuidString)"
        let permissions = pinned.sourceInfo.st_mode & 0o777
        let destinationDescriptor = temporaryName.withCString {
            openat(
                pinned.directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                permissions
            )
        }
        guard destinationDescriptor >= 0 else {
            throw Self.failure("could not exclusively create the refreshed staged executable")
        }
        var renamed = false
        defer {
            close(destinationDescriptor)
            if !renamed {
                _ = temporaryName.withCString { unlinkat(pinned.directoryDescriptor, $0, 0) }
            }
        }

        try Self.copyBytes(
            from: pinned.sourceDescriptor,
            to: destinationDescriptor,
            expectedSize: expectedIdentity.size
        )
        try Self.copyExtendedAttributes(
            from: pinned.sourceDescriptor,
            to: destinationDescriptor
        )
        guard fchmod(destinationDescriptor, permissions) == 0 else {
            throw Self.failure("could not preserve staged executable permissions")
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw Self.failure("could not synchronize the refreshed staged executable")
        }

        let sourceAfterCopy = try Self.trustedFileInfo(
            pinned.sourceDescriptor,
            expectedIdentity: expectedIdentity,
            operation: "revalidate pinned staged executable",
            expectedUserID: expectedUserID
        )
        guard Self.sameFile(pinned.sourceInfo, sourceAfterCopy),
              try RuntimeSHA256.hexDigest(
                ofDescriptor: pinned.sourceDescriptor,
                path: executableURL.path
              ) == expectedIdentity.sha256
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the staged executable changed while its trusted vnode was refreshed"
            )
        }

        let destinationIdentity = try Self.captureIdentity(
            destinationDescriptor,
            path: executableURL.path,
            expectedSHA256: expectedIdentity.sha256
        )
        guard destinationIdentity.device == expectedIdentity.device,
              destinationIdentity.inode != expectedIdentity.inode
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the refreshed staged executable did not receive a fresh vnode"
            )
        }
        guard !(try Self.hasQuarantine(destinationDescriptor)) else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the refreshed staged executable still has com.apple.quarantine"
            )
        }

        try Self.validatePathStillReferencesPinnedSource(
            directoryDescriptor: pinned.directoryDescriptor,
            name: pinned.name,
            expectedIdentity: expectedIdentity
        )
        let renameResult = temporaryName.withCString { temporaryPath in
            pinned.name.withCString { executablePath in
                renameat(
                    pinned.directoryDescriptor,
                    temporaryPath,
                    pinned.directoryDescriptor,
                    executablePath
                )
            }
        }
        guard renameResult == 0 else {
            throw Self.failure("could not atomically activate the refreshed staged executable")
        }
        renamed = true
        guard fsync(pinned.directoryDescriptor) == 0 else {
            throw Self.failure("could not synchronize the staged executable directory")
        }

        let replacementDescriptor = pinned.name.withCString {
            openat(pinned.directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard replacementDescriptor >= 0 else {
            throw Self.failure("could not reopen the refreshed staged executable")
        }
        defer { close(replacementDescriptor) }
        let replacementIdentity = try Self.captureIdentity(
            replacementDescriptor,
            path: executableURL.path,
            expectedSHA256: expectedIdentity.sha256
        )
        guard replacementIdentity == destinationIdentity else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the refreshed staged executable identity changed during atomic replacement"
            )
        }
        return replacementIdentity
    }

    private struct PinnedSource {
        let directoryDescriptor: Int32
        let sourceDescriptor: Int32
        let name: String
        let sourceInfo: stat
    }

    private static func openPinnedSource(
        _ executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity,
        expectedUserID: uid_t
    ) throws -> PinnedSource {
        let executable = executableURL.standardizedFileURL
        let directory = executable.deletingLastPathComponent()
        let name = executable.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              directory.appendingPathComponent(name).standardizedFileURL == executable
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed("invalid staged executable path")
        }
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw failure("could not safely open the staged executable directory")
        }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == expectedUserID,
              directoryInfo.st_mode & 0o022 == 0
        else {
            close(directoryDescriptor)
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the staged executable directory is not private and user-owned"
            )
        }
        let sourceDescriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            close(directoryDescriptor)
            throw failure("could not safely open the staged executable")
        }
        do {
            let sourceInfo = try trustedFileInfo(
                sourceDescriptor,
                expectedIdentity: expectedIdentity,
                operation: "pin staged executable",
                expectedUserID: expectedUserID
            )
            try validatePathStillReferencesPinnedSource(
                directoryDescriptor: directoryDescriptor,
                name: name,
                expectedIdentity: expectedIdentity
            )
            let hash = try RuntimeSHA256.hexDigest(
                ofDescriptor: sourceDescriptor,
                path: executable.path
            )
            guard hash == expectedIdentity.sha256 else {
                throw RuntimeInstallerError.quarantineRemovalFailed(
                    "the pinned staged executable checksum changed"
                )
            }
            return PinnedSource(
                directoryDescriptor: directoryDescriptor,
                sourceDescriptor: sourceDescriptor,
                name: name,
                sourceInfo: sourceInfo
            )
        } catch {
            close(sourceDescriptor)
            close(directoryDescriptor)
            throw error
        }
    }

    private static func trustedFileInfo(
        _ descriptor: Int32,
        expectedIdentity: RuntimeExecutableIdentity,
        operation: String,
        expectedUserID: uid_t
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw failure("could not \(operation)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedUserID,
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              info.st_mode & 0o100 != 0,
              info.st_size == expectedIdentity.size,
              UInt64(info.st_dev) == expectedIdentity.device,
              UInt64(info.st_ino) == expectedIdentity.inode
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the staged executable is not the expected private single-link user-owned vnode"
            )
        }
        return info
    }

    private static func validatePathStillReferencesPinnedSource(
        directoryDescriptor: Int32,
        name: String,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws {
        var info = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size == expectedIdentity.size,
              UInt64(info.st_dev) == expectedIdentity.device,
              UInt64(info.st_ino) == expectedIdentity.inode
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the staged executable path no longer references the validated vnode"
            )
        }
    }

    private static func captureIdentity(
        _ descriptor: Int32,
        path: String,
        expectedSHA256: String
    ) throws -> RuntimeExecutableIdentity {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o022 == 0,
              before.st_mode & 0o100 != 0,
              before.st_size >= 0
        else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the refreshed staged executable is not a private single-link user-owned executable"
            )
        }
        let hash = try RuntimeSHA256.hexDigest(ofDescriptor: descriptor, path: path)
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameFile(before, after), hash == expectedSHA256 else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the refreshed staged executable identity or checksum is unstable"
            )
        }
        return RuntimeExecutableIdentity(
            device: UInt64(before.st_dev),
            inode: UInt64(before.st_ino),
            size: before.st_size,
            sha256: hash
        )
    }

    private static func copyBytes(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        expectedSize: Int64
    ) throws {
        guard lseek(sourceDescriptor, 0, SEEK_SET) >= 0 else {
            throw failure("could not seek the pinned staged executable")
        }
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(sourceDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("could not read the pinned staged executable")
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw failure("could not write the refreshed staged executable")
                }
                written += result
            }
            copied += Int64(count)
            guard copied <= expectedSize else {
                throw RuntimeInstallerError.quarantineRemovalFailed(
                    "the staged executable grew while it was refreshed"
                )
            }
        }
        guard copied == expectedSize else {
            throw RuntimeInstallerError.quarantineRemovalFailed(
                "the staged executable was truncated while it was refreshed"
            )
        }
    }

    private static func copyExtendedAttributes(from sourceDescriptor: Int32, to destinationDescriptor: Int32) throws {
        let bufferSize = flistxattr(sourceDescriptor, nil, 0, 0)
        guard bufferSize >= 0 else {
            throw failure("could not enumerate staged executable extended attributes")
        }
        guard bufferSize > 0 else { return }
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let readCount = flistxattr(sourceDescriptor, &buffer, buffer.count, 0)
        guard readCount == bufferSize else {
            throw failure("staged executable extended attributes changed during inspection")
        }

        var offset = 0
        while offset < readCount {
            let name = buffer.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            if name == quarantineName { continue }
            let valueSize = name.withCString {
                fgetxattr(sourceDescriptor, $0, nil, 0, 0, 0)
            }
            guard valueSize >= 0 else {
                throw failure("could not read staged executable extended attribute \(name)")
            }
            var value = Data(count: valueSize)
            let valueReadCount = value.withUnsafeMutableBytes { bytes in
                name.withCString {
                    fgetxattr(sourceDescriptor, $0, bytes.baseAddress, valueSize, 0, 0)
                }
            }
            guard valueReadCount == valueSize else {
                throw failure("staged executable extended attribute \(name) changed during copy")
            }
            let setResult = value.withUnsafeBytes { bytes in
                name.withCString {
                    fsetxattr(destinationDescriptor, $0, bytes.baseAddress, valueSize, 0, 0)
                }
            }
            guard setResult == 0 else {
                throw failure("could not preserve staged executable extended attribute \(name)")
            }
        }
    }

    private static func hasQuarantine(_ descriptor: Int32) throws -> Bool {
        let result = quarantineName.withCString {
            fgetxattr(descriptor, $0, nil, 0, 0, 0)
        }
        if result >= 0 { return true }
        if errno == ENOATTR { return false }
        throw failure("could not inspect quarantine on the staged executable descriptor")
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func failure(_ message: String) -> RuntimeInstallerError {
        RuntimeInstallerError.quarantineRemovalFailed(
            "\(message): \(String(cString: strerror(errno)))"
        )
    }
}

private struct LatestRuntimeManifest: Decodable {
    let version: RuntimeReleaseVersion
}

private actor RuntimeInstallationGate {
    static let shared = RuntimeInstallationGate()

    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Never>)] = []

    func acquire(_ id: UUID) async {
        if owner == nil {
            owner = id
            return
        }
        await withCheckedContinuation { waiters.append((id, $0)) }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.0
            next.1.resume()
        }
    }
}

public protocol RuntimeInstalling: Sendable {
    func installedCurrentRuntime() async throws -> InstalledRuntime?
    func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime
}

public actor RuntimeInstaller: RuntimeInstalling {
    public struct Dependencies: Sendable {
        public let network: any RuntimeNetworkClient
        public let store: any RuntimeStoreManaging
        public let archive: any RuntimeArchiveHandling
        public let validator: any RuntimeExecutableValidating
        public let signatureInspector: any RuntimeCodeSignatureInspecting
        public let trustPolicy: any RuntimePreExecutionTrustPolicy
        public let quarantineManager: any RuntimeQuarantineManaging
        public let securityLogger: any RuntimeInstallationSecurityLogging
        public let validationTracer: any RuntimeInstallerValidationTracing
        public let developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy
        public let developerIDRequirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating
        public let progressDeliveryHook: any RuntimeInstallerProgressDeliveryHook
        public let storeLease: RuntimeStoreLease?

        public init(
            network: any RuntimeNetworkClient,
            store: any RuntimeStoreManaging,
            archive: any RuntimeArchiveHandling,
            validator: any RuntimeExecutableValidating,
            signatureInspector: (any RuntimeCodeSignatureInspecting)? = nil,
            trustPolicy: any RuntimePreExecutionTrustPolicy = TemporaryAdHocRuntimeTrustPolicy(),
            quarantineManager: any RuntimeQuarantineManaging = DarwinRuntimeQuarantineManager(),
            securityLogger: any RuntimeInstallationSecurityLogging = AppRuntimeInstallationSecurityLogger(),
            validationTracer: any RuntimeInstallerValidationTracing = NoOpRuntimeInstallerValidationTracer(),
            developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy = RuntimeDeveloperIDAuthenticationPolicy(),
            developerIDRequirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating = SecurityRuntimeDeveloperIDRequirementEvaluator(),
            progressDeliveryHook: any RuntimeInstallerProgressDeliveryHook = NoOpRuntimeInstallerProgressDeliveryHook(),
            storeLease: RuntimeStoreLease? = nil
        ) {
            self.network = network
            self.store = store
            self.archive = archive
            self.validator = validator
            self.signatureInspector = signatureInspector
                ?? (validator as? any RuntimeCodeSignatureInspecting)
                ?? UnsignedRuntimeCodeSignatureInspector()
            self.trustPolicy = trustPolicy
            self.quarantineManager = quarantineManager
            self.securityLogger = securityLogger
            self.validationTracer = validationTracer
            self.developerIDAuthenticationPolicy = developerIDAuthenticationPolicy
            self.developerIDRequirementEvaluator = developerIDRequirementEvaluator
            self.progressDeliveryHook = progressDeliveryHook
            self.storeLease = storeLease
        }
    }

    private struct Operation {
        let id: UUID
        let key: String
        let task: Task<Void, Never>
        var resultWaiters: [UUID: CheckedContinuation<InstalledRuntime, Error>]
        var completionWaiters: [UUID: CheckedContinuation<Void, Never>]
        var progressHandlers: [UUID: RuntimeInstallerProgressChannel]
        var latestProgress: RuntimeInstallationPhase?
        var acceptingJoiners: Bool
    }

    private let architecture: RuntimeArchitecture
    private let limits: RuntimeInstallerLimits
    private let dependencies: Dependencies
    private var activeOperation: Operation?
    private var cancelledResultWaiters: Set<UUID> = []
    private var cancelledCompletionWaiters: Set<UUID> = []

    public init(
        rootURL: URL = RuntimeStore.defaultRoot(),
        architecture: RuntimeArchitecture = .native,
        limits: RuntimeInstallerLimits = RuntimeInstallerLimits(),
        expectedDeveloperIDTeamIdentifier: String? = nil
    ) {
        let developerIDRequirementEvaluator = SecurityRuntimeDeveloperIDRequirementEvaluator()
        let validator = MachORuntimeValidator(
            developerIDRequirementEvaluator: developerIDRequirementEvaluator
        )
        let lease = RuntimeStoreLease(rootURL: rootURL)
        self.architecture = architecture
        self.limits = limits
        dependencies = Dependencies(
            network: URLSessionRuntimeNetworkClient(),
            store: RuntimeStore(rootURL: rootURL, validator: validator, lease: lease),
            archive: SafeTarXZArchiveHandler(),
            validator: validator,
            signatureInspector: validator,
            trustPolicy: TemporaryAdHocRuntimeTrustPolicy(),
            quarantineManager: DarwinRuntimeQuarantineManager(),
            securityLogger: AppRuntimeInstallationSecurityLogger(),
            developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy(
                expectedTeamIdentifier: expectedDeveloperIDTeamIdentifier
            ),
            developerIDRequirementEvaluator: developerIDRequirementEvaluator,
            storeLease: lease
        )
    }

    public init(
        architecture: RuntimeArchitecture,
        limits: RuntimeInstallerLimits = RuntimeInstallerLimits(),
        dependencies: Dependencies
    ) {
        self.architecture = architecture
        self.limits = limits
        self.dependencies = dependencies
    }

    public func installedCurrentRuntime() throws -> InstalledRuntime? {
        try dependencies.store.current(architecture: architecture)
    }

    public func installLatest() async throws -> InstalledRuntime {
        try await installLatest { _ in }
    }

    public func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        let key = "latest:\(architecture.rawValue)"
        return try await coalesced(key: key, progress: progress) { [architecture, limits, dependencies] emitProgress in
            await emitProgress(.resolving)
            try Task.checkCancellation()
            if let current = try dependencies.store.current(architecture: architecture) {
                await emitProgress(.ready)
                return current
            }
            let manifestDownload = try await dependencies.network.download(
                RuntimeDownloadRequest(
                    url: RuntimeReleaseURLs.latestManifest,
                    maximumBytes: limits.manifestBytes,
                    maximumRedirects: limits.redirects
                )
            )
            let manifest: LatestRuntimeManifest
            do {
                let decoder = JSONDecoder()
                manifest = try decoder.decode(LatestRuntimeManifest.self, from: manifestDownload.data)
            } catch {
                throw RuntimeInstallerError.invalidManifest(error.localizedDescription)
            }
            let installed = try await Self.install(
                version: manifest.version,
                architecture: architecture,
                limits: limits,
                dependencies: dependencies,
                progress: emitProgress
            )
            await emitProgress(.ready)
            return installed
        }
    }

    public func install(version: RuntimeReleaseVersion) async throws -> InstalledRuntime {
        let key = "\(version.rawValue):\(architecture.rawValue)"
        return try await coalesced(key: key) { [architecture, limits, dependencies] _ in
            try await Self.install(
                version: version,
                architecture: architecture,
                limits: limits,
                dependencies: dependencies,
                progress: { _ in }
            )
        }
    }

    private func coalesced(
        key: String,
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void = { _ in },
        operation: @escaping @Sendable (
            _ progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
        ) async throws -> InstalledRuntime
    ) async throws -> InstalledRuntime {
        while let active = activeOperation,
              active.key != key || !active.acceptingJoiners {
            try await waitForOperationCompletion(active.id)
            try checkCancellation()
        }

        let operationID: UUID
        if let active = activeOperation {
            operationID = active.id
        } else {
            operationID = startOperation(key: key, operation: operation)
        }
        return try await waitForOperationResult(operationID: operationID, progress: progress)
    }

    private func startOperation(
        key: String,
        operation: @escaping @Sendable (
            _ progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
        ) async throws -> InstalledRuntime
    ) -> UUID {
        let operationID = UUID()
        let owner = self
        let task = Task {
            await RuntimeInstallationGate.shared.acquire(operationID)
            let result: Result<InstalledRuntime, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await operation { phase in
                    await owner.publishProgress(operationID: operationID, phase: phase)
                })
            }
            catch is CancellationError { result = .failure(RuntimeInstallerError.cancelled) }
            catch { result = .failure(error) }
            await RuntimeInstallationGate.shared.release(operationID)
            await owner.finishOperation(id: operationID, result: result)
        }
        activeOperation = Operation(
            id: operationID,
            key: key,
            task: task,
            resultWaiters: [:],
            completionWaiters: [:],
            progressHandlers: [:],
            latestProgress: nil,
            acceptingJoiners: true
        )
        return operationID
    }

    private func waitForOperationResult(
        operationID: UUID,
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerResultWaiter(
                    continuation,
                    operationID: operationID,
                    waiterID: waiterID,
                    progress: progress
                )
            }
        } onCancel: {
            Task { await self.cancelResultWaiter(operationID: operationID, waiterID: waiterID) }
        }
    }

    private func registerResultWaiter(
        _ continuation: CheckedContinuation<InstalledRuntime, Error>,
        operationID: UUID,
        waiterID: UUID,
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) {
        if cancelledResultWaiters.remove(waiterID) != nil || Task.isCancelled {
            continuation.resume(throwing: RuntimeInstallerError.cancelled)
            return
        }
        guard var active = activeOperation, active.id == operationID else {
            continuation.resume(throwing: RuntimeInstallerError.processFailure("installation operation ended before the waiter joined"))
            return
        }
        let channel = RuntimeInstallerProgressChannel(
            handler: progress,
            hook: dependencies.progressDeliveryHook
        )
        active.resultWaiters[waiterID] = continuation
        active.progressHandlers[waiterID] = channel
        if let latest = active.latestProgress {
            channel.enqueue(RuntimeInstallerProgressDelivery(phase: latest, kind: .replay))
        }
        activeOperation = active
    }

    private func cancelResultWaiter(operationID: UUID, waiterID: UUID) {
        guard var active = activeOperation, active.id == operationID else {
            cancelledResultWaiters.insert(waiterID)
            return
        }
        guard let continuation = active.resultWaiters.removeValue(forKey: waiterID) else {
            cancelledResultWaiters.insert(waiterID)
            return
        }
        let progressChannel = active.progressHandlers.removeValue(forKey: waiterID)
        let shouldCancelOperation = active.resultWaiters.isEmpty
        if shouldCancelOperation { active.acceptingJoiners = false }
        activeOperation = active
        progressChannel?.cancelPending()
        continuation.resume(throwing: RuntimeInstallerError.cancelled)
        if shouldCancelOperation { active.task.cancel() }
    }

    private func waitForOperationCompletion(_ operationID: UUID) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerCompletionWaiter(continuation, operationID: operationID, waiterID: waiterID)
            }
            try checkCancellation()
        } onCancel: {
            Task { await self.cancelCompletionWaiter(operationID: operationID, waiterID: waiterID) }
        }
    }

    private func registerCompletionWaiter(
        _ continuation: CheckedContinuation<Void, Never>,
        operationID: UUID,
        waiterID: UUID
    ) {
        if cancelledCompletionWaiters.remove(waiterID) != nil || Task.isCancelled {
            continuation.resume()
            return
        }
        guard var active = activeOperation, active.id == operationID else {
            continuation.resume()
            return
        }
        active.completionWaiters[waiterID] = continuation
        activeOperation = active
    }

    private func cancelCompletionWaiter(operationID: UUID, waiterID: UUID) {
        guard var active = activeOperation, active.id == operationID else {
            cancelledCompletionWaiters.insert(waiterID)
            return
        }
        guard let continuation = active.completionWaiters.removeValue(forKey: waiterID) else {
            cancelledCompletionWaiters.insert(waiterID)
            return
        }
        activeOperation = active
        continuation.resume()
    }

    private func publishProgress(operationID: UUID, phase: RuntimeInstallationPhase) {
        guard var active = activeOperation, active.id == operationID else { return }
        active.latestProgress = phase
        for channel in active.progressHandlers.values {
            channel.enqueue(RuntimeInstallerProgressDelivery(phase: phase, kind: .publication))
        }
        activeOperation = active
    }

    private func finishOperation(id: UUID, result: Result<InstalledRuntime, Error>) async {
        guard var active = activeOperation, active.id == id else { return }
        active.acceptingJoiners = false
        let progressChannels = Array(active.progressHandlers.values)
        activeOperation = active
        for channel in progressChannels { await channel.close() }
        guard let completed = activeOperation, completed.id == id else { return }
        activeOperation = nil
        for continuation in completed.resultWaiters.values {
            switch result {
            case .success(let runtime): continuation.resume(returning: runtime)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        completed.completionWaiters.values.forEach { $0.resume() }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw RuntimeInstallerError.cancelled }
    }

    private static func install(
        version: RuntimeReleaseVersion,
        architecture: RuntimeArchitecture,
        limits: RuntimeInstallerLimits,
        dependencies: Dependencies,
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        try Task.checkCancellation()
        if let cached = try dependencies.store.cached(version: version, architecture: architecture) {
            return cached
        }

        await progress(.downloading(progress: 0))
        let temporaryDirectory = try dependencies.store.makePrivateTemporaryDirectory()
        var temporaryDirectoryOwned = true
        defer {
            if temporaryDirectoryOwned {
                var cleanupLease: RuntimeStoreLease.Token?
                if let storeLease = dependencies.storeLease {
                    cleanupLease = try? storeLease.acquire(.exclusiveMutation)
                }
                try? FileManager.default.removeItem(at: temporaryDirectory)
                cleanupLease?.release()
            }
        }

        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: architecture)
        let sidecarURL = RuntimeReleaseURLs.checksum(version: version, architecture: architecture)
        async let archiveDownload = dependencies.network.download(
            RuntimeDownloadRequest(
                url: archiveURL,
                maximumBytes: limits.archiveBytes,
                maximumRedirects: limits.redirects
            ),
            progress: { receivedBytes, expectedBytes in
                guard expectedBytes > 0 else { return }
                await progress(.downloading(progress: Double(receivedBytes) / Double(expectedBytes)))
            }
        )
        async let checksumDownload = dependencies.network.download(
            RuntimeDownloadRequest(
                url: sidecarURL,
                maximumBytes: limits.checksumBytes,
                maximumRedirects: limits.redirects
            ),
            progress: { _, _ in }
        )
        let (downloadedArchive, downloadedChecksum) = try await (archiveDownload, checksumDownload)
        try Task.checkCancellation()
        await progress(.verifying)

        let expectedChecksum = try RuntimeChecksumSidecar.parse(
            downloadedChecksum.data,
            expectedFilename: architecture.archiveName
        )
        let actualChecksum = RuntimeSHA256.hexDigest(of: downloadedArchive.data)
        guard actualChecksum == expectedChecksum else {
            throw RuntimeInstallerError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        let stagingLease = try dependencies.storeLease?.acquire(.exclusiveMutation)
        var stagingLeaseReleased = false
        defer {
            if !stagingLeaseReleased { stagingLease?.release() }
        }

        let archiveFile = temporaryDirectory.appendingPathComponent(architecture.archiveName)
        do {
            try downloadedArchive.data.write(to: archiveFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveFile.path)
        } catch {
            throw RuntimeFilesystemError.wrapping(
                error,
                operation: "stage downloaded runtime archive",
                path: archiveFile.path
            )
        }
        try Self.applyDownloadQuarantine(to: archiveFile, sourceURL: downloadedArchive.responseURL)
        let inspection = try await dependencies.archive.inspect(
            archiveURL: archiveFile,
            temporaryDirectory: temporaryDirectory,
            limits: limits
        )
        try Task.checkCancellation()

        let executable = temporaryDirectory.appendingPathComponent("forge3")
        try dependencies.archive.extractExecutable(from: inspection, to: executable)
        try Self.applyDownloadQuarantine(to: executable, sourceURL: downloadedArchive.responseURL)
        try? FileManager.default.removeItem(at: archiveFile)
        try? FileManager.default.removeItem(at: inspection.tarURL)
        try dependencies.validator.validate(executableURL: executable, expectedArchitecture: architecture)
        dependencies.validationTracer.record(.initialMachOValidated)
        let executableChecksum = try RuntimeSHA256.hexDigest(ofFile: executable)
        let validatedIdentity = try RuntimeExecutableIdentityValidator.capture(
            executable,
            expectedSHA256: executableChecksum
        )
        dependencies.validationTracer.record(.initialIdentityAndHashValidated)
        let executionIdentity = try Self.applyPreExecutionTrustPolicy(
            executableURL: executable,
            architecture: architecture,
            validatedIdentity: validatedIdentity,
            dependencies: dependencies
        )
        try RuntimeExecutableIdentityValidator.validate(executable, expected: executionIdentity)
        stagingLease?.release()
        stagingLeaseReleased = true
        let receipt = RuntimeStoreReceipt(
            version: version,
            architecture: architecture,
            archiveSHA256: actualChecksum,
            executableSHA256: executableChecksum
        )
        try Task.checkCancellation()
        await progress(.installing)
        let installed = try dependencies.store.installStagedRuntime(
            executableURL: executable,
            receipt: receipt,
            temporaryDirectory: temporaryDirectory
        )
        temporaryDirectoryOwned = false
        return installed
    }

    private static func applyPreExecutionTrustPolicy(
        executableURL: URL,
        architecture: RuntimeArchitecture,
        validatedIdentity: RuntimeExecutableIdentity,
        dependencies: Dependencies
    ) throws -> RuntimeExecutableIdentity {
        try Task.checkCancellation()
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: validatedIdentity)
        let signature = try dependencies.signatureInspector.inspectSignature(of: executableURL)
        dependencies.validationTracer.record(.initialSignatureClassInspected)
        try dependencies.developerIDAuthenticationPolicy.authenticate(
            signature,
            executableURL: executableURL,
            requirementEvaluator: dependencies.developerIDRequirementEvaluator
        )
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: validatedIdentity)
        let hasQuarantine = try dependencies.quarantineManager.hasQuarantine(
            at: executableURL,
            expectedIdentity: validatedIdentity
        )
        dependencies.validationTracer.record(.initialQuarantineInspected)
        let context = RuntimePreExecutionTrustContext(
            signature: signature,
            hasQuarantine: hasQuarantine,
            architecture: architecture,
            executableIdentity: validatedIdentity
        )
        let decision = try dependencies.trustPolicy.decision(for: context)
        dependencies.validationTracer.record(.trustPolicyEvaluated)
        switch decision {
        case .preserve:
            return validatedIdentity
        case .refreshRemovingQuarantine:
            guard signature.signatureClass == .adHoc, hasQuarantine else {
                throw RuntimeInstallerError.quarantineRemovalFailed(
                    "the pre-execution trust policy attempted quarantine removal outside the ad-hoc quarantined case"
                )
            }
            let refreshedIdentity = try dependencies.quarantineManager
                .refreshExecutableRemovingQuarantine(
                    from: executableURL,
                    expectedIdentity: validatedIdentity
                )
            dependencies.validationTracer.record(.stagedVnodeRefreshed)
            try RuntimeExecutableIdentityValidator.validate(executableURL, expected: refreshedIdentity)
            dependencies.validationTracer.record(.postRefreshIdentityAndHashValidated)
            try dependencies.validator.validate(
                executableURL: executableURL,
                expectedArchitecture: architecture
            )
            dependencies.validationTracer.record(.postRefreshMachOValidated)
            let refreshedSignature = try dependencies.signatureInspector.inspectSignature(of: executableURL)
            guard refreshedSignature.signatureClass == .adHoc else {
                throw RuntimeInstallerError.invalidMachO(
                    "the refreshed staged executable is no longer ad-hoc signed"
                )
            }
            dependencies.validationTracer.record(.postRefreshSignatureClassInspected)
            try RuntimeExecutableIdentityValidator.validate(executableURL, expected: refreshedIdentity)
            guard !(try dependencies.quarantineManager.hasQuarantine(
                at: executableURL,
                expectedIdentity: refreshedIdentity
            )) else {
                throw RuntimeInstallerError.quarantineRemovalFailed(
                    "the refreshed staged executable still has com.apple.quarantine"
                )
            }
            dependencies.validationTracer.record(.postRefreshQuarantineValidated)
            dependencies.securityLogger.log(.refreshedAdHocQuarantinedStagedExecutable)
            return refreshedIdentity
        }
    }

    private static func applyDownloadQuarantine(to url: URL, sourceURL: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
            "LSQuarantineAgentName": "Forge Menu Bar",
            "LSQuarantineDataURL": sourceURL
        ]
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "apply download quarantine", path: url.path)
        }
    }
}
