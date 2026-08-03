import Darwin
import Foundation

public protocol ForgeProcessHosting: AnyObject, Sendable {
    var onExit: (@Sendable (_ status: Int32, _ runtime: TimeInterval, _ generation: UInt64) -> Void)? { get set }
    func start(runtime: InstalledRuntime, endpoint: LoopbackEndpoint, generation: UInt64) async throws
    func stop(gracePeriod: TimeInterval) async
}

public protocol InstalledRuntimeIdentityValidating: Sendable {
    func validate(_ runtime: InstalledRuntime) throws
}

public struct InstalledRuntimeIdentityValidator: InstalledRuntimeIdentityValidating {
    private let expectedUserID: uid_t

    public init(expectedUserID: uid_t = geteuid()) {
        self.expectedUserID = expectedUserID
    }

    public func validate(_ runtime: InstalledRuntime) throws {
        let pinned = try RuntimePinnedExecutable(
            url: runtime.executableURL,
            expectedUserID: expectedUserID
        )
        defer { pinned.close() }
        try pinned.validateCurrentFile()
    }
}

public final class ForgeProcessHost: ForgeProcessHosting, @unchecked Sendable {
    private static let postReapDrainBytes = 64 * 1_024
    private static let postReapDrainInterval: TimeInterval = 0.1

    public struct Configuration: Sendable {
        public let environment: [String: String]
        public let logURL: URL
        public let maximumLogBytes: UInt64
        public let retainedLogFiles: Int
        public let maximumBufferedOutputBytes: Int
        public let launchHooks: RuntimePinnedLaunchHooks
        public let guardianExecutableURL: URL
        public let guardianLaunchTimeout: TimeInterval

        public init(
            environment: [String: String] = [:],
            logURL: URL,
            maximumLogBytes: UInt64 = 5_000_000,
            retainedLogFiles: Int = 3,
            maximumBufferedOutputBytes: Int = 256_000,
            launchHooks: RuntimePinnedLaunchHooks = RuntimePinnedLaunchHooks(),
            guardianExecutableURL: URL? = nil,
            guardianLaunchTimeout: TimeInterval = 5
        ) {
            self.environment = environment
            self.logURL = logURL
            self.maximumLogBytes = maximumLogBytes
            self.retainedLogFiles = retainedLogFiles
            self.maximumBufferedOutputBytes = max(4_096, maximumBufferedOutputBytes)
            self.launchHooks = launchHooks
            self.guardianExecutableURL = guardianExecutableURL
                ?? Self.defaultGuardianExecutableURL()
            self.guardianLaunchTimeout = max(0.1, guardianLaunchTimeout)
        }

        private static func defaultGuardianExecutableURL() -> URL {
            // XCTest's bundle executable cannot enter the production app's
            // internal mode. The already-built lease helper links the same
            // core and exposes that mode solely for integration tests.
            let bundleURL = Bundle.main.bundleURL
            let candidates = [
                bundleURL.deletingLastPathComponent().appendingPathComponent("ForgeRuntimeLeaseTestHelper"),
                bundleURL.appendingPathComponent("ForgeRuntimeLeaseTestHelper"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/debug/ForgeRuntimeLeaseTestHelper")
            ]
            if let testHelper = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) {
                return testHelper
            }
            return Bundle.main.executableURL
                ?? URL(fileURLWithPath: CommandLine.arguments[0])
        }
    }

    public var onExit: (@Sendable (_ status: Int32, _ runtime: TimeInterval, _ generation: UInt64) -> Void)? {
        get { queue.sync { exitHandler } }
        set { queue.sync { exitHandler = newValue } }
    }

    private let configuration: Configuration
    private let logger: AppLogger
    private let runtimeIdentityValidator: any InstalledRuntimeIdentityValidating
    private let lease: RuntimeStoreLease?
    private let queue = DispatchQueue(label: "dev.forgecode.menubar.process-host")
    private let logWriter: RotatingLogWriter
    private var exitHandler: (@Sendable (_ status: Int32, _ runtime: TimeInterval, _ generation: UInt64) -> Void)?
    private var guardianPID: pid_t = 0
    private var serviceIdentity: ForgeLifecycleGuardian.ProcessIdentity?
    private var controlDescriptor: Int32 = -1
    private var startedAt: Date?
    private var lifecycleGeneration: UInt64 = 0
    private var lifecycleToken: UInt64 = 0
    private var nextLifecycleToken: UInt64 = 0
    private var stopping = false
    private var stopEscalation: DispatchWorkItem?
    private var guardianSource: DispatchSourceProcess?
    private var outputSource: DispatchSourceRead?
    private var outputDescriptor: Int32 = -1
    private var outputBuffer = Data()
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: Configuration,
        logger: AppLogger = .shared,
        runtimeIdentityValidator: any InstalledRuntimeIdentityValidating = InstalledRuntimeIdentityValidator(),
        lease: RuntimeStoreLease? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        self.runtimeIdentityValidator = runtimeIdentityValidator
        self.lease = lease
        self.logWriter = RotatingLogWriter(
            fileManager: .default,
            logURL: configuration.logURL,
            maximumBytes: configuration.maximumLogBytes,
            retainedFiles: configuration.retainedLogFiles
        )
    }

    public func start(runtime: InstalledRuntime, endpoint: LoopbackEndpoint, generation: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startLocked(runtime: runtime, endpoint: endpoint, generation: generation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func lifecycleProcessIDs() -> (guardian: pid_t, service: pid_t) {
        queue.sync { (guardianPID, serviceIdentity?.pid ?? 0) }
    }

    func closeLifecycleControlForTesting() {
        queue.sync {
            guard controlDescriptor >= 0 else { return }
            Darwin.close(controlDescriptor)
            controlDescriptor = -1
        }
    }

    public func stop(gracePeriod: TimeInterval = 3) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.guardianPID > 0 else {
                    continuation.resume()
                    return
                }

                self.stopWaiters.append(continuation)
                guard !self.stopping else { return }
                self.stopping = true
                let expectedGuardianPID = self.guardianPID
                let expectedServiceIdentity = self.serviceIdentity
                let expectedToken = self.lifecycleToken
                self.logger.info("Stopping forge3 process group \(expectedServiceIdentity?.pid ?? 0) through lifecycle guardian \(expectedGuardianPID)")
                self.requestGuardianStopLocked(gracePeriod: gracePeriod)

                let escalation = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.guardianPID == expectedGuardianPID,
                          self.serviceIdentity == expectedServiceIdentity,
                          self.lifecycleToken == expectedToken,
                          self.stopping
                    else { return }
                    self.logger.warning("forge3 did not terminate within \(String(format: "%.1f", gracePeriod)) seconds; forcing process-group and guardian cleanup")
                    // The guardian is the still-waitable process-group leader,
                    // so its PID pins the PGID against reuse. Kill the complete
                    // lifecycle group before reaping the guardian.
                    _ = kill(-expectedGuardianPID, SIGKILL)
                    self.reapGuardianLocked(expectedGuardianPID, lifecycleToken: expectedToken)
                }
                self.stopEscalation?.cancel()
                self.stopEscalation = escalation
                self.queue.asyncAfter(deadline: .now() + max(0, gracePeriod) + 0.25, execute: escalation)
            }
        }
    }

    private func startLocked(runtime: InstalledRuntime, endpoint: LoopbackEndpoint, generation: UInt64) throws {
        guard guardianPID == 0 else { throw ForgeCoreError.processAlreadyRunning }
        try runtimeIdentityValidator.validate(runtime)
        let selectedExecutable = runtime.executableURL.standardizedFileURL
        let pinnedExecutable = try RuntimePinnedExecutable(url: selectedExecutable)
        defer { pinnedExecutable.close() }
        guard FileManager.default.isExecutableFile(atPath: selectedExecutable.path) else {
            throw ForgeCoreError.missingExecutable(selectedExecutable.path)
        }
        try pinnedExecutable.prepareForLaunch(hooks: configuration.launchHooks)
        let metadata = try pinnedExecutable.currentFileMetadata()

        var controlPair = [Int32](repeating: -1, count: 2)
        var statusPair = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &controlPair) == 0 else {
            throw ForgeCoreError.processLaunch("could not create guardian control socket: \(String(cString: strerror(errno)))")
        }
        defer { closePair(&controlPair) }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &statusPair) == 0 else {
            throw ForgeCoreError.processLaunch("could not create guardian status socket: \(String(cString: strerror(errno)))")
        }
        defer { closePair(&statusPair) }
        guard pipe(&outputPipe) == 0 else {
            throw ForgeCoreError.processLaunch("could not create logging pipe: \(String(cString: strerror(errno)))")
        }
        defer { closePair(&outputPipe) }

        // Duplicate every child resource above the reserved range before
        // constructing any dup2 action. Sources are therefore unique and can
        // never be clobbered when arbitrary parent descriptors occupy 20...23
        // or when the original source/destination graph contains a cycle.
        let guardianSources = try [
            duplicateForGuardian(controlPair[1]),
            duplicateForGuardian(statusPair[1]),
            duplicateForGuardian(outputPipe[1]),
            duplicateForGuardian(pinnedExecutable.directoryDescriptor)
        ]
        defer { guardianSources.forEach { Darwin.close($0) } }
        let guardianDestinations = [
            ForgeLifecycleGuardian.controlDescriptor,
            ForgeLifecycleGuardian.statusDescriptor,
            ForgeLifecycleGuardian.outputDescriptor,
            ForgeLifecycleGuardian.runtimeDirectoryDescriptor
        ]
        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&actions), operation: "initialize guardian file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, destination) in zip(guardianSources, guardianDestinations) {
            try checkPOSIX(
                posix_spawn_file_actions_adddup2(&actions, source, destination),
                operation: "map guardian descriptor"
            )
        }
        let arguments = [
            configuration.guardianExecutableURL.path,
            ForgeLifecycleGuardian.modeArgument,
            selectedExecutable.path,
            pinnedExecutable.basename,
            String(endpoint.port),
            String(metadata.device),
            String(metadata.inode),
            String(ForgeLifecycleGuardian.controlDescriptor),
            String(ForgeLifecycleGuardian.statusDescriptor),
            String(ForgeLifecycleGuardian.outputDescriptor),
            String(ForgeLifecycleGuardian.runtimeDirectoryDescriptor),
            String(UInt64(configuration.guardianLaunchTimeout * 1_000))
        ]
        var guardianEnvironment = Self.sanitizedEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: configuration.environment
        )
        if let lease {
            guardianEnvironment["FORGE_INTERNAL_RUNTIME_LEASE_ROOT"] = lease.rootURL.path
        }
        let environmentStrings = guardianEnvironment.keys.sorted().compactMap { key in
            guardianEnvironment[key].map { "\(key)=\($0)" }
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes), operation: "initialize guardian attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
            ),
            operation: "enable guardian process-group and close-on-exec isolation"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "make guardian the lifecycle process-group leader"
        )

        var spawnedGuardianPID: pid_t = 0
        let spawnResult = posix_spawn(
            &spawnedGuardianPID,
            configuration.guardianExecutableURL.path,
            &actions,
            &attributes,
            &argv,
            &envp
        )
        guard spawnResult == 0 else {
            throw ForgeCoreError.processLaunch(String(cString: strerror(spawnResult)))
        }
        close(controlPair[1]); controlPair[1] = -1
        close(statusPair[1]); statusPair[1] = -1
        close(outputPipe[1]); outputPipe[1] = -1

        do {
            let launchDeadline = ForgeLifecycleGuardian.deadline(
                after: configuration.guardianLaunchTimeout
            )
            let packet = try readGuardianStatus(
                descriptor: statusPair[0],
                deadline: launchDeadline
            )
            guard ForgeLifecycleGuardian.validateStatusPacket(packet) else {
                throw ForgeCoreError.processLaunch("lifecycle guardian rejected forge3 launch (\(packet.result))")
            }
            let identity = ForgeLifecycleGuardian.identity(from: packet)
            try sendGuardianControlPacket(
                ForgeLifecycleGuardian.startAcknowledgementPacket(),
                descriptor: controlPair[0],
                deadline: launchDeadline
            )
            close(statusPair[0]); statusPair[0] = -1

            guardianPID = spawnedGuardianPID
            serviceIdentity = identity
            controlDescriptor = controlPair[0]
            controlPair[0] = -1
            startedAt = Date()
            lifecycleGeneration = generation
            nextLifecycleToken &+= 1
            lifecycleToken = nextLifecycleToken
            let processToken = lifecycleToken
            stopping = false
            stopEscalation?.cancel()
            stopEscalation = nil
            beginReadingOutputLocked(descriptor: outputPipe[0])
            outputPipe[0] = -1

            let source = DispatchSource.makeProcessSource(
                identifier: spawnedGuardianPID,
                eventMask: .exit,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.reapGuardianLocked(spawnedGuardianPID, lifecycleToken: processToken)
            }
            guardianSource = source
            source.resume()
            logger.info("Started forge3 process group \(packet.servicePID) through lifecycle guardian \(spawnedGuardianPID) from \(selectedExecutable.path) on private loopback port \(endpoint.port)")
        } catch {
            close(controlPair[0]); controlPair[0] = -1
            close(statusPair[0]); statusPair[0] = -1
            // Ownership begins when posix_spawn returns the guardian PID. The
            // guardian is the new process-group leader and remains our child,
            // so the PGID cannot be reused before waitpid. Every failed launch
            // kills the complete lifecycle group first, then reaps the guardian.
            _ = kill(-spawnedGuardianPID, SIGKILL)
            while waitpid(spawnedGuardianPID, nil, 0) == -1 && errno == EINTR {}
            throw error
        }
    }

    private func readGuardianStatus(
        descriptor: Int32,
        deadline: UInt64
    ) throws -> ForgeLifecycleGuardian.GuardianStatusPacket {
        var packet = ForgeLifecycleGuardian.GuardianStatusPacket(
            magic: 0,
            result: EIO,
            servicePID: 0,
            serviceStartSeconds: 0,
            serviceStartMicroseconds: 0
        )
        let frameResult = withUnsafeMutableBytes(of: &packet) { bytes in
            ForgeLifecycleGuardian.readCompleteFrame(
                descriptor: descriptor,
                bytes: bytes,
                deadline: deadline
            )
        }
        switch frameResult {
        case .complete:
            return packet
        case .closed:
            // Status observation never consumes child ownership. The launch
            // failure path must first signal the lifecycle group while the
            // unreaped guardian still pins its PGID, then perform the sole
            // waitpid below.
            throw ForgeCoreError.processLaunch("lifecycle guardian exited before forge3 was ready")
        case .failed:
            throw ForgeCoreError.processLaunch("lifecycle guardian launch timed out or returned an incomplete status packet")
        }
    }

    private func sendGuardianControlPacket(
        _ packet: ForgeLifecycleGuardian.ControlPacket,
        descriptor: Int32,
        deadline: UInt64
    ) throws {
        var packet = packet
        let complete = withUnsafeBytes(of: &packet) { bytes in
            ForgeLifecycleGuardian.writeCompleteFrame(
                descriptor: descriptor,
                bytes: bytes,
                deadline: deadline
            )
        }
        guard complete else {
            throw ForgeCoreError.processLaunch("could not send complete lifecycle guardian control packet")
        }
    }

    private func requestGuardianStopLocked(gracePeriod: TimeInterval) {
        guard controlDescriptor >= 0 else { return }
        do {
            try sendGuardianControlPacket(
                ForgeLifecycleGuardian.stopPacket(gracePeriod: gracePeriod),
                descriptor: controlDescriptor,
                deadline: ForgeLifecycleGuardian.deadline(
                    after: configuration.guardianLaunchTimeout
                )
            )
        } catch {
            logger.error(error.localizedDescription)
        }
        Darwin.close(controlDescriptor)
        controlDescriptor = -1
    }

    private func beginReadingOutputLocked(descriptor: Int32) {
        outputDescriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let count = min(16_384, max(1, Int(source.data)))
            var bytes = [UInt8](repeating: 0, count: count)
            let received = read(descriptor, &bytes, bytes.count)
            if received > 0 {
                self.appendOutputLocked(bytes, count: received)
            } else if received == 0 {
                source.cancel()
            }
        }
        source.setCancelHandler { close(descriptor) }
        outputSource = source
        source.resume()
    }

    private func appendOutputLocked(_ bytes: [UInt8], count: Int) {
        outputBuffer.append(bytes, count: count)
        flushCompleteLogLinesLocked()
        guard outputBuffer.count > configuration.maximumBufferedOutputBytes else { return }

        let retainedCount = configuration.maximumBufferedOutputBytes / 2
        let droppedCount = outputBuffer.count - retainedCount
        outputBuffer.removeFirst(droppedCount)
        logWriter.append("[forge3 output truncated: \(droppedCount) bytes without a newline]\n")
    }

    private func flushCompleteLogLinesLocked() {
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            logWriter.append(Redactor.redact(String(decoding: line, as: UTF8.self)) + "\n")
        }
    }

    private func flushRemainingOutputLocked() {
        guard !outputBuffer.isEmpty else { return }
        logWriter.append(Redactor.redact(String(decoding: outputBuffer, as: UTF8.self)) + "\n")
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func drainOutputLocked() {
        guard outputDescriptor >= 0 else { return }
        // Match the bounded final-drain policy used by RuntimeProcess. An
        // escaped session can retain this pipe and write forever after the
        // guardian is reaped, so EOF is not a valid lifecycle completion gate.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var bytesRemaining = Self.postReapDrainBytes
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.nanoseconds(Self.postReapDrainInterval)
        while bytesRemaining > 0,
              DispatchTime.now().uptimeNanoseconds < deadline {
            let requested = min(bytes.count, bytesRemaining)
            let received = read(outputDescriptor, &bytes, requested)
            if received > 0 {
                appendOutputLocked(bytes, count: received)
                bytesRemaining -= received
            } else if received == -1 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func reapGuardianLocked(_ expectedGuardianPID: pid_t, lifecycleToken expectedToken: UInt64) {
        guard guardianPID == expectedGuardianPID, lifecycleToken == expectedToken else { return }
        stopEscalation?.cancel()
        stopEscalation = nil

        // The unreaped guardian remains the lifecycle process-group leader,
        // pinning the PGID against reuse even if forge3 has already exited.
        // Kill all descendants before the waitpid below releases that identity.
        _ = kill(-expectedGuardianPID, SIGKILL)
        var status: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(expectedGuardianPID, &status, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult == expectedGuardianPID || (waitResult == -1 && errno == ECHILD) else {
            logger.error("Could not reap lifecycle guardian \(expectedGuardianPID): \(String(cString: strerror(errno)))")
            return
        }

        let exitStatus = decodedExitStatus(status)
        let runtime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let exitedGeneration = lifecycleGeneration
        let intentional = stopping
        guardianSource?.cancel()
        guardianSource = nil
        if controlDescriptor >= 0 { Darwin.close(controlDescriptor) }
        controlDescriptor = -1
        outputSource?.cancel()
        outputSource = nil
        drainOutputLocked()
        outputDescriptor = -1
        flushRemainingOutputLocked()
        guardianPID = 0
        serviceIdentity = nil
        startedAt = nil
        lifecycleGeneration = 0
        lifecycleToken = 0
        stopping = false
        finishStopWaitersLocked()
        logger.info("forge3 lifecycle guardian exited with status \(exitStatus) after \(String(format: "%.1f", runtime)) seconds")
        if !intentional {
            exitHandler?(exitStatus, runtime, exitedGeneration)
        }
    }

    private func finishStopWaitersLocked() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func duplicateForGuardian(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard duplicate >= 0 else {
            throw ForgeCoreError.processLaunch(
                "could not isolate guardian descriptor: \(String(cString: strerror(errno)))"
            )
        }
        return duplicate
    }

    private func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ForgeCoreError.processLaunch(
                "could not \(operation): \(String(cString: strerror(result)))"
            )
        }
    }

    private func closePair(_ descriptors: inout [Int32]) {
        for index in descriptors.indices where descriptors[index] >= 0 {
            Darwin.close(descriptors[index])
            descriptors[index] = -1
        }
    }

    private func decodedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return status
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        let value = interval * 1_000_000_000
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    static func sanitizedEnvironment(
        inherited: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        let allowedExact: Set<String> = [
            "HOME", "PATH", "SHELL", "TMPDIR", "USER", "LOGNAME",
            "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"
        ]
        let allowedPrefixes = ["FORGE_", "RUST_LOG"]
        var result = inherited.filter { key, _ in
            allowedExact.contains(key) || allowedPrefixes.contains { key.hasPrefix($0) }
        }
        for (key, value) in overrides {
            result[key] = value
        }
        if result["PATH"] == nil {
            result["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return result
    }
}
