import Darwin
import Foundation

/// The seam the supervisor and developer override depend on. Two operations:
/// report an already-installed runtime, or install the latest by running the
/// upstream shell installer.
public protocol RuntimeInstalling: Sendable {
    func installedCurrentRuntime() async throws -> InstalledRuntime?
    func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime
}

/// Thin wrapper around forge3's cargo-dist shell installer.
///
/// First run downloads the installer script from `installerURL` (default
/// `https://install.forgecode.dev/server`) and runs it via `/bin/sh` with
/// `FORGE3_INSTALL_DIR` pinned to a deterministic directory. The binary lands
/// at `<installDir>/bin/forge3` (cargo-home layout) and a receipt is written to
/// `~/.config/forge3/forge3-receipt.json` so forge3's own axoupdater self-update
/// keeps working. No checksum, signature, or Mach-O verification is performed —
/// the installer script is fully trusted.
public actor RuntimeInstaller: RuntimeInstalling {
    /// Overrides the installer script source. `FORGE_UPDATE_INSTALLER_URL=...`
    /// (e.g. `http://127.0.0.1:9877/install.sh`) points the app at a local
    /// script for testing.
    public static let installerURLEnvironmentKey = "FORGE_UPDATE_INSTALLER_URL"
    public static let defaultInstallerURL = URL(string: "https://install.forgecode.dev/server")!

    private let installDir: URL
    private let installerURL: URL
    private let architecture: RuntimeArchitecture
    private let logger: AppLogger
    private let session: URLSession
    private let maximumScriptBytes: Int

    public init(
        installDir: URL = RuntimeInstaller.defaultInstallDir(),
        installerURL: URL? = nil,
        architecture: RuntimeArchitecture = .native,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: AppLogger = .shared,
        session: URLSession = .shared,
        maximumScriptBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.installDir = installDir.standardizedFileURL
        self.installerURL = installerURL
            ?? RuntimeInstaller.resolveInstallerURL(environment: environment)
        self.architecture = architecture
        self.logger = logger
        self.session = session
        self.maximumScriptBytes = maximumScriptBytes
    }

    /// Deterministic install directory: `~/Library/Application Support/ForgeCode/forge3`.
    public static func defaultInstallDir(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let library = libraryDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Application Support/ForgeCode/forge3", isDirectory: true)
    }

    /// The absolute path the installed executable is expected at.
    public static func executableURL(installDir: URL) -> URL {
        installDir
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("forge3")
            .standardizedFileURL
    }

    public static func resolveInstallerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment[installerURLEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return defaultInstallerURL
    }

    public func installedCurrentRuntime() throws -> InstalledRuntime? {
        let executable = Self.executableURL(installDir: installDir)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return InstalledRuntime(
            version: .unknown,
            architecture: architecture,
            executableURL: executable
        )
    }

    public func installLatest() async throws -> InstalledRuntime {
        try await installLatest { _ in }
    }

    public func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        // Already installed (e.g. a concurrent install won): reuse it.
        if let existing = try installedCurrentRuntime() {
            await progress(.ready)
            return existing
        }

        await progress(.resolving)
        try Task.checkCancellation()

        let scriptURL = try await downloadInstallerScript()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        try Task.checkCancellation()
        await progress(.installing)
        logger.info("Running forge3 installer from \(installerURL.absoluteString) into \(installDir.path)")
        try await runInstaller(scriptURL: scriptURL)

        let executable = Self.executableURL(installDir: installDir)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ThinInstallerError.missingExecutable(executable.path)
        }
        Self.removeQuarantine(at: executable, logger: logger)

        await progress(.ready)
        return InstalledRuntime(
            version: .unknown,
            architecture: architecture,
            executableURL: executable
        )
    }

    private func downloadInstallerScript() async throws -> URL {
        var request = URLRequest(url: installerURL)
        request.timeoutInterval = 60
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError { throw ThinInstallerError.cancelled }
            throw ThinInstallerError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ThinInstallerError.download("installer host returned HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw ThinInstallerError.download("the installer script was empty")
        }
        guard data.count <= maximumScriptBytes else {
            throw ThinInstallerError.download("the installer script exceeded \(maximumScriptBytes) bytes")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge3-installer-\(UUID().uuidString)", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("forge3-installer.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: scriptURL, options: .atomic)
        } catch {
            throw RuntimeFilesystemError.thin(error, operation: "stage the forge3 installer script", path: scriptURL.path)
        }
        return scriptURL
    }

    private func runInstaller(scriptURL: URL) async throws {
        do {
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        } catch {
            throw RuntimeFilesystemError.thin(error, operation: "create the forge3 install directory", path: installDir.path)
        }

        let invocation = Self.makeInvocation(scriptURL: scriptURL, installDir: installDir)
        let status = try await Self.runShell(
            arguments: invocation.arguments,
            environmentOverrides: invocation.environmentOverrides,
            logger: logger
        )
        guard status == 0 else {
            throw ThinInstallerError.installerFailed(status: status)
        }
    }

    /// Pure builder for the installer subprocess invocation, factored out for
    /// testing. Uses the default managed install (receipt enabled) targeting a
    /// fixed directory, without touching shell rc files.
    public struct Invocation: Equatable, Sendable {
        public let arguments: [String]
        public let environmentOverrides: [String: String]
    }

    public static func makeInvocation(scriptURL: URL, installDir: URL) -> Invocation {
        Invocation(
            arguments: ["/bin/sh", scriptURL.path],
            environmentOverrides: [
                "FORGE3_INSTALL_DIR": installDir.path,
                "FORGE3_NO_MODIFY_PATH": "1",
                "FORGE3_PRINT_QUIET": "1"
            ]
        )
    }

    /// Removes `com.apple.quarantine` from the installed binary. Best-effort:
    /// the only Gatekeeper workaround retained. A locally-downloaded script's
    /// output usually isn't quarantined, but strip it defensively.
    static func removeQuarantine(at url: URL, logger: AppLogger) {
        let result = url.path.withCString { path in
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
        if result != 0 && errno != ENOATTR {
            logger.warning("Could not remove com.apple.quarantine from \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Runs a short-lived one-shot subprocess (the installer), streaming its
    /// output to the app log. Unlike the long-lived forge3 child, this does not
    /// need process-group supervision.
    static func runShell(
        arguments: [String],
        environmentOverrides: [String: String],
        logger: AppLogger
    ) async throws -> Int32 {
        precondition(!arguments.isEmpty)
        let environment = ForgeProcessHost.sanitizedEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: environmentOverrides
        )
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        logger.info("forge3-installer: \(Redactor.redact(String(line)))")
                    }
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ThinInstallerError.download(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}
