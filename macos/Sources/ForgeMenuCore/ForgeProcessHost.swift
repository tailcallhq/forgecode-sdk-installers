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
    public struct Configuration: Sendable {
        public let environment: [String: String]
        public let logURL: URL
        public let maximumLogBytes: UInt64
        public let retainedLogFiles: Int
        public let maximumBufferedOutputBytes: Int
        public let launchHooks: RuntimePinnedLaunchHooks

        public init(
            environment: [String: String] = [:],
            logURL: URL,
            maximumLogBytes: UInt64 = 5_000_000,
            retainedLogFiles: Int = 3,
            maximumBufferedOutputBytes: Int = 256_000,
            launchHooks: RuntimePinnedLaunchHooks = RuntimePinnedLaunchHooks()
        ) {
            self.environment = environment
            self.logURL = logURL
            self.maximumLogBytes = maximumLogBytes
            self.retainedLogFiles = retainedLogFiles
            self.maximumBufferedOutputBytes = max(4_096, maximumBufferedOutputBytes)
            self.launchHooks = launchHooks
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
    private var pid: pid_t = 0
    private var startedAt: Date?
    private var lifecycleGeneration: UInt64 = 0
    private var lifecycleToken: UInt64 = 0
    private var nextLifecycleToken: UInt64 = 0
    private var stopping = false
    private var stopEscalation: DispatchWorkItem?
    private var processSource: DispatchSourceProcess?
    private var outputSource: DispatchSourceRead?
    private var outputDescriptor: Int32 = -1
    private var outputBuffer = Data()
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var executionLeaseToken: RuntimeStoreLease.Token?

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

    public func stop(gracePeriod: TimeInterval = 3) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.pid > 0 else {
                    continuation.resume()
                    return
                }

                self.stopWaiters.append(continuation)
                guard !self.stopping else { return }
                self.stopping = true
                let expectedPID = self.pid
                let expectedToken = self.lifecycleToken
                self.logger.info("Stopping forge3 process group \(expectedPID)")
                _ = kill(-expectedPID, SIGTERM)

                let escalation = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.pid == expectedPID,
                          self.lifecycleToken == expectedToken,
                          self.stopping
                    else { return }
                    self.logger.warning("forge3 did not terminate within \(String(format: "%.1f", gracePeriod)) seconds; sending SIGKILL")
                    _ = kill(-expectedPID, SIGKILL)
                    guard self.pid == expectedPID,
                          self.lifecycleToken == expectedToken,
                          self.stopping
                    else { return }
                    self.reapExitedProcessLocked(expectedPID, lifecycleToken: expectedToken)
                }
                self.stopEscalation?.cancel()
                self.stopEscalation = escalation
                self.queue.asyncAfter(deadline: .now() + max(0, gracePeriod), execute: escalation)
            }
        }
    }

    private func startLocked(runtime: InstalledRuntime, endpoint: LoopbackEndpoint, generation: UInt64) throws {
        guard pid == 0 else { throw ForgeCoreError.processAlreadyRunning }
        try runtimeIdentityValidator.validate(runtime)
        let executionLease = try lease?.acquire(.sharedExecution)
        var retainExecutionLease = false
        defer {
            if !retainExecutionLease { executionLease?.release() }
        }
        let selectedExecutable = runtime.executableURL.standardizedFileURL
        let pinnedExecutable = try RuntimePinnedExecutable(url: selectedExecutable)
        defer { pinnedExecutable.close() }
        guard FileManager.default.isExecutableFile(atPath: selectedExecutable.path) else {
            throw ForgeCoreError.missingExecutable(selectedExecutable.path)
        }

        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw ForgeCoreError.processLaunch("could not create logging pipe: \(String(cString: strerror(errno)))")
        }
        var readDescriptor = descriptors[0]
        var writeDescriptor = descriptors[1]
        defer {
            if readDescriptor >= 0 { close(readDescriptor) }
            if writeDescriptor >= 0 { close(writeDescriptor) }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ForgeCoreError.processLaunch("could not initialize process file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try pinnedExecutable.addDirectoryActions(to: &actions)
        try checkPOSIX(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            operation: "redirect stdin"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO),
            operation: "redirect stdout"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO),
            operation: "redirect stderr"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&actions, readDescriptor),
            operation: "close child logging input"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&actions, writeDescriptor),
            operation: "close child logging output"
        )

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ForgeCoreError.processLaunch("could not initialize process attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "enable process-group creation"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "configure process group"
        )

        let arguments = [
            pinnedExecutable.basename,
            "--log-format", "json",
            "ws", "--addr", endpoint.address
        ]
        let environment = Self.sanitizedEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: configuration.environment
        )
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var spawnedPID: pid_t = 0
        let result = try pinnedExecutable.spawn(
            pid: &spawnedPID,
            actions: &actions,
            attributes: &attributes,
            argv: &argv,
            envp: &envp,
            hooks: configuration.launchHooks
        )
        close(writeDescriptor)
        writeDescriptor = -1
        guard result == 0 else {
            throw ForgeCoreError.processLaunch(String(cString: strerror(result)))
        }

        pid = spawnedPID
        executionLeaseToken = executionLease
        retainExecutionLease = true
        startedAt = Date()
        lifecycleGeneration = generation
        nextLifecycleToken &+= 1
        lifecycleToken = nextLifecycleToken
        let processToken = lifecycleToken
        stopping = false
        stopEscalation?.cancel()
        stopEscalation = nil
        beginReadingOutputLocked(descriptor: readDescriptor)
        readDescriptor = -1

        let source = DispatchSource.makeProcessSource(identifier: spawnedPID, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.reapExitedProcessLocked(spawnedPID, lifecycleToken: processToken)
        }
        processSource = source
        source.resume()
        logger.info("Started forge3 process group \(spawnedPID) from \(selectedExecutable.path) on private loopback port \(endpoint.port)")
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
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let received = read(outputDescriptor, &bytes, bytes.count)
            if received > 0 {
                appendOutputLocked(bytes, count: received)
            } else {
                return
            }
        }
    }

    private func reapExitedProcessLocked(_ expectedPID: pid_t, lifecycleToken expectedToken: UInt64) {
        guard pid == expectedPID, lifecycleToken == expectedToken else { return }
        stopEscalation?.cancel()
        stopEscalation = nil
        // The child has not been reaped yet, so its PID cannot be reused. This
        // is the final safe point to clean up any descendants in its group.
        _ = kill(-expectedPID, SIGKILL)
        var status: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(expectedPID, &status, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult == expectedPID || (waitResult == -1 && errno == ECHILD) else {
            logger.error("Could not reap forge3 process \(expectedPID): \(String(cString: strerror(errno)))")
            return
        }

        let signal = status & 0x7f
        let exitStatus: Int32
        if signal == 0 {
            exitStatus = (status >> 8) & 0xff
        } else if signal != 0x7f {
            exitStatus = 128 + signal
        } else {
            exitStatus = status
        }

        let runtime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let exitedGeneration = lifecycleGeneration
        let intentional = stopping
        processSource?.cancel()
        processSource = nil
        drainOutputLocked()
        outputSource?.cancel()
        outputSource = nil
        outputDescriptor = -1
        flushRemainingOutputLocked()
        pid = 0
        executionLeaseToken?.release()
        executionLeaseToken = nil
        startedAt = nil
        lifecycleGeneration = 0
        lifecycleToken = 0
        stopping = false
        finishStopWaitersLocked()
        logger.info("forge3 exited with status \(exitStatus) after \(String(format: "%.1f", runtime)) seconds")
        if !intentional {
            exitHandler?(exitStatus, runtime, exitedGeneration)
        }
    }

    private func finishStopWaitersLocked() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ForgeCoreError.processLaunch(
                "could not \(operation): \(String(cString: strerror(result)))"
            )
        }
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
