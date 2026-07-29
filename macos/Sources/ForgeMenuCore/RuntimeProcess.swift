import Darwin
import Foundation

public struct RuntimeProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let standardOutputLimitExceeded: Bool

    public init(
        status: Int32,
        stdout: Data = Data(),
        stderr: Data = Data(),
        standardOutputLimitExceeded: Bool = false
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.standardOutputLimitExceeded = standardOutputLimitExceeded
    }
}

public enum RuntimeExecutionProbeResult: Sendable, Equatable {
    case succeeded
    case timedOut
    case executionUnavailable(String)
    case failed(String)
    case versionMismatch(expected: String, actual: String)
}

public protocol RuntimeExecutionProbing: Sendable {
    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion
    ) async throws -> RuntimeExecutionProbeResult
}

public protocol RuntimeIdentityPinnedExecutionProbing: RuntimeExecutionProbing {
    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeExecutionProbeResult
}

public extension RuntimeExecutionProbing {
    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeExecutionProbeResult {
        if let probe = self as? any RuntimeIdentityPinnedExecutionProbing {
            return try await probe.probe(
                executableURL: executableURL,
                expectedVersion: expectedVersion,
                expectedIdentity: expectedIdentity
            )
        }
        return try await probe(
            executableURL: executableURL,
            expectedVersion: expectedVersion
        )
    }
}

public struct BoundedRuntimeExecutionProbe: RuntimeIdentityPinnedExecutionProbing {
    private let processRunner: any RuntimeProcessRunning
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let maximumOutputBytes: Int
    private let lease: RuntimeStoreLease?

    public init(
        processRunner: any RuntimeProcessRunning = POSIXRuntimeProcessRunner(),
        timeout: TimeInterval = 8,
        terminationGracePeriod: TimeInterval = 0.2,
        maximumOutputBytes: Int = 4_096,
        lease: RuntimeStoreLease? = nil
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.maximumOutputBytes = maximumOutputBytes
        self.lease = lease
    }

    public func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion
    ) async throws -> RuntimeExecutionProbeResult {
        try await probe(
            executableURL: executableURL,
            expectedVersion: expectedVersion,
            expectedIdentity: nil
        )
    }

    public func probe(installedRuntime: InstalledRuntime) async throws -> RuntimeExecutionProbeResult {
        try installedRuntime.validateExecutableIdentity()
        try Task.checkCancellation()
        return try await probe(
            executableURL: installedRuntime.executableURL,
            expectedVersion: installedRuntime.version,
            expectedIdentity: installedRuntime.executableIdentity
        )
    }

    public func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeExecutionProbeResult {
        let result: RuntimeProcessResult
        let leaseToken = try lease?.acquire(.sharedExecution)
        defer { leaseToken?.release() }
        do {
            result = try await processRunner.run(
                executable: executableURL,
                arguments: ["--version"],
                standardOutput: nil,
                maximumStandardOutputBytes: maximumOutputBytes,
                timeout: timeout,
                terminationGracePeriod: terminationGracePeriod,
                expectedIdentity: expectedIdentity
            )
        } catch RuntimeInstallerError.processTimeout {
            return .timedOut
        } catch RuntimeInstallerError.processLaunchDenied(let message) {
            return .executionUnavailable(message)
        } catch RuntimeInstallerError.processFailure(let message) {
            return .failed(message)
        } catch RuntimeInstallerError.cancelled {
            throw RuntimeInstallerError.cancelled
        } catch is CancellationError {
            throw RuntimeInstallerError.cancelled
        }

        guard !result.standardOutputLimitExceeded else {
            return .failed("forge3 --version exceeded the output limit")
        }
        guard result.status == 0 else {
            let diagnostic = Self.diagnostic(from: result.stderr)
            return .failed(diagnostic.isEmpty ? "forge3 --version exited with status \(result.status)" : diagnostic)
        }

        let expected = "forge3 \(expectedVersion.rawValue)"
        if Self.isExactVersionOutput(result.stdout, expected: expected) {
            return .succeeded
        }
        return .versionMismatch(
            expected: expected,
            actual: Self.displayOutput(result.stdout)
        )
    }

    private static func isExactVersionOutput(_ data: Data, expected: String) -> Bool {
        data == Data(expected.utf8)
            || data == Data("\(expected)\n".utf8)
            || data == Data("\(expected)\r\n".utf8)
    }

    private static func displayOutput(_ data: Data) -> String {
        var value = String(decoding: data.prefix(4_096), as: UTF8.self)
        if value.hasSuffix("\r\n") { value.removeLast(2) }
        else if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    private static func diagnostic(from data: Data) -> String {
        String(decoding: data.prefix(1_024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol RuntimeProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval
    ) async throws -> RuntimeProcessResult
}

public protocol RuntimeIdentityPinnedProcessRunning: RuntimeProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeProcessResult
}

public extension RuntimeProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeProcessResult {
        if let runner = self as? any RuntimeIdentityPinnedProcessRunning {
            return try await runner.run(
                executable: executable,
                arguments: arguments,
                standardOutput: standardOutput,
                maximumStandardOutputBytes: maximumStandardOutputBytes,
                timeout: timeout,
                terminationGracePeriod: terminationGracePeriod,
                expectedIdentity: expectedIdentity
            )
        }
        return try await run(
            executable: executable,
            arguments: arguments,
            standardOutput: standardOutput,
            maximumStandardOutputBytes: maximumStandardOutputBytes,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod
        )
    }

    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int
    ) async throws -> RuntimeProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            standardOutput: standardOutput,
            maximumStandardOutputBytes: maximumStandardOutputBytes,
            timeout: 60,
            terminationGracePeriod: 1
        )
    }
}

public struct POSIXRuntimeProcessRunner: RuntimeIdentityPinnedProcessRunning {
    private let launchHooks: RuntimePinnedLaunchHooks

    public init(launchHooks: RuntimePinnedLaunchHooks = RuntimePinnedLaunchHooks()) {
        self.launchHooks = launchHooks
    }

    public func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL? = nil,
        maximumStandardOutputBytes: Int = 1_024 * 1_024,
        timeout: TimeInterval = 60,
        terminationGracePeriod: TimeInterval = 1
    ) async throws -> RuntimeProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            standardOutput: standardOutput,
            maximumStandardOutputBytes: maximumStandardOutputBytes,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            expectedIdentity: nil
        )
    }

    public func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL? = nil,
        maximumStandardOutputBytes: Int = 1_024 * 1_024,
        timeout: TimeInterval = 60,
        terminationGracePeriod: TimeInterval = 1,
        expectedIdentity: RuntimeExecutableIdentity?
    ) async throws -> RuntimeProcessResult {
        try Task.checkCancellation()
        guard maximumStandardOutputBytes >= 0,
              timeout.isFinite, timeout > 0,
              terminationGracePeriod.isFinite, terminationGracePeriod >= 0 else {
            throw RuntimeInstallerError.processFailure("invalid process limits")
        }

        let selectedExecutable = executable.standardizedFileURL
        let pinnedExecutable = try expectedIdentity.map {
            try RuntimePinnedExecutable(url: selectedExecutable, expectedIdentity: $0)
        }
        defer { pinnedExecutable?.close() }
        var stdoutDescriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&stdoutDescriptors) == 0 else {
            throw RuntimeInstallerError.processFailure("could not create stdout pipe: \(String(cString: strerror(errno)))")
        }
        var stderrDescriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&stderrDescriptors) == 0 else {
            close(stdoutDescriptors[0])
            close(stdoutDescriptors[1])
            throw RuntimeInstallerError.processFailure("could not create stderr pipe: \(String(cString: strerror(errno)))")
        }
        let stdoutRead = stdoutDescriptors[0]
        let stdoutWrite = stdoutDescriptors[1]
        let stderrRead = stderrDescriptors[0]
        let stderrWrite = stderrDescriptors[1]

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            Self.closeDescriptors([stdoutRead, stdoutWrite, stderrRead, stderrWrite])
            throw RuntimeInstallerError.processFailure("could not initialize process file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        do {
            if let pinnedExecutable {
                try pinnedExecutable.addDirectoryActions(to: &actions)
            }
            try Self.checkPOSIX(
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                operation: "redirect stdin"
            )
            try Self.checkPOSIX(
                posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO),
                operation: "redirect stdout"
            )
            try Self.checkPOSIX(
                posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO),
                operation: "redirect stderr"
            )
            for (descriptor, operation) in [
                (stdoutRead, "close child stdout input"),
                (stdoutWrite, "close child stdout output"),
                (stderrRead, "close child stderr input"),
                (stderrWrite, "close child stderr output")
            ] {
                try Self.checkPOSIX(
                    posix_spawn_file_actions_addclose(&actions, descriptor),
                    operation: operation
                )
            }
        } catch {
            Self.closeDescriptors([stdoutRead, stdoutWrite, stderrRead, stderrWrite])
            throw error
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Self.closeDescriptors([stdoutRead, stdoutWrite, stderrRead, stderrWrite])
            throw RuntimeInstallerError.processFailure("could not initialize process attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        do {
            try Self.checkPOSIX(
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
                operation: "enable process-group creation"
            )
            try Self.checkPOSIX(
                posix_spawnattr_setpgroup(&attributes, 0),
                operation: "configure process group"
            )
        } catch {
            Self.closeDescriptors([stdoutRead, stdoutWrite, stderrRead, stderrWrite])
            throw error
        }

        let environment = ForgeProcessHost.sanitizedEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: ["LANG": "C", "LC_ALL": "C"]
        )
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        let executableArgument = pinnedExecutable?.basename ?? selectedExecutable.path
        var argv = ([executableArgument] + arguments).map { strdup($0) } + [nil]
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult: Int32
        do {
            if let pinnedExecutable {
                spawnResult = try pinnedExecutable.spawn(
                    pid: &pid,
                    actions: &actions,
                    attributes: &attributes,
                    argv: &argv,
                    envp: &envp,
                    hooks: launchHooks
                )
            } else {
                spawnResult = posix_spawn(
                    &pid,
                    selectedExecutable.path,
                    &actions,
                    &attributes,
                    &argv,
                    &envp
                )
            }
        } catch {
            close(stdoutWrite)
            close(stderrWrite)
            close(stdoutRead)
            close(stderrRead)
            throw error
        }
        close(stdoutWrite)
        close(stderrWrite)
        guard spawnResult == 0 else {
            close(stdoutRead)
            close(stderrRead)
            let message = String(cString: strerror(spawnResult))
            if spawnResult == EACCES || spawnResult == EPERM {
                throw RuntimeInstallerError.processLaunchDenied(message)
            }
            throw RuntimeInstallerError.processFailure(message)
        }

        let control = POSIXProcessControl(pid: pid, gracePeriod: terminationGracePeriod)
        let operation = Task.detached(priority: .utility) {
            try Self.collect(
                pid: pid,
                stdoutDescriptor: stdoutRead,
                stderrDescriptor: stderrRead,
                standardOutput: standardOutput,
                maximumStandardOutputBytes: maximumStandardOutputBytes,
                control: control
            )
        }

        let outcome = await withTaskCancellationHandler {
            await withTaskGroup(of: ProcessRaceOutcome.self) { group in
                group.addTask {
                    do { return .result(.success(try await operation.value)) }
                    catch { return .result(.failure(error)) }
                }
                group.addTask {
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(timeout)) }
                    catch { return .cancelled }
                    control.requestTermination()
                    return .timedOut
                }
                let first = await group.next() ?? .cancelled
                group.cancelAll()
                return first
            }
        } onCancel: {
            control.requestTermination()
        }

        switch outcome {
        case .result(.success(let result)):
            if Task.isCancelled { throw RuntimeInstallerError.cancelled }
            return result
        case .result(.failure(let error)):
            if error is CancellationError || Task.isCancelled { throw RuntimeInstallerError.cancelled }
            throw error
        case .timedOut:
            control.requestTermination()
            _ = try? await operation.value
            throw RuntimeInstallerError.processTimeout
        case .cancelled:
            control.requestTermination()
            _ = try? await operation.value
            throw RuntimeInstallerError.cancelled
        }
    }

    private static func collect(
        pid: pid_t,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        control: POSIXProcessControl
    ) throws -> RuntimeProcessResult {
        let outputHandle: FileHandle?
        if let standardOutput {
            let descriptor = open(
                standardOutput.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
            guard descriptor >= 0 else {
                control.requestTermination()
                close(stdoutDescriptor)
                close(stderrDescriptor)
                throw RuntimeFilesystemError.posix(
                    errno,
                    operation: "exclusively create process output file",
                    path: standardOutput.path
                )
            }
            outputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } else {
            outputHandle = nil
        }

        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var outputBytes = 0
        var outputLimitExceeded = false
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? outputHandle?.close()
                close(stdoutDescriptor)
                readers.leave()
            }
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let reaped = control.isReaped
                var descriptor = pollfd(fd: stdoutDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let pollResult = poll(&descriptor, 1, reaped ? 0 : 50)
                if pollResult == 0 {
                    if reaped { return }
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let received = read(stdoutDescriptor, &bytes, bytes.count)
                if received > 0 {
                    let accepted = lock.withLock { () -> Int in
                        let remaining = max(0, maximumStandardOutputBytes - outputBytes)
                        let count = min(received, remaining)
                        outputBytes += count
                        if count < received { outputLimitExceeded = true }
                        return count
                    }
                    if accepted > 0 {
                        let chunk = Data(bytes.prefix(accepted))
                        if let outputHandle { try? outputHandle.write(contentsOf: chunk) }
                        else { lock.withLock { stdout.append(chunk) } }
                    }
                    if accepted < received { control.requestTermination() }
                } else if received == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                close(stderrDescriptor)
                readers.leave()
            }
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let reaped = control.isReaped
                var descriptor = pollfd(fd: stderrDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let pollResult = poll(&descriptor, 1, reaped ? 0 : 50)
                if pollResult == 0 {
                    if reaped { return }
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let received = read(stderrDescriptor, &bytes, bytes.count)
                if received > 0 {
                    lock.withLock {
                        let remaining = max(0, maximumStandardOutputBytes - stderr.count)
                        stderr.append(contentsOf: bytes.prefix(min(received, remaining)))
                    }
                } else if received == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }

        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(pid, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult == pid else {
            let message = String(cString: strerror(errno))
            control.requestTermination()
            _ = kill(-pid, SIGKILL)
            readers.wait()
            throw RuntimeInstallerError.processFailure("could not reap process \(pid): \(message)")
        }

        // Mark the PID unavailable for all future signaling before waiting
        // for pipe readers. Readers poll this state, so descendants that
        // escaped the process group cannot retain our operation indefinitely.
        control.markReaped()
        readers.wait()
        return lock.withLock {
            RuntimeProcessResult(
                status: Self.exitStatus(waitStatus),
                stdout: stdout,
                stderr: stderr,
                standardOutputLimitExceeded: outputLimitExceeded
            )
        }
    }

    private static func exitStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 { return (waitStatus >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return waitStatus
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        let value = interval * 1_000_000_000
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        descriptors.forEach { close($0) }
    }

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw RuntimeInstallerError.processFailure(
                "could not \(operation): \(String(cString: strerror(result)))"
            )
        }
    }
}

public struct FoundationRuntimeProcessRunner: RuntimeProcessRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL? = nil,
        maximumStandardOutputBytes: Int = 1_024 * 1_024,
        timeout: TimeInterval = 60,
        terminationGracePeriod: TimeInterval = 1
    ) async throws -> RuntimeProcessResult {
        // Keep the compatibility type but use the descriptor-based runner.
        // Foundation's blocking FileHandle readers cannot be safely bounded
        // when escaped descendants retain inherited pipe descriptors.
        try await POSIXRuntimeProcessRunner().run(
            executable: executable,
            arguments: arguments,
            standardOutput: standardOutput,
            maximumStandardOutputBytes: maximumStandardOutputBytes,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod
        )
    }
}

private enum ProcessRaceOutcome: @unchecked Sendable {
    case result(Result<RuntimeProcessResult, Error>)
    case timedOut
    case cancelled
}

final class POSIXProcessControl: @unchecked Sendable {
    typealias SignalSender = @Sendable (_ processGroup: pid_t, _ signal: Int32) -> Void
    typealias Scheduler = @Sendable (_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private let pid: pid_t
    private let gracePeriod: TimeInterval
    private var terminationRequested = false
    private var reaped = false
    private let sendSignal: SignalSender
    private let schedule: Scheduler

    init(
        pid: pid_t,
        gracePeriod: TimeInterval,
        sendSignal: @escaping SignalSender = { processGroup, signal in _ = kill(-processGroup, signal) },
        schedule: @escaping Scheduler = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.pid = pid
        self.gracePeriod = gracePeriod
        self.sendSignal = sendSignal
        self.schedule = schedule
    }

    var isReaped: Bool { lock.withLock { reaped } }

    func requestTermination() {
        let requested = lock.withLock { () -> Bool in
            guard !terminationRequested, !reaped else { return false }
            terminationRequested = true
            sendSignal(pid, SIGTERM)
            return true
        }
        guard requested else { return }
        schedule(gracePeriod) { [self] in
            lock.withLock {
                if !reaped { sendSignal(pid, SIGKILL) }
            }
        }
    }

    func markReaped() { lock.withLock { reaped = true } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
