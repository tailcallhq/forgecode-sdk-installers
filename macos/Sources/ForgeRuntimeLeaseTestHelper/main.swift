import Darwin
import Foundation
import ForgeMenuCore

@main
private enum ForgeRuntimeLeaseTestHelper {
    static func main() async {
        if let guardianStatus = ForgeLifecycleGuardian.runIfRequested() {
            exit(guardianStatus)
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--escaped-output-writer" {
            runEscapedOutputWriter(pidFile: CommandLine.arguments[2])
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--escaped-output-launcher" {
            runEscapedOutputLauncher(pidFile: CommandLine.arguments[2])
        }
        if let pidFile = ProcessInfo.processInfo.environment["FORGE_TEST_ESCAPED_OUTPUT_PID_FILE"] {
            runEscapedOutputService(pidFile: pidFile)
        }
        if CommandLine.arguments.count == 4,
           CommandLine.arguments[1] == "--runtime-process-fd-probe" {
            await runRuntimeProcessFDProbe()
        }
        if CommandLine.arguments.count == 6,
           CommandLine.arguments[1] == "--lifecycle-owner-death" {
            await runLifecycleOwnerDeathProbe()
        }
        guard CommandLine.arguments.count == 5,
              let mode = Mode(rawValue: CommandLine.arguments[2])
        else {
            FileHandle.standardError.write(
                Data("usage: ForgeRuntimeLeaseTestHelper <runtime-root> <shared|exclusive> <marker> <exit|hold>\n".utf8)
            )
            exit(64)
        }

        do {
            let rootURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let lease = RuntimeStoreLease(rootURL: rootURL)
            let token = try lease.acquire(mode.leaseMode)
            let markerURL = URL(fileURLWithPath: CommandLine.arguments[3])
            try Data("locked".utf8).write(to: markerURL, options: .withoutOverwriting)
            if CommandLine.arguments[4] == "hold" {
                while true { pause() }
            }
            token.release()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func runEscapedOutputService(pidFile: String) -> Never {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { exit(73) }
        defer { posix_spawnattr_destroy(&attributes) }
        let arguments = [CommandLine.arguments[0], "--escaped-output-launcher", pidFile]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in environment where pointer != nil { free(pointer) }
        }
        var escapedPID: pid_t = 0
        guard posix_spawn(
            &escapedPID,
            CommandLine.arguments[0],
            nil,
            &attributes,
            &argv,
            &environment
        ) == 0 else { exit(75) }

        FileHandle.standardOutput.write(Data("escaped-output-ready\n".utf8))
        while true { pause() }
    }

    private static func runEscapedOutputLauncher(pidFile: String) -> Never {
        guard setsid() >= 0 else { exit(76) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { exit(77) }
        defer { posix_spawnattr_destroy(&attributes) }
        let arguments = [CommandLine.arguments[0], "--escaped-output-writer", pidFile]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in environment where pointer != nil { free(pointer) }
        }
        var writerPID: pid_t = 0
        guard posix_spawn(
            &writerPID,
            CommandLine.arguments[0],
            nil,
            &attributes,
            &argv,
            &environment
        ) == 0 else { exit(79) }
        exit(0)
    }

    private static func runEscapedOutputWriter(pidFile: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let marker = "escaped=\(getpid())\n"
        guard marker.withCString({ pointer in
            let descriptor = open(
                pidFile,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            return write(descriptor, pointer, strlen(pointer)) == strlen(pointer)
        }) else { exit(80) }

        FileHandle.standardOutput.write(Data("api_key=sk-escaped-output-secret\n".utf8))
        var output = [UInt8](repeating: UInt8(ascii: "x"), count: 16 * 1_024)
        output[output.count - 1] = UInt8(ascii: "\n")
        while true {
            if write(STDOUT_FILENO, &output, output.count) < 0 { usleep(1_000) }
            if write(STDERR_FILENO, &output, output.count) < 0 { usleep(1_000) }
        }
    }

    private static func runLifecycleOwnerDeathProbe() async -> Never {
        let runtimeURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let logURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let pidURL = URL(fileURLWithPath: CommandLine.arguments[4])
        guard let port = UInt16(CommandLine.arguments[5]) else { exit(64) }
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: runtimeURL
        )
        let host = ForgeProcessHost(configuration: .init(
            logURL: logURL,
            guardianExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            guardianLaunchTimeout: 5
        ))
        Task {
            do {
                try await host.start(
                    runtime: runtime,
                    endpoint: LoopbackEndpoint(port: port),
                    generation: 1
                )
                exit(70)
            } catch {
                exit(71)
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: pidURL.path) {
                // Model abrupt menu-process death: do not run destructors or
                // orderly lifecycle shutdown. Closing the inherited control
                // endpoint is the only ownership signal sent to the guardian.
                _exit(0)
            }
            usleep(10_000)
        }
        exit(72)
    }

    private static func runRuntimeProcessFDProbe() async -> Never {
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let sentinel = open("/dev/null", O_RDONLY)
        guard sentinel >= 0, fcntl(sentinel, F_SETFD, 0) == 0 else { exit(71) }
        setenv("FORGE_TEST_SENTINEL_FD", String(sentinel), 1)
        close(STDIN_FILENO)
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        do {
            let result = try await POSIXRuntimeProcessRunner().run(
                executable: executable,
                arguments: [],
                standardOutput: nil,
                maximumStandardOutputBytes: 4_096,
                timeout: 5,
                terminationGracePeriod: 0.1
            )
            var data = Data("status=\(result.status)\n".utf8)
            data.append(result.stdout)
            data.append(result.stderr)
            try data.write(to: resultURL, options: .atomic)
            exit(result.status == 0 ? 0 : 1)
        } catch {
            try? Data("error=\(error)\n".utf8).write(to: resultURL, options: .atomic)
            exit(1)
        }
    }

    private enum Mode: String {
        case shared
        case exclusive

        var leaseMode: RuntimeStoreLease.Mode {
            switch self {
            case .shared: return .sharedExecution
            case .exclusive: return .exclusiveMutation
            }
        }
    }
}
