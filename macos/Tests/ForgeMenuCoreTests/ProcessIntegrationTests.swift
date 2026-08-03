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
    private func makeHost(
        fixture: ProcessFixture,
        configuration: ForgeProcessHost.Configuration? = nil,
        runtimeIdentityValidator: any InstalledRuntimeIdentityValidating = PermissiveRuntimeIdentityValidator(),
        lease: RuntimeStoreLease? = nil
    ) throws -> ForgeProcessHost {
        let guardianURL = try locateBuiltGuardianHelper()
        return ForgeProcessHost(
            configuration: configuration ?? .init(
                logURL: fixture.logURL,
                guardianExecutableURL: guardianURL
            ),
            runtimeIdentityValidator: runtimeIdentityValidator,
            lease: lease
        )
    }

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
                }),
                guardianExecutableURL: try locateBuiltGuardianHelper()
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
                }),
                guardianExecutableURL: try locateBuiltGuardianHelper()
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
        let host = try makeHost(
            fixture: fixture,
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
        let host = try makeHost(
            fixture: fixture,
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
            configuration: .init(
                logURL: logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper()
            ),
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
                maximumBufferedOutputBytes: 4_096,
                guardianExecutableURL: try locateBuiltGuardianHelper()
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
        let host = try makeHost(
            fixture: fixture,
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
        let host = try makeHost(
            fixture: fixture,
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
        let host = try makeHost(
            fixture: fixture,
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
            configuration: .init(
                logURL: logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper()
            ),
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

    func testDynamicGuardianDescriptorsWorkWhenAllocationsCrossFormerReservedRange() async throws {
        let heldDescriptors = try openDescriptorsThrough(23)
        defer { heldDescriptors.forEach { close($0) } }
        let fixture = try ProcessFixture(script: "#!/bin/sh\nprintf 'dynamic-descriptors-ready\\n'\nwhile :; do sleep 1; done\n")
        defer { fixture.remove() }
        let host = try makeHost(fixture: fixture)

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_449),
            generation: 79
        )
        try await waitForFile(fixture.logURL, containing: "dynamic-descriptors-ready")
        await host.stop(gracePeriod: 0.1)
    }

    func testOwnerDeathDuringDelayedPreStatusWindowPromptlyCleansGuardianAndService() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-owner-death-pids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let fixture = try ProcessFixture(script: "#!/bin/sh\nwhile :; do sleep 1; done\n")
        defer { fixture.remove() }
        let helper = try locateBuiltGuardianHelper()
        let owner = Process()
        owner.executableURL = helper
        owner.arguments = [
            "--lifecycle-owner-death",
            fixture.scriptURL.path,
            fixture.logURL.path,
            pidFile.path,
            "55456"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["FORGE_INTERNAL_TEST_PRE_HANDSHAKE_DELAY_MS"] = "5000"
        environment["FORGE_INTERNAL_TEST_AFTER_SPAWN_PID_FILE"] = pidFile.path
        owner.environment = environment

        let started = Date()
        try owner.run()
        owner.waitUntilExit()
        XCTAssertEqual(owner.terminationStatus, 0)
        let leader = try await waitForLoggedPID(pidFile, key: "leader")
        let leaderDisappeared = await waitForProcessToDisappear(leader, timeout: 1.5)
        XCTAssertTrue(leaderDisappeared)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testPreHandshakeTimeoutClosesOwnershipChannelAndReapsLeaderAndDescendant() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-pre-handshake-pids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let fixture = try ProcessFixture(script: "#!/bin/sh\nwhile :; do sleep 1; done\n")
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                environment: [
                    "FORGE_INTERNAL_TEST_PRE_HANDSHAKE_DELAY_MS": "1000",
                    "FORGE_INTERNAL_TEST_AFTER_SPAWN_PID_FILE": pidFile.path
                ],
                logURL: fixture.logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper(),
                guardianLaunchTimeout: 0.1
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        do {
            try await host.start(
                runtime: fixture.runtime,
                endpoint: LoopbackEndpoint(port: 55_450),
                generation: 80
            )
            XCTFail("the delayed pre-handshake lifecycle must time out")
        } catch let error as ForgeCoreError {
            guard case .processLaunch(let message) = error else {
                return XCTFail("unexpected launch error: \(error)")
            }
            XCTAssertTrue(message.contains("timed out"), message)
        }

        let leader = try await waitForLoggedPID(pidFile, key: "leader")
        let disappeared = await waitForProcessToDisappear(leader)
        XCTAssertTrue(disappeared)
    }

    func testInjectedThrowImmediatelyAfterSpawnReapsLeaderAndDescendant() async throws {
        try await assertPostSpawnFaultCleansLifecycle(fault: "throw", port: 55_453)
    }

    func testInjectedGuardianSIGKILLImmediatelyAfterSpawnStillCleansOwnedGroup() async throws {
        try await assertPostSpawnFaultCleansLifecycle(fault: "sigkill", port: 55_454)
    }

    func testFragmentedStatusPrefixCannotDefeatGuardianLaunchDeadline() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-status-prefix-pids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let fixture = try ProcessFixture(script: "#!/bin/sh\nwhile :; do sleep 1; done\n")
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                environment: [
                    "FORGE_INTERNAL_TEST_STATUS_PREFIX_STALL": "1",
                    "FORGE_INTERNAL_TEST_AFTER_SPAWN_PID_FILE": pidFile.path
                ],
                logURL: fixture.logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper(),
                guardianLaunchTimeout: 0.2
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        let started = Date()
        do {
            try await host.start(
                runtime: fixture.runtime,
                endpoint: LoopbackEndpoint(port: 55_455),
                generation: 84
            )
            XCTFail("fragmented status must time out")
        } catch let error as ForgeCoreError {
            guard case .processLaunch(let message) = error else {
                return XCTFail("unexpected launch error: \(error)")
            }
            XCTAssertTrue(message.contains("timed out") || message.contains("incomplete"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let leader = try await waitForLoggedPID(pidFile, key: "leader")
        let disappeared = await waitForProcessToDisappear(leader)
        XCTAssertTrue(disappeared)
    }

    func testFramedReadDeadlineSurvivesReadablePrefixThenStall() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.filter { $0 >= 0 }.forEach { close($0) } }
        var prefix: UInt8 = 0x5A
        XCTAssertEqual(send(sockets[0], &prefix, 1, MSG_NOSIGNAL), 1)
        var frame = [UInt8](repeating: 0, count: 16)
        let started = Date()
        let result = frame.withUnsafeMutableBytes { bytes in
            ForgeLifecycleGuardian.readCompleteFrame(
                descriptor: sockets[1],
                bytes: bytes,
                deadline: ForgeLifecycleGuardian.deadline(after: 0.1)
            )
        }
        XCTAssertEqual(result, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(frame[0], prefix)
    }

    func testFramedWriteDeadlineSurvivesPartialProgressThenStall() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.filter { $0 >= 0 }.forEach { close($0) } }
        var bufferSize: Int32 = 4_096
        XCTAssertEqual(
            setsockopt(
                sockets[0],
                SOL_SOCKET,
                SO_SNDBUF,
                &bufferSize,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )
        let flags = fcntl(sockets[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(sockets[0], F_SETFL, flags | O_NONBLOCK), 0)
        var filler = [UInt8](repeating: 0xA5, count: 4_096)
        while send(sockets[0], &filler, filler.count, MSG_NOSIGNAL) > 0 {}
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
        var drained: UInt8 = 0
        XCTAssertEqual(recv(sockets[1], &drained, 1, 0), 1)
        let frame = Data(repeating: 0x3C, count: 1_024 * 1_024)
        let started = Date()
        let complete = frame.withUnsafeBytes { bytes in
            ForgeLifecycleGuardian.writeCompleteFrame(
                descriptor: sockets[0],
                bytes: bytes,
                deadline: ForgeLifecycleGuardian.deadline(after: 0.1)
            )
        }
        XCTAssertFalse(complete)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testGuardianAndServiceDoNotInheritUnrelatedSentinelDescriptor() async throws {
        let sentinel = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(sentinel, 0)
        defer { if sentinel >= 0 { close(sentinel) } }
        XCTAssertEqual(fcntl(sentinel, F_SETFD, 0), 0)

        let fixture = try ProcessFixture(script: """
        #!/bin/sh
        if [ -e /dev/fd/\(sentinel) ]; then
          printf 'sentinel-inherited\\n'
          exit 91
        fi
        printf 'sentinel-closed\\n'
        while :; do sleep 1; done
        """)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                environment: ["FORGE_INTERNAL_TEST_SENTINEL_FD": String(sentinel)],
                logURL: fixture.logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper()
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_451),
            generation: 81
        )
        try await waitForFile(fixture.logURL, containing: "sentinel-closed")
        await host.stop(gracePeriod: 0.1)
    }

    func testStopPacketTransfersExactGraceBeforeSIGKILLEscalation() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        trap '' TERM
        printf 'grace-ready\n'
        while :; do sleep 0.05; done
        """#)
        defer { fixture.remove() }
        let host = try makeHost(fixture: fixture)
        let gracePeriod: TimeInterval = 0.55
        XCTAssertEqual(
            ForgeLifecycleGuardian.stopPacket(gracePeriod: gracePeriod).graceMilliseconds,
            550
        )

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_452),
            generation: 82
        )
        try await waitForFile(fixture.logURL, containing: "grace-ready")
        let started = Date()
        await host.stop(gracePeriod: gracePeriod)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(elapsed, 0.50)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testGuardianFailureKillsPersistentLeaderAndDescendantAndReportsUnexpectedExit() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        sleep 30 &
        child=$!
        printf 'guardian-leader=%s descendant=%s\n' "$$" "$child"
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let host = try makeHost(
            fixture: fixture,
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        let exited = expectation(description: "guardian failure reported")
        host.onExit = { status, _, generation in
            XCTAssertEqual(status, 128 + SIGKILL)
            XCTAssertEqual(generation, 77)
            exited.fulfill()
        }

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_447),
            generation: 77
        )
        let logged = try await waitForLoggedProcessPair(
            fixture.logURL,
            leaderKey: "guardian-leader",
            descendantKey: "descendant"
        )
        let ids = host.lifecycleProcessIDs()
        XCTAssertEqual(ids.service, logged.leader)
        XCTAssertGreaterThan(ids.guardian, 0)
        XCTAssertGreaterThan(ids.service, 0)
        XCTAssertEqual(kill(ids.guardian, SIGKILL), 0)

        await fulfillment(of: [exited], timeout: 3)
        let disappeared = await awaitProcessesToDisappear([logged.leader, logged.descendant])
        XCTAssertTrue(disappeared)
    }

    // Note: the guardian branch this work is ported from also carried a
    // `--forge-internal-lifecycle-termination-probe` entry point, asserting the
    // menu app quit itself when forge3 failed. That policy is deliberately not
    // adopted: the app must survive a forge3 failure so `ServiceSupervisor` can
    // restart it. The probe and its test were dropped with it.

    func testGuardianControlEOFKillsServiceGroupWithinBound() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        trap '' TERM
        sleep 30 &
        child=$!
        printf 'parent-leader=%s descendant=%s\n' "$$" "$child"
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let host = try makeHost(
            fixture: fixture,
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_448),
            generation: 78
        )
        let logged = try await waitForLoggedProcessPair(
            fixture.logURL,
            leaderKey: "parent-leader",
            descendantKey: "descendant"
        )
        let ids = host.lifecycleProcessIDs()
        XCTAssertEqual(ids.service, logged.leader)
        let started = Date()
        // Closing the menu side of the control channel models crash/SIGKILL:
        // the guardian observes EOF and owns bounded group termination without
        // receiving an orderly stop command.
        host.closeLifecycleControlForTesting()
        let serviceGroupDisappeared = await awaitProcessesToDisappear([logged.leader, logged.descendant])
        let guardianDisappeared = await waitForProcessToDisappear(ids.guardian)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(serviceGroupDisappeared)
        XCTAssertTrue(guardianDisappeared)
    }

    func testProcessHostKillsHelperThatIgnoresTermWithinBound() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        trap '' TERM
        printf 'ready\n'
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let host = try makeHost(
            fixture: fixture,
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

    func testProcessHostStopReturnsWhenEscapedDescendantContinuouslyWritesOutput() async throws {
        let escapedPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-escaped-output-pid-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: escapedPIDFile.path) {
                try? FileManager.default.removeItem(at: escapedPIDFile)
            }
        }
        let helper = try locateBuiltGuardianHelper()
        let fixture = try ProcessFixture(script: "unused")
        defer { fixture.remove() }
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: helper
        )
        let host = ForgeProcessHost(
            configuration: .init(
                environment: [
                    "FORGE_TEST_ESCAPED_OUTPUT_PID_FILE": escapedPIDFile.path
                ],
                logURL: fixture.logURL,
                guardianExecutableURL: helper
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )
        var escapedPIDs: [pid_t] = []
        defer {
            escapedPIDs.forEach { _ = kill($0, SIGKILL) }
        }

        try await host.start(
            runtime: runtime,
            endpoint: LoopbackEndpoint(port: 55_457),
            generation: 85
        )
        let firstEscapedPID = try await waitForLoggedPID(escapedPIDFile, key: "escaped")
        escapedPIDs.append(firstEscapedPID)
        try await waitForFile(fixture.logURL, containing: "escaped-output-ready")

        let started = Date()
        await host.stop(gracePeriod: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(processExists(firstEscapedPID))

        let ids = host.lifecycleProcessIDs()
        XCTAssertEqual(ids.guardian, 0)
        XCTAssertEqual(ids.service, 0)
        let restartStarted = Date()
        try await host.start(
            runtime: runtime,
            endpoint: LoopbackEndpoint(port: 55_458),
            generation: 86
        )
        let secondEscapedPID = try await waitForLoggedPID(
            escapedPIDFile,
            key: "escaped",
            occurrence: 2
        )
        escapedPIDs.append(secondEscapedPID)
        await host.stop(gracePeriod: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(restartStarted), 1.5)

        let log = try String(contentsOf: fixture.logURL)
        XCTAssertFalse(log.contains("sk-escaped-output-secret"))
        XCTAssertTrue(log.contains("<redacted>"))
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

    private func assertPostSpawnFaultCleansLifecycle(fault: String, port: UInt16) async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-post-spawn-pids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                environment: [
                    "FORGE_INTERNAL_TEST_AFTER_SPAWN_FAULT": fault,
                    "FORGE_INTERNAL_TEST_AFTER_SPAWN_PID_FILE": pidFile.path
                ],
                logURL: fixture.logURL,
                guardianExecutableURL: try locateBuiltGuardianHelper(),
                guardianLaunchTimeout: 0.3
            ),
            runtimeIdentityValidator: PermissiveRuntimeIdentityValidator()
        )

        do {
            try await host.start(
                runtime: fixture.runtime,
                endpoint: LoopbackEndpoint(port: port),
                generation: 83
            )
            XCTFail("post-spawn fault must reject launch")
        } catch {}
        let leader = try await waitForLoggedPID(pidFile, key: "leader")
        let disappeared = await waitForProcessToDisappear(leader)
        XCTAssertTrue(disappeared)
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

private func openDescriptorsThrough(_ target: Int32) throws -> [Int32] {
    var descriptors: [Int32] = []
    while (descriptors.last ?? -1) < target {
        let descriptor = open("/dev/null", O_RDONLY)
        guard descriptor >= 0 else {
            descriptors.forEach { close($0) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptors.append(descriptor)
    }
    return descriptors
}

private func waitForLoggedPID(
    _ url: URL,
    key: String,
    occurrence: Int = 1,
    timeout: TimeInterval = 3
) async throws -> pid_t {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))=(\\d+)\\b"
    let expression = try NSRegularExpression(pattern: pattern)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: url) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = expression.matches(in: text, range: range)
            if occurrence > 0,
               matches.count >= occurrence,
               let pidRange = Range(matches[occurrence - 1].range(at: 1), in: text),
               let pid = pid_t(text[pidRange]) {
                return pid
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw RuntimeInstallerError.processTimeout
}

private func waitForLoggedProcessPair(
    _ url: URL,
    leaderKey: String,
    descendantKey: String,
    timeout: TimeInterval = 3
) async throws -> (leader: pid_t, descendant: pid_t) {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: leaderKey))=(\\d+) "
        + "\(NSRegularExpression.escapedPattern(for: descendantKey))=(\\d+)\\b"
    let expression = try NSRegularExpression(pattern: pattern)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: url) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = expression.firstMatch(in: text, range: range),
               let leaderRange = Range(match.range(at: 1), in: text),
               let descendantRange = Range(match.range(at: 2), in: text),
               let leader = pid_t(text[leaderRange]),
               let descendant = pid_t(text[descendantRange]) {
                return (leader, descendant)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw RuntimeInstallerError.processTimeout
}

private func awaitProcessesToDisappear(_ pids: [pid_t], timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if pids.allSatisfy({ !processExists($0) }) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return pids.allSatisfy { !processExists($0) }
}

private func processExists(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard count == MemoryLayout<proc_bsdinfo>.size else { return false }
    // A descendant can briefly remain as a zombie until its new parent reaps
    // it. It has already terminated and cannot keep the lifecycle group alive.
    return info.pbi_status != UInt32(SZOMB)
}

private func locateBuiltGuardianHelper() throws -> URL {
    try locateBuiltExecutable(named: "ForgeRuntimeLeaseTestHelper")
}

private func locateBuiltMenuBarExecutable() throws -> URL {
    try locateBuiltExecutable(named: "ForgeMenuBar")
}

private func locateBuiltExecutable(named name: String) throws -> URL {
    let testsURL = Bundle(for: ProcessIntegrationTests.self).bundleURL
    let candidates = [
        testsURL.deletingLastPathComponent().appendingPathComponent(name),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/\(name)")
    ]
    return try XCTUnwrap(
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
        "Could not locate built \(name) executable. Checked: \(candidates.map(\.path))"
    )
}

private func waitForProcessToDisappear(_ pid: pid_t, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return kill(pid, 0) == -1 && errno == ESRCH
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
