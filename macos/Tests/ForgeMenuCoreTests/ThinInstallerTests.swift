import Foundation
import XCTest
@testable import ForgeMenuCore

final class ThinInstallerTests: XCTestCase {
    // MARK: - Env forwarding to the forge3 child

    func testSanitizedEnvironmentForwardsDebugAndAPIKeyVars() {
        let sanitized = ForgeProcessHost.sanitizedEnvironment(
            inherited: [
                "HOME": "/Users/test",
                "FORGE_UPDATE_CURRENT_VERSION": "0.1.195",
                "FORGE_UPDATE_MANIFEST_URL": "https://example.com/manifest.json",
                "FORGE_UPDATE_INSTALLER_URL": "http://127.0.0.1:9877/install.sh",
                "FORGE_CONSOLE_ORIGIN": "http://127.0.0.1:5173",
                "FORGE3_API_KEY": "sk-forge3-key",
                "SECRET_TOKEN": "do-not-inherit"
            ],
            overrides: [:]
        )
        XCTAssertEqual(sanitized["FORGE_UPDATE_CURRENT_VERSION"], "0.1.195")
        XCTAssertEqual(sanitized["FORGE_UPDATE_MANIFEST_URL"], "https://example.com/manifest.json")
        XCTAssertEqual(sanitized["FORGE_UPDATE_INSTALLER_URL"], "http://127.0.0.1:9877/install.sh")
        XCTAssertEqual(sanitized["FORGE_CONSOLE_ORIGIN"], "http://127.0.0.1:5173")
        XCTAssertEqual(sanitized["FORGE3_API_KEY"], "sk-forge3-key")
        XCTAssertNil(sanitized["SECRET_TOKEN"])
        XCTAssertNotNil(sanitized["PATH"], "PATH must be defaulted when absent")
    }

    // MARK: - Installer invocation construction

    func testInstallerInvocationUsesShInstallDirNoModifyPathAndQuiet() {
        let scriptURL = URL(fileURLWithPath: "/tmp/forge3-installer/forge3-installer.sh")
        let installDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/ForgeCode/forge3")
        let invocation = RuntimeInstaller.makeInvocation(scriptURL: scriptURL, installDir: installDir)

        XCTAssertEqual(invocation.arguments, ["/bin/sh", scriptURL.path])
        XCTAssertEqual(invocation.environmentOverrides["FORGE3_INSTALL_DIR"], installDir.path)
        XCTAssertEqual(invocation.environmentOverrides["FORGE3_NO_MODIFY_PATH"], "1")
        XCTAssertEqual(invocation.environmentOverrides["FORGE3_PRINT_QUIET"], "1")
        // Self-update must remain enabled: never disable the updater.
        XCTAssertNil(invocation.environmentOverrides["FORGE3_DISABLE_UPDATE"])
        XCTAssertNil(invocation.environmentOverrides["FORGE3_UNMANAGED_INSTALL"])
    }

    func testInstallerURLDefaultsToPublicEndpoint() {
        XCTAssertEqual(
            RuntimeInstaller.resolveInstallerURL(environment: [:]).absoluteString,
            "https://install.forgecode.dev/server"
        )
        XCTAssertEqual(
            RuntimeInstaller.resolveInstallerURL(
                environment: ["FORGE_UPDATE_INSTALLER_URL": "   "]
            ).absoluteString,
            "https://install.forgecode.dev/server"
        )
    }

    func testInstallerURLOverrideHonoursEnvironment() {
        let resolved = RuntimeInstaller.resolveInstallerURL(
            environment: ["FORGE_UPDATE_INSTALLER_URL": "http://127.0.0.1:9877/install.sh"]
        )
        XCTAssertEqual(resolved.absoluteString, "http://127.0.0.1:9877/install.sh")
    }

    func testDefaultInstallDirIsUnderApplicationSupport() {
        let library = URL(fileURLWithPath: "/Users/test/Library")
        let dir = RuntimeInstaller.defaultInstallDir(libraryDirectory: library)
        XCTAssertEqual(dir.path, "/Users/test/Library/Application Support/ForgeCode/forge3")
        XCTAssertEqual(
            RuntimeInstaller.executableURL(installDir: dir).path,
            "/Users/test/Library/Application Support/ForgeCode/forge3/bin/forge3"
        )
    }

    // MARK: - Installed-binary location (no network)

    func testInstalledCurrentRuntimeDetectsExecutableAtBinForge3() async throws {
        let installDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: installDir) }
        let binDir = installDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let installer = RuntimeInstaller(installDir: installDir)

        // No executable yet.
        let missing = try await installer.installedCurrentRuntime()
        XCTAssertNil(missing)

        // Non-executable regular file is still "not installed".
        let executable = binDir.appendingPathComponent("forge3")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        let notExecutable = try await installer.installedCurrentRuntime()
        XCTAssertNil(notExecutable)

        // Executable present -> installed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let installed = try await installer.installedCurrentRuntime()
        XCTAssertEqual(installed?.executableURL, executable.standardizedFileURL)
        XCTAssertEqual(installed?.version, .unknown)
    }

    // MARK: - Installer subprocess execution + de-quarantine (no network)

    func testInstallLatestRunsScriptDeQuarantinesAndReturnsExecutable() async throws {
        let installDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: installDir) }

        // Fake installer script: create $FORGE3_INSTALL_DIR/bin/forge3.
        let scriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptDir) }
        let scriptURL = scriptDir.appendingPathComponent("install.sh")
        let script = """
        #!/bin/sh
        mkdir -p "$FORGE3_INSTALL_DIR/bin"
        printf '#!/bin/sh\\nprintf forge3-ok\\n' > "$FORGE3_INSTALL_DIR/bin/forge3"
        chmod +x "$FORGE3_INSTALL_DIR/bin/forge3"
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installer = RuntimeInstaller(installDir: installDir, installerURL: scriptURL)
        let phases = Locked<[RuntimeInstallationPhase]>([])
        let runtime = try await installer.installLatest { phase in
            phases.withValue { $0.append(phase) }
        }

        let executable = RuntimeInstaller.executableURL(installDir: installDir)
        XCTAssertEqual(runtime.executableURL, executable)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertTrue(phases.value.contains(.resolving))
        XCTAssertTrue(phases.value.contains(.installing))
        XCTAssertEqual(phases.value.last, .ready)

        // Second call sees it as already installed and short-circuits.
        let cached = try await installer.installedCurrentRuntime()
        XCTAssertEqual(cached?.executableURL, executable)
    }

    func testInstallLatestSurfacesInstallerFailure() async throws {
        let installDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: installDir) }
        let scriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thin-fail-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptDir) }
        let scriptURL = scriptDir.appendingPathComponent("install.sh")
        try Data("#!/bin/sh\nexit 7\n".utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installer = RuntimeInstaller(installDir: installDir, installerURL: scriptURL)
        do {
            _ = try await installer.installLatest()
            XCTFail("a nonzero installer exit must throw")
        } catch let error as ThinInstallerError {
            XCTAssertEqual(error, .installerFailed(status: 7))
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func withValue(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
