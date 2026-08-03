import Darwin
import Foundation

/// Internal same-binary mode that couples the menu application to forge3.
/// The menu process owns a framed control socket; closure makes this guardian
/// terminate and reap the complete forge3 process group. Conversely, the
/// guardian exits as soon as forge3 exits, allowing the menu process to treat
/// either failure as fatal.
public enum ForgeLifecycleGuardian {
    public static let modeArgument = "--forge-internal-lifecycle-guardian"

    static let controlDescriptor: Int32 = 20
    static let statusDescriptor: Int32 = 21
    static let outputDescriptor: Int32 = 22
    static let runtimeDirectoryDescriptor: Int32 = 23

    private static let statusMagic: UInt32 = 0x4647_5233 // "FGR3"
    private static let controlMagic: UInt32 = 0x4647_434C // "FGCL"
    private static let startAcknowledgement: UInt32 = 1
    private static let stopRequest: UInt32 = 2

    public static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.count > 1, arguments[1] == modeArgument else { return nil }
        return run(arguments: arguments)
    }

    private static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 12,
              let port = UInt16(arguments[4]),
              let expectedDevice = UInt64(arguments[5]),
              let expectedInode = UInt64(arguments[6]),
              let controlDescriptor = Int32(arguments[7]),
              let statusDescriptor = Int32(arguments[8]),
              let outputDescriptor = Int32(arguments[9]),
              let runtimeDirectoryDescriptor = Int32(arguments[10]),
              let launchTimeoutMilliseconds = UInt64(arguments[11])
        else { return 64 }

        let descriptors = Descriptors(
            control: controlDescriptor,
            status: statusDescriptor,
            output: outputDescriptor,
            runtimeDirectory: runtimeDirectoryDescriptor
        )
        let runtimeDisplayPath = arguments[2]
        let runtimeBasename = arguments[3]
        let leaseRoot = ProcessInfo.processInfo.environment["FORGE_INTERNAL_RUNTIME_LEASE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let launchDeadline = deadline(after: TimeInterval(launchTimeoutMilliseconds) / 1_000)
        var spawnedServicePID: pid_t = 0
        var serviceNeedsCleanup = false
        defer {
            if serviceNeedsCleanup, spawnedServicePID > 0 {
                terminateAndReapOwnedGroup(
                    servicePID: spawnedServicePID,
                    processGroupID: getpgrp(),
                    gracePeriod: 0
                )
            }
        }

        do {
            try assertTestSentinelClosed()
            let leaseToken = try leaseRoot.map {
                try RuntimeStoreLease(rootURL: $0).acquire(.sharedExecution)
            }
            defer { leaseToken?.release() }

            let expectedIdentity = try capturePinnedIdentity(
                basename: runtimeBasename,
                directoryDescriptor: descriptors.runtimeDirectory
            )
            guard expectedIdentity.device == expectedDevice,
                  expectedIdentity.inode == expectedInode
            else {
                throw RuntimeInstallerError.untrustedStoreItem(
                    "runtime executable identity changed before guardian launch"
                )
            }

            let servicePID = try spawnService(
                runtimeDisplayPath: runtimeDisplayPath,
                runtimeBasename: runtimeBasename,
                endpoint: LoopbackEndpoint(port: port),
                expectedIdentity: expectedIdentity,
                descriptors: descriptors
            )
            spawnedServicePID = servicePID
            serviceNeedsCleanup = true
            try recordPostSpawnServicePIDIfRequested(servicePID)
            try injectPostSpawnFaultIfRequested()
            let serviceIdentity = try ProcessIdentity.capture(
                servicePID,
                processGroupID: getpgrp()
            )

            guard awaitPreHandshakeWindow(servicePID: servicePID, descriptors: descriptors)
            else { return 1 }
            let statusSent = injectFragmentedStatusStallIfRequested(
                identity: serviceIdentity,
                descriptor: descriptors.status,
                deadline: launchDeadline
            ) ?? sendStatus(
                result: 0,
                identity: serviceIdentity,
                descriptor: descriptors.status,
                deadline: launchDeadline
            )
            guard statusSent,
                  awaitStartAcknowledgement(
                    servicePID: servicePID,
                    descriptor: descriptors.control,
                    deadline: launchDeadline
                  )
            else { return 1 }
            Darwin.close(descriptors.status)
            let result = monitor(
                servicePID: servicePID,
                processGroupID: getpgrp(),
                controlDescriptor: descriptors.control
            )
            serviceNeedsCleanup = false
            return result
        } catch {
            writeDiagnostic(
                "Lifecycle guardian could not launch forge3: \(error.localizedDescription)\n",
                descriptor: descriptors.output
            )
            sendStatus(
                result: EIO,
                identity: nil,
                descriptor: descriptors.status,
                deadline: launchDeadline
            )
            return 1
        }
    }

    private static func spawnService(
        runtimeDisplayPath: String,
        runtimeBasename: String,
        endpoint: LoopbackEndpoint,
        expectedIdentity: RuntimeExecutableIdentity,
        descriptors: Descriptors
    ) throws -> pid_t {
        try validatePinnedRuntime(
            basename: runtimeBasename,
            expectedIdentity: expectedIdentity,
            displayPath: runtimeDisplayPath,
            directoryDescriptor: descriptors.runtimeDirectory
        )

        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&actions), operation: "initialize service file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkPOSIX(
            posix_spawn_file_actions_addfchdir_np(&actions, descriptors.runtimeDirectory),
            operation: "pin service working directory"
        )
        try checkPOSIX(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            operation: "redirect service stdin"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&actions, descriptors.output, STDOUT_FILENO),
            operation: "redirect service stdout"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&actions, descriptors.output, STDERR_FILENO),
            operation: "redirect service stderr"
        )
        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes), operation: "initialize service attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ),
            operation: "enable service process-group and close-on-exec defaults"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, getpgrp()),
            operation: "join service to guardian-owned process group"
        )

        let arguments = [
            runtimeBasename,
            "--log-format", "json",
            "ws", "--addr", endpoint.address
        ]
        var environment = ForgeProcessHost.sanitizedEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: [:]
        ).filter { !$0.key.hasPrefix("FORGE_INTERNAL_") }
        if let sentinel = ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_SENTINEL_FD"] {
            environment["FORGE_TEST_SENTINEL_FD"] = sentinel
        }
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var servicePID: pid_t = 0
        let result = posix_spawn(
            &servicePID,
            runtimeBasename,
            &actions,
            &attributes,
            &argv,
            &envp
        )
        guard result == 0 else {
            throw ForgeCoreError.processLaunch(String(cString: strerror(result)))
        }
        return servicePID
    }

    /// Test-only delay that continues monitoring parent ownership. It exercises
    /// the exact window after service spawn but before the host learns its PID.
    private static func awaitPreHandshakeWindow(
        servicePID: pid_t,
        descriptors: Descriptors
    ) -> Bool {
        let milliseconds = ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_PRE_HANDSHAKE_DELAY_MS"]
            .flatMap(UInt64.init) ?? 0
        guard milliseconds > 0 else {
            return controlChannelIsOpen(descriptor: descriptors.control)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(milliseconds) / 1_000)
        while Date() < deadline {
            if !controlChannelIsOpen(descriptor: descriptors.control) { return false }
            if serviceHasExitedWithoutReaping(servicePID) { return false }
            usleep(10_000)
        }
        return controlChannelIsOpen(descriptor: descriptors.control)
    }

    private static func awaitStartAcknowledgement(
        servicePID: pid_t,
        descriptor: Int32,
        deadline: UInt64
    ) -> Bool {
        while !deadlineExpired(deadline) {
            if serviceHasExitedWithoutReaping(servicePID) { return false }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&pollDescriptor, 1, min(50, pollTimeout(deadline: deadline)))
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { return false }
            switch receiveControlPacket(descriptor: descriptor, deadline: deadline) {
            case .packet(let packet)
                where packet.magic == controlMagic && packet.command == startAcknowledgement:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func monitor(
        servicePID: pid_t,
        processGroupID: pid_t,
        controlDescriptor: Int32
    ) -> Int32 {
        while true {
            if let status = observeExitedService(servicePID) {
                // The unreaped guardian pins this process-group identity until
                // the host performs the sole waitpid. Forced reciprocal
                // cleanup deliberately includes the guardian, avoiding any
                // per-PID snapshot and its PID-reuse race.
                _ = kill(-processGroupID, SIGKILL)
                return decodedExitStatus(status)
            }

            var descriptor = pollfd(
                fd: controlDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = poll(&descriptor, 1, 50)
            if pollResult > 0 {
                if descriptor.revents & Int16(POLLIN) != 0 {
                    switch receiveControlPacket(
                        descriptor: controlDescriptor,
                        deadline: deadline(after: 1)
                    ) {
                    case .packet(let packet)
                        where packet.magic == controlMagic && packet.command == stopRequest:
                        terminateAndReapOwnedGroup(
                            servicePID: servicePID,
                            processGroupID: processGroupID,
                            gracePeriod: TimeInterval(packet.graceMilliseconds) / 1_000
                        )
                        return 0
                    case .closed:
                        terminateAndReapOwnedGroup(
                            servicePID: servicePID,
                            processGroupID: processGroupID,
                            gracePeriod: 0
                        )
                        return 0
                    default:
                        terminateAndReapOwnedGroup(
                            servicePID: servicePID,
                            processGroupID: processGroupID,
                            gracePeriod: 0
                        )
                        return 1
                    }
                }
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    terminateAndReapOwnedGroup(
                        servicePID: servicePID,
                        processGroupID: processGroupID,
                        gracePeriod: 0
                    )
                    return 0
                }
            } else if pollResult < 0 && errno != EINTR {
                terminateAndReapOwnedGroup(
                    servicePID: servicePID,
                    processGroupID: processGroupID,
                    gracePeriod: 0
                )
                return 1
            }
        }
    }

    private static func terminateAndReapOwnedGroup(
        servicePID: pid_t,
        processGroupID: pid_t,
        gracePeriod: TimeInterval
    ) {
        signalLifecycleGroupWithGuardianProtected(processGroupID, signal: SIGTERM)
        let stopDeadline = Date().addingTimeInterval(max(0, gracePeriod))
        repeat {
            if observeExitedService(servicePID) != nil {
                reapServiceLeader(servicePID)
                // A second group-level TERM includes the guardian after its
                // temporary protection is gone. This closes the lifecycle even
                // if a non-child group member survived the first TERM, without
                // ever enumerating or signalling snapshot PIDs.
                _ = kill(-processGroupID, SIGTERM)
                pause()
            }
            if Date() >= stopDeadline { break }
            usleep(10_000)
        } while true

        // SIGKILL cannot be ignored. Killing the complete group is safe because
        // the host still owns the unreaped guardian and therefore the PGID
        // cannot be reused before the host's sole waitpid.
        _ = kill(-processGroupID, SIGKILL)
        pause()
    }

    private static func signalLifecycleGroupWithGuardianProtected(
        _ processGroupID: pid_t,
        signal signalNumber: Int32
    ) {
        let previousHandler = Darwin.signal(signalNumber, SIG_IGN)
        _ = kill(-processGroupID, signalNumber)
        _ = Darwin.signal(signalNumber, previousHandler)
    }

    private static func observeExitedService(_ servicePID: pid_t) -> Int32? {
        var info = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(servicePID), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 {
                guard info.si_pid == servicePID else { return nil }
                if info.si_code == CLD_EXITED {
                    return Int32(info.si_status) << 8
                }
                return Int32(info.si_status) & 0x7f
            }
            if errno == EINTR { continue }
            return nil
        }
    }

    private static func serviceHasExitedWithoutReaping(_ servicePID: pid_t) -> Bool {
        observeExitedService(servicePID) != nil
    }

    private static func reapServiceLeader(_ servicePID: pid_t) {
        var status: Int32 = 0
        while waitpid(servicePID, &status, 0) == -1 && errno == EINTR {}
    }

    private static func controlChannelIsOpen(descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result > 0 { return true }
        if result == 0 { return false }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return true }
        return errno != ECONNRESET && errno != EBADF
    }

    private enum ControlReceiveResult {
        case packet(ControlPacket)
        case closed
        case failed
    }

    private static func receiveControlPacket(
        descriptor: Int32,
        deadline: UInt64
    ) -> ControlReceiveResult {
        var packet = ControlPacket(magic: 0, command: 0, graceMilliseconds: 0)
        let result = withUnsafeMutableBytes(of: &packet) { bytes in
            readCompleteFrame(descriptor: descriptor, bytes: bytes, deadline: deadline)
        }
        switch result {
        case .complete: return .packet(packet)
        case .closed: return .closed
        case .failed: return .failed
        }
    }

    @discardableResult
    private static func sendStatus(
        result: Int32,
        identity: ProcessIdentity?,
        descriptor: Int32,
        deadline: UInt64
    ) -> Bool {
        var packet = GuardianStatusPacket(
            magic: statusMagic,
            result: result,
            servicePID: identity?.pid ?? 0,
            serviceStartSeconds: identity?.startSeconds ?? 0,
            serviceStartMicroseconds: identity?.startMicroseconds ?? 0
        )
        return withUnsafeBytes(of: &packet) { bytes in
            writeCompleteFrame(descriptor: descriptor, bytes: bytes, deadline: deadline)
        }
    }

    enum FrameReadResult: Equatable {
        case complete
        case closed
        case failed
    }

    static func readCompleteFrame(
        descriptor: Int32,
        bytes: UnsafeMutableRawBufferPointer,
        deadline: UInt64
    ) -> FrameReadResult {
        guard let base = bytes.baseAddress else { return .complete }
        var offset = 0
        while offset < bytes.count {
            guard waitForDescriptor(descriptor, events: Int16(POLLIN), deadline: deadline) else {
                return .failed
            }
            let count = recv(
                descriptor,
                base.advanced(by: offset),
                bytes.count - offset,
                MSG_DONTWAIT
            )
            if count > 0 {
                offset += count
            } else if count == 0 || (count < 0 && errno == ECONNRESET) {
                return .closed
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                return .failed
            }
        }
        return .complete
    }

    static func writeCompleteFrame(
        descriptor: Int32,
        bytes: UnsafeRawBufferPointer,
        deadline: UInt64
    ) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            guard waitForDescriptor(descriptor, events: Int16(POLLOUT), deadline: deadline) else {
                return false
            }
            let count = send(
                descriptor,
                base.advanced(by: offset),
                bytes.count - offset,
                MSG_NOSIGNAL | MSG_DONTWAIT
            )
            if count > 0 {
                offset += count
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                return false
            }
        }
        return true
    }

    static func deadline(after interval: TimeInterval) -> UInt64 {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    private static func deadlineExpired(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private static func pollTimeout(deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        let remaining = deadline - now
        let milliseconds = (remaining + 999_999) / 1_000_000
        return Int32(min(UInt64(Int32.max), milliseconds))
    }

    private static func waitForDescriptor(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) -> Bool {
        while !deadlineExpired(deadline) {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: events | Int16(POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&pollDescriptor, 1, pollTimeout(deadline: deadline))
            if result > 0 {
                return pollDescriptor.revents & events != 0
                    || pollDescriptor.revents & Int16(POLLHUP) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
        return false
    }

    private static func writeDiagnostic(_ message: String, descriptor: Int32) {
        let data = Data(message.utf8)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = write(descriptor, base, bytes.count)
        }
    }

    private static func capturePinnedIdentity(
        basename: String,
        directoryDescriptor: Int32
    ) throws -> RuntimeExecutableIdentity {
        var info = stat()
        let result = basename.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw RuntimeFilesystemError.posix(
                errno,
                operation: "inspect pinned guardian runtime executable",
                path: basename
            )
        }
        return RuntimeExecutableIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size,
            sha256: ""
        )
    }

    private static func validatePinnedRuntime(
        basename: String,
        expectedIdentity: RuntimeExecutableIdentity,
        displayPath: String,
        directoryDescriptor: Int32
    ) throws {
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw RuntimeInstallerError.untrustedStoreItem("invalid pinned runtime basename")
        }
        var info = stat()
        let result = basename.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              info.st_mode & 0o100 != 0,
              UInt64(info.st_dev) == expectedIdentity.device,
              UInt64(info.st_ino) == expectedIdentity.inode,
              info.st_size == expectedIdentity.size
        else {
            throw RuntimeInstallerError.untrustedStoreItem(
                "runtime executable is unsafe at the guardian launch boundary: \(displayPath)"
            )
        }
    }

    private static func assertTestSentinelClosed() throws {
        guard let value = ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_SENTINEL_FD"],
              let descriptor = Int32(value)
        else { return }
        errno = 0
        if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
            throw ForgeCoreError.processLaunch("guardian inherited sentinel descriptor \(descriptor)")
        }
    }

    private static func decodedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal == SSTOP { return 128 + ((status >> 8) & 0xff) }
        return 128 + signal
    }

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ForgeCoreError.processLaunch(
                "could not \(operation): \(String(cString: strerror(result)))"
            )
        }
    }

    private struct Descriptors {
        let control: Int32
        let status: Int32
        let output: Int32
        let runtimeDirectory: Int32
    }

    struct GuardianStatusPacket {
        var magic: UInt32
        var result: Int32
        var servicePID: pid_t
        var serviceStartSeconds: UInt64
        var serviceStartMicroseconds: UInt64

        var identity: ProcessIdentity? {
            guard result == 0, servicePID > 0, serviceStartSeconds > 0 else { return nil }
            return ProcessIdentity(
                pid: servicePID,
                startSeconds: serviceStartSeconds,
                startMicroseconds: serviceStartMicroseconds
            )
        }
    }

    struct ControlPacket {
        var magic: UInt32
        var command: UInt32
        var graceMilliseconds: UInt64
    }

    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        static func capture(_ pid: pid_t, processGroupID: pid_t) throws -> ProcessIdentity {
            var info = proc_bsdinfo()
            let count = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard count == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_pgid == processGroupID
            else {
                throw ForgeCoreError.processLaunch("could not capture forge3 process identity")
            }
            return ProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
        }

    }

    private static func recordPostSpawnServicePIDIfRequested(_ servicePID: pid_t) throws {
        guard let path = ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_AFTER_SPAWN_PID_FILE"]
        else { return }
        try Data("leader=\(servicePID)\n".utf8).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
    }

    private static func injectPostSpawnFaultIfRequested() throws {
        switch ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_AFTER_SPAWN_FAULT"] {
        case "throw":
            throw ForgeCoreError.processLaunch("injected failure immediately after forge3 spawn")
        case "sigkill":
            _ = kill(getpid(), SIGKILL)
            pause()
        default:
            return
        }
    }

    private static func injectFragmentedStatusStallIfRequested(
        identity: ProcessIdentity,
        descriptor: Int32,
        deadline: UInt64
    ) -> Bool? {
        guard ProcessInfo.processInfo.environment["FORGE_INTERNAL_TEST_STATUS_PREFIX_STALL"] == "1"
        else { return nil }
        var packet = GuardianStatusPacket(
            magic: statusMagic,
            result: 0,
            servicePID: identity.pid,
            serviceStartSeconds: identity.startSeconds,
            serviceStartMicroseconds: identity.startMicroseconds
        )
        let prefixSent = withUnsafeBytes(of: &packet) { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            return send(descriptor, base, 1, MSG_NOSIGNAL) == 1
        }
        guard prefixSent else { return false }
        while !deadlineExpired(deadline) { usleep(1_000) }
        return false
    }

    static func validateStatusPacket(_ packet: GuardianStatusPacket) -> Bool {
        packet.magic == statusMagic
            && packet.result == 0
            && packet.servicePID > 0
            && packet.serviceStartSeconds > 0
    }

    static func identity(from packet: GuardianStatusPacket) -> ProcessIdentity {
        ProcessIdentity(
            pid: packet.servicePID,
            startSeconds: packet.serviceStartSeconds,
            startMicroseconds: packet.serviceStartMicroseconds
        )
    }

    static func startAcknowledgementPacket() -> ControlPacket {
        ControlPacket(magic: controlMagic, command: startAcknowledgement, graceMilliseconds: 0)
    }

    static func stopPacket(gracePeriod: TimeInterval) -> ControlPacket {
        ControlPacket(
            magic: controlMagic,
            command: stopRequest,
            graceMilliseconds: UInt64(max(0, gracePeriod) * 1_000)
        )
    }
}
