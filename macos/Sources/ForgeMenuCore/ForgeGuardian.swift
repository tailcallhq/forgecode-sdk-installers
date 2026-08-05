// Imports

import Darwin
import Foundation

// Structs and Enums

public enum ForgeGuardian {
    public static let argumentMarker = "--forge3-guardian"
    public static let deathDescriptor: Int32 = 3

    // Implementation

    /// Runs the internal guardian mode before the menu-bar app initializes
    /// AppKit. This function returns only for a normal application launch.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.count > 1, arguments[1] == argumentMarker else { return }
        guard arguments.count >= 3 else {
            writeDiagnostic("forge3 guardian requires an executable path\n")
            Darwin.exit(EX_USAGE)
        }

        let executablePath = arguments[2]
        let serviceArguments = [URL(fileURLWithPath: executablePath).lastPathComponent]
            + Array(arguments.dropFirst(3))
        Darwin.exit(run(executablePath: executablePath, arguments: serviceArguments))
    }

    public static func currentExecutableURL() -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func run(executablePath: String, arguments: [String]) -> Int32 {
        // The host uses SIGTERM as a belt-and-braces wakeup after closing the
        // death pipe. The guardian must remain alive long enough to clean the
        // separately grouped service tree.
        _ = Darwin.signal(SIGTERM, SIG_IGN)

        let servicePID: pid_t
        do {
            servicePID = try spawnService(executablePath: executablePath, arguments: arguments)
        } catch {
            writeDiagnostic("forge3 guardian could not launch service: \(error)\n")
            return EX_OSERR
        }

        while true {
            if let status = observeExitedProcess(servicePID) {
                // The unreaped service leader pins its process-group identity,
                // so descendants can be swept without a PID-reuse race.
                _ = kill(-servicePID, SIGKILL)
                reapProcess(servicePID)
                return decodeExitStatus(status)
            }

            var descriptor = pollfd(
                fd: deathDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&descriptor, 1, 50)
            if result > 0, descriptor.revents != 0 {
                terminateProcessGroup(servicePID)
                return 0
            }
            if result < 0, errno != EINTR {
                writeDiagnostic("forge3 guardian death-pipe poll failed: \(posixError())\n")
                terminateProcessGroup(servicePID)
                return EX_OSERR
            }
        }
    }

    private static func spawnService(executablePath: String, arguments: [String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&actions), operation: "initialize service file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&actions, deathDescriptor),
            operation: "close service death descriptor"
        )

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes), operation: "initialize service attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        try checkPOSIX(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            operation: "restore service signal defaults"
        )
        try checkPOSIX(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
            ),
            operation: "enable service process-group creation"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "configure service process group"
        )

        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var servicePID: pid_t = 0
        let result = posix_spawn(
            &servicePID,
            executablePath,
            &actions,
            &attributes,
            &argv,
            environ
        )
        try checkPOSIX(result, operation: "spawn service")
        return servicePID
    }

    private static func terminateProcessGroup(_ servicePID: pid_t) {
        _ = kill(-servicePID, SIGTERM)

        // forge3 is known not to honor SIGTERM. Escalate immediately rather
        // than delaying guardian cleanup long enough for the host's own
        // guardian fallback to race and leave the separate service group alive.
        _ = kill(-servicePID, SIGKILL)
        reapProcess(servicePID)
    }

    private static func observeExitedProcess(_ processID: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { return status }
            if result == 0 { return nil }
            if result == -1, errno == EINTR { continue }
            return nil
        }
    }

    private static func reapProcess(_ processID: pid_t) {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) == -1, errno == EINTR {}
    }

    private static func decodeExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return status
    }

    // Utility Functions

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ForgeCoreError.processLaunch("could not \(operation): \(String(cString: strerror(result)))")
        }
    }

    private static func posixError() -> String {
        String(cString: strerror(errno))
    }

    private static func writeDiagnostic(_ message: String) {
        message.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }
}
