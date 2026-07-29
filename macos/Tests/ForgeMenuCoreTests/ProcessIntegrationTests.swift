import Darwin
import Foundation
import XCTest
@testable import ForgeMenuCore

private struct PermissiveRuntimeIdentityValidator: InstalledRuntimeIdentityValidating {
    func validate(_ runtime: InstalledRuntime) throws {}
}

private struct RejectingRuntimeIdentityValidator: InstalledRuntimeIdentityValidating {
    func validate(_ runtime: InstalledRuntime) throws {
        throw RuntimeInstallerError.untrustedStoreItem("identity changed")
    }
}

final class ProcessIntegrationTests: XCTestCase {
    func testProcessHostAcceptsSafeSelfReplacementAtAdjacentLaunchValidation() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'original-must-not-run\\n'\nsleep 30\n")
        defer { fixture.remove() }
        let originalIdentity = try RuntimeExecutableIdentityValidator.capture(fixture.scriptURL)
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: fixture.scriptURL,
            executableIdentity: originalIdentity
        )
        let replacement = fixture.directory.appendingPathComponent("replacement")
        try Data("#!/bin/sh\nprintf 'self-replaced-runtime\\n'\nsleep 30\n".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
        let host = ForgeProcessHost(
            configuration: .init(
                logURL: fixture.logURL,
                launchHooks: RuntimePinnedLaunchHooks(beforeFinalIdentityValidation: {
                    try FileManager.default.removeItem(at: fixture.scriptURL)
                    try FileManager.default.moveItem(at: replacement, to: fixture.scriptURL)
                })
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(runtime: runtime, endpoint: LoopbackEndpoint(port: 55_444), generation: 1)
        try await waitForFile(fixture.logURL, containing: "self-replaced-runtime")
        XCTAssertNotEqual(try inode(fixture.scriptURL), originalIdentity.inode)
        await host.stop(gracePeriod: 0.1)
        let log = try String(contentsOf: fixture.logURL)
        XCTAssertTrue(log.contains("self-replaced-runtime"))
        XCTAssertFalse(log.contains("original-must-not-run"))
    }

    func testProcessHostPinnedParentPreventsAncestorReplacementRedirect() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalDirectory = parent.appendingPathComponent("runtime")
        let movedDirectory = parent.appendingPathComponent("runtime-pinned")
        let replacementDirectory = parent.appendingPathComponent("runtime-replacement")
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let originalExecutable = originalDirectory.appendingPathComponent("forge3")
        let replacementExecutable = replacementDirectory.appendingPathComponent("forge3")
        let logURL = parent.appendingPathComponent("ancestor.jsonl")
        try Data("#!/bin/sh\nprintf 'pinned-original\\n'\nsleep 30\n".utf8).write(to: originalExecutable)
        try Data("#!/bin/sh\nprintf 'redirected-replacement\\n'\nsleep 30\n".utf8).write(to: replacementExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: originalExecutable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacementExecutable.path)
        let identity = try RuntimeExecutableIdentityValidator.capture(originalExecutable)
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: originalExecutable,
            executableIdentity: identity
        )
        let host = ForgeProcessHost(
            configuration: .init(
                logURL: logURL,
                launchHooks: RuntimePinnedLaunchHooks(beforeFinalIdentityValidation: {
                    try FileManager.default.moveItem(at: originalDirectory, to: movedDirectory)
                    try FileManager.default.moveItem(at: replacementDirectory, to: originalDirectory)
                })
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(runtime: runtime, endpoint: LoopbackEndpoint(port: 55_445), generation: 1)
        try await waitForFile(logURL, containing: "pinned-original")
        await host.stop(gracePeriod: 0.1)
        let log = try String(contentsOf: logURL)
        XCTAssertTrue(log.contains("pinned-original"))
        XCTAssertFalse(log.contains("redirected-replacement"))
    }

    func testProcessHostRetainsSharedStoreLeaseUntilServiceIsReaped() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'lease-ready\\n'\nsleep 30\n")
        defer { fixture.remove() }
        let runtimeRoot = fixture.directory.appendingPathComponent("runtime-store")
        let lease = RuntimeStoreLease(rootURL: runtimeRoot)
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator(),
            lease: lease
        )

        try await host.start(runtime: fixture.runtime, endpoint: LoopbackEndpoint(port: 55_446), generation: 1)
        try await waitForFile(fixture.logURL, containing: "lease-ready")
        let exclusiveTask = Task.detached { try lease.acquire(.exclusiveMutation) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let probeDescriptor = open(lease.lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(probeDescriptor, 0)
        if probeDescriptor >= 0 {
            XCTAssertEqual(flock(probeDescriptor, LOCK_EX | LOCK_NB), -1)
            XCTAssertEqual(errno, EWOULDBLOCK)
            close(probeDescriptor)
        }

        await host.stop(gracePeriod: 0.1)
        let exclusive = try await exclusiveTask.value
        exclusive.release()
    }

    func testProcessHostUsesExactArgumentsEnvironmentAndRedactedLog() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        printf '%s\n' "$@"
        printf 'FORGE_DATA_DIR=%s\n' "${FORGE_DATA_DIR-unset}"
        printf 'FORGE_CONFIG_DIR=%s\n' "${FORGE_CONFIG_DIR-unset}"
        printf 'api_key=sk-integrationsecret\n'
        sleep 30
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        let endpoint = LoopbackEndpoint(port: 55_432)

        try await host.start(runtime: fixture.runtime, endpoint: endpoint, generation: 1)
        try await waitForFile(fixture.logURL, containing: "127.0.0.1:55432")
        let started = Date()
        await host.stop(gracePeriod: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let log = try String(contentsOf: fixture.logURL)
        XCTAssertTrue(log.contains("--log-format\njson\nws\n--addr\n127.0.0.1:55432"))
        XCTAssertTrue(log.contains("FORGE_DATA_DIR=unset"))
        XCTAssertTrue(log.contains("FORGE_CONFIG_DIR=unset"))
        XCTAssertFalse(log.contains("sk-integrationsecret"))
        XCTAssertTrue(log.contains("<redacted>"))
    }

    func testProcessHostUsesExecutableSelectedForEachLifecycle() async throws {
        let first = try ProcessFixture(script: "#!/bin/sh\nprintf 'first-runtime\\n'\nsleep 30\n")
        let second = try ProcessFixture(script: "#!/bin/sh\nprintf 'second-runtime\\n'\nsleep 30\n")
        defer { first.remove(); second.remove() }
        let logURL = first.directory.appendingPathComponent("selected-runtime.jsonl")
        let host = ForgeProcessHost(
            configuration: .init(logURL: logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(
            runtime: first.runtime,
            endpoint: LoopbackEndpoint(port: 55_435),
            generation: 11
        )
        try await waitForFile(logURL, containing: "first-runtime")
        await host.stop(gracePeriod: 0.1)

        try await host.start(
            runtime: second.runtime,
            endpoint: LoopbackEndpoint(port: 55_436),
            generation: 12
        )
        try await waitForFile(logURL, containing: "second-runtime")
        await host.stop(gracePeriod: 0.1)

        let log = try String(contentsOf: logURL)
        XCTAssertTrue(log.contains("first-runtime"))
        XCTAssertTrue(log.contains("second-runtime"))
    }

    func testProcessHostBoundsSingleLineOutputBuffer() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        i=0
        while [ "$i" -lt 20000 ]; do
          printf x
          i=$((i + 1))
        done
        sleep 30
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                logURL: fixture.logURL,
                maximumBufferedOutputBytes: 4_096
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_434),
            generation: 1
        )
        try await waitForFile(fixture.logURL, containing: "output truncated")
        await host.stop(gracePeriod: 0.1)

        let log = try String(contentsOf: fixture.logURL)
        XCTAssertTrue(log.contains("output truncated"))
        XCTAssertLessThan(log.utf8.count, 15_000)
    }

    func testProcessHostRejectsSecondStartWhileRunning() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'ready\\n'\nsleep 30\n")
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_437),
            generation: 1
        )
        try await waitForFile(fixture.logURL, containing: "ready")

        do {
            try await host.start(
                runtime: fixture.runtime,
                endpoint: LoopbackEndpoint(port: 55_438),
                generation: 2
            )
            XCTFail("a second start must fail")
        } catch {
            XCTAssertEqual(error as? ForgeCoreError, .processAlreadyRunning)
        }
        await host.stop(gracePeriod: 0.1)
    }

    func testProcessHostValidatesRuntimeIdentityBeforeSpawn() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'must-not-run\\n'\n")
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: RejectingRuntimeIdentityValidator()
        )

        do {
            try await host.start(
                runtime: fixture.runtime,
                endpoint: LoopbackEndpoint(port: 55_439),
                generation: 1
            )
            XCTFail("identity validation must reject the process")
        } catch {
            XCTAssertEqual(error as? RuntimeInstallerError, .untrustedStoreItem("identity changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.logURL.path))
    }

    func testDefaultProcessValidatorAcceptsSafeCurrentFileWithoutReceiptIdentity() throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'safe\\n'\n")
        defer { fixture.remove() }
        let validator = InstalledRuntimeIdentityValidator()
        let staleIdentity = try RuntimeExecutableIdentityValidator.capture(fixture.scriptURL)
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .arm64,
            executableURL: fixture.scriptURL,
            executableIdentity: staleIdentity
        )

        let replacement = fixture.directory.appendingPathComponent("replacement")
        try Data("#!/bin/sh\nprintf 'new-content-and-inode\\n'\n".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: fixture.scriptURL)
        try FileManager.default.moveItem(at: replacement, to: fixture.scriptURL)

        XCTAssertNotEqual(try inode(fixture.scriptURL), staleIdentity.inode)
        XCTAssertNoThrow(try validator.validate(runtime))
        XCTAssertNoThrow(try validator.validate(InstalledRuntime(
            version: runtime.version,
            architecture: runtime.architecture,
            executableURL: runtime.executableURL
        )))
    }

    func testDefaultProcessValidatorRejectsUnsafeCurrentFiles() throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'unsafe\\n'\n")
        defer { fixture.remove() }
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: fixture.scriptURL
        )
        let validator = InstalledRuntimeIdentityValidator()

        let symlink = fixture.directory.appendingPathComponent("forge3-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.scriptURL)
        XCTAssertThrowsError(try validator.validate(InstalledRuntime(
            version: runtime.version,
            architecture: runtime.architecture,
            executableURL: symlink
        )))

        let linkedDirectory = fixture.directory.appendingPathComponent("runtime-link")
        let realDirectory = fixture.directory.appendingPathComponent("runtime-real")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let linkedExecutable = realDirectory.appendingPathComponent("forge3")
        try Data("#!/bin/sh\nprintf 'linked\\n'\n".utf8).write(to: linkedExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: linkedExecutable.path)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        XCTAssertThrowsError(try validator.validate(InstalledRuntime(
            version: runtime.version,
            architecture: runtime.architecture,
            executableURL: linkedDirectory.appendingPathComponent("forge3")
        )))

        let hardlink = fixture.directory.appendingPathComponent("forge3-hardlink")
        try FileManager.default.linkItem(at: fixture.scriptURL, to: hardlink)
        XCTAssertThrowsError(try validator.validate(runtime))
        try FileManager.default.removeItem(at: hardlink)

        XCTAssertThrowsError(
            try InstalledRuntimeIdentityValidator(expectedUserID: geteuid() &+ 1).validate(runtime)
        )

        for mode in [0o720, 0o702, 0o600] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.scriptURL.path)
            XCTAssertThrowsError(try validator.validate(runtime), "mode \(String(mode, radix: 8))")
        }
    }

    func testProcessHostConnectsChildStdinToEOF() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        if IFS= read -r value; then
          printf 'stdin-data:%s\n' "$value"
        else
          printf 'stdin-eof\n'
        fi
        sleep 30
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_440),
            generation: 1
        )
        try await waitForFile(fixture.logURL, containing: "stdin-eof")
        await host.stop(gracePeriod: 0.1)
    }

    func testCompletedStopTimerCannotKillReplacementLifecycle() async throws {
        let first = try ProcessFixture(script: "#!/bin/sh\nprintf 'first-ready\\n'\nsleep 30\n")
        let second = try ProcessFixture(script: "#!/bin/sh\nprintf 'second-ready\\n'\nsleep 30\n")
        defer { first.remove(); second.remove() }
        let logURL = first.directory.appendingPathComponent("stale-timer.jsonl")
        let host = ForgeProcessHost(
            configuration: .init(logURL: logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        try await host.start(runtime: first.runtime, endpoint: LoopbackEndpoint(port: 55_441), generation: 1)
        try await waitForFile(logURL, containing: "first-ready")
        await host.stop(gracePeriod: 0.2)
        try await host.start(runtime: second.runtime, endpoint: LoopbackEndpoint(port: 55_442), generation: 2)
        try await waitForFile(logURL, containing: "second-ready")
        // Sleep past the first lifecycle's grace deadline so a stale kill
        // timer, if one survived, would have fired against the replacement.
        try await Task.sleep(nanoseconds: 400_000_000)

        do {
            try await host.start(runtime: second.runtime, endpoint: LoopbackEndpoint(port: 55_443), generation: 3)
            XCTFail("replacement should still be running after the stale timer deadline")
        } catch {
            XCTAssertEqual(error as? ForgeCoreError, .processAlreadyRunning)
        }
        await host.stop(gracePeriod: 0.1)
    }

    func testProcessHostKillsHelperThatIgnoresTermWithinBound() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        trap '' TERM
        printf 'ready\n'
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_433),
            generation: 1
        )
        try await waitForFile(fixture.logURL, containing: "ready")
        let started = Date()
        await host.stop(gracePeriod: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testRuntimePathsCanResolveLogsBeforeRuntimeExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Library")

        let paths = try RuntimePaths.resolve(libraryDirectory: library)
        XCTAssertEqual(
            paths.serviceLog,
            library.appendingPathComponent("Logs/ForgeMenuBar/forge3.jsonl")
        )
        XCTAssertEqual(paths.logsDirectory, library.appendingPathComponent("Logs/ForgeMenuBar"))
    }

    private func waitForFile(_ url: URL, containing value: String) async throws {
        // Generous deadline: passing runs return in milliseconds; the bound
        // only limits how long a genuine failure can stall a loaded CI runner.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let text = try? String(contentsOf: url), text.contains(value) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(value) in \(url.path)")
    }
}

private func inode(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.systemFileNumber] as? NSNumber else {
        throw RuntimeInstallerError.processFailure("could not read runtime inode")
    }
    return value.uint64Value
}

private struct ProcessFixture {
    let directory: URL
    let scriptURL: URL
    let logURL: URL
    var runtime: InstalledRuntime {
        InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: scriptURL,
            executableIdentity: try? RuntimeExecutableIdentityValidator.capture(scriptURL)
        )
    }

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        scriptURL = directory.appendingPathComponent("forge3")
        logURL = directory.appendingPathComponent("forge3.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
