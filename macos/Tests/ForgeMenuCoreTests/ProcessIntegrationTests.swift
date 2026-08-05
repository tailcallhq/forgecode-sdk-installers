import Darwin
import Foundation
import XCTest
@testable import ForgeMenuCore

final class ProcessIntegrationTests: XCTestCase {
    func testProcessHostUsesExactArgumentsEnvironmentAndRedactedLog() async throws {
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        printf '%s\n' "$@"
        printf 'FORGE_DATA_DIR=%s\n' "${FORGE_DATA_DIR-unset}"
        printf 'FORGE_CONFIG_DIR=%s\n' "${FORGE_CONFIG_DIR-unset}"
        printf 'FORGE_GUARDIAN_TEST=%s\n' "${FORGE_GUARDIAN_TEST-unset}"
        printf 'api_key=sk-integrationsecret\n'
        sleep 30
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(
                environment: ["FORGE_GUARDIAN_TEST": "visible"],
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
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
        XCTAssertTrue(log.contains("FORGE_GUARDIAN_TEST=visible"))
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
                guardianExecutableURL: try guardianExecutableURL()
            )
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
                guardianExecutableURL: try guardianExecutableURL()
            )
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
            configuration: .init(
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
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

    func testProcessHostRejectsMissingExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("forge3")
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: missing
        )
        let host = ForgeProcessHost(
            configuration: .init(logURL: directory.appendingPathComponent("forge3.jsonl"))
        )
        do {
            try await host.start(runtime: runtime, endpoint: LoopbackEndpoint(port: 55_439), generation: 1)
            XCTFail("starting a missing executable must fail")
        } catch {
            XCTAssertEqual(error as? ForgeCoreError, .missingExecutable(missing.standardizedFileURL.path))
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
            configuration: .init(
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
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
                guardianExecutableURL: try guardianExecutableURL()
            )
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
            configuration: .init(
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
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

    func testProcessHostKillsWholeProcessGroupLeavingNoOrphans() async throws {
        // The child spawns a grandchild in the same process group that ignores
        // SIGTERM. Group-kill on stop() must reap the descendant too, and the
        // stop must still return within the grace bound.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("forge3")
        let logURL = directory.appendingPathComponent("forge3.jsonl")
        let markerURL = directory.appendingPathComponent("grandchild.marker")
        let script = """
        #!/bin/sh
        (
          trap '' TERM
          printf 'gc\\n' > \(markerURL.path)
          while :; do sleep 1; done
        ) &
        printf 'parent-ready\\n'
        wait
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureRuntime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: scriptURL
        )

        let host = ForgeProcessHost(
            configuration: .init(
                logURL: logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
        )
        try await host.start(runtime: fixtureRuntime, endpoint: LoopbackEndpoint(port: 55_450), generation: 1)
        try await waitForFile(logURL, containing: "parent-ready")
        // Wait for the grandchild to record its presence.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: markerURL.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        let started = Date()
        await host.stop(gracePeriod: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testGuardianPropagatesImmediateRestartExitStatus() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\nexit 75\n")
        defer { fixture.remove() }
        let recorder = ProcessExitRecorder(expectedFulfillmentCount: 1)
        let host = ForgeProcessHost(
            configuration: .init(
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
        )
        host.onExit = { status, _, generation in
            recorder.record(status: status, generation: generation)
        }

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_451),
            generation: 31
        )
        await fulfillment(of: [recorder.expectation], timeout: 5)
        XCTAssertEqual(recorder.status, 75)
        XCTAssertEqual(recorder.generation, 31)
    }

    func testGuardianMapsServiceSignalToShellStatus() async throws {
        let fixture = try ProcessFixture(script: "#!/bin/sh\necho $$ > \"$FORGE_PID_FILE\"\nwhile :; do sleep 1; done\n")
        defer { fixture.remove() }
        let pidURL = fixture.directory.appendingPathComponent("forge3.pid")
        let recorder = ProcessExitRecorder(expectedFulfillmentCount: 1)
        let host = ForgeProcessHost(
            configuration: .init(
                environment: ["FORGE_PID_FILE": pidURL.path],
                logURL: fixture.logURL,
                guardianExecutableURL: try guardianExecutableURL()
            )
        )
        host.onExit = { status, _, _ in recorder.record(status: status, generation: 0) }

        try await host.start(
            runtime: fixture.runtime,
            endpoint: LoopbackEndpoint(port: 55_452),
            generation: 32
        )
        let servicePID = try await waitForPID(in: pidURL)
        XCTAssertEqual(kill(servicePID, SIGKILL), 0)
        await fulfillment(of: [recorder.expectation], timeout: 5)
        XCTAssertEqual(recorder.status, 128 + SIGKILL)
    }

    func testGuardianDeathPipeEOFRemovesServiceWithoutOrphan() async throws {
        let guardianURL = try guardianExecutableURL()
        let fixture = try ProcessFixture(script: #"""
        #!/bin/sh
        trap '' TERM
        echo $$ > "$FORGE_PID_FILE"
        while :; do sleep 1; done
        """#)
        defer { fixture.remove() }
        let pidURL = fixture.directory.appendingPathComponent("orphan.pid")
        var deathDescriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&deathDescriptors), 0)
        var guardianPID: pid_t = 0
        var servicePID: pid_t = 0
        defer {
            close(deathDescriptors[0])
            close(deathDescriptors[1])
            if servicePID > 0 { _ = kill(servicePID, SIGKILL) }
            if guardianPID > 0 {
                _ = kill(-guardianPID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(guardianPID, &status, WNOHANG)
            }
        }

        guardianPID = try spawnGuardian(
            guardianURL: guardianURL,
            serviceURL: fixture.scriptURL,
            deathReadDescriptor: deathDescriptors[0],
            deathWriteDescriptor: deathDescriptors[1],
            environment: ["FORGE_PID_FILE": pidURL.path]
        )
        close(deathDescriptors[0])
        deathDescriptors[0] = -1
        servicePID = try await waitForPID(in: pidURL)

        close(deathDescriptors[1])
        deathDescriptors[1] = -1
        try await waitForProcessToDisappear(servicePID, timeout: 5)
        XCTAssertEqual(kill(servicePID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        try await waitForProcessToDisappear(guardianPID, timeout: 5, reapChild: true)
        guardianPID = 0
        servicePID = 0
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

    private func guardianExecutableURL() throws -> URL {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directCandidate = packageDirectory.appendingPathComponent(".build/debug/ForgeMenuBar")
        if FileManager.default.isExecutableFile(atPath: directCandidate.path) {
            return directCandidate.resolvingSymlinksInPath()
        }

        let buildDirectory = packageDirectory.appendingPathComponent(".build")
        if let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let candidate as URL in enumerator
                where candidate.lastPathComponent == "ForgeMenuBar"
                    && FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        throw XCTSkip("ForgeMenuBar executable is absent; run swift build before integration tests")
    }

    private func spawnGuardian(
        guardianURL: URL,
        serviceURL: URL,
        deathReadDescriptor: Int32,
        deathWriteDescriptor: Int32,
        environment overrides: [String: String]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        XCTAssertEqual(posix_spawn_file_actions_init(&actions), 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        XCTAssertEqual(posix_spawn_file_actions_addclose(&actions, deathWriteDescriptor), 0)
        XCTAssertEqual(
            posix_spawn_file_actions_adddup2(
                &actions,
                deathReadDescriptor,
                ForgeGuardian.deathDescriptor
            ),
            0
        )
        if deathReadDescriptor != ForgeGuardian.deathDescriptor {
            XCTAssertEqual(posix_spawn_file_actions_addclose(&actions, deathReadDescriptor), 0)
        }

        var attributes: posix_spawnattr_t?
        XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertEqual(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            0
        )
        XCTAssertEqual(posix_spawnattr_setpgroup(&attributes, 0), 0)

        let arguments = [
            guardianURL.lastPathComponent,
            ForgeGuardian.argumentMarker,
            serviceURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        overrides.forEach { environment[$0.key] = $0.value }
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var processID: pid_t = 0
        let result = posix_spawn(
            &processID,
            guardianURL.path,
            &actions,
            &attributes,
            &argv,
            &envp
        )
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(result))]
            )
        }
        return processID
    }

    private func waitForPID(in url: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: url),
               let processID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for process ID in \(url.path)")
        throw CancellationError()
    }

    private func waitForProcessToDisappear(
        _ processID: pid_t,
        timeout: TimeInterval,
        reapChild: Bool = false
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if reapChild {
                var status: Int32 = 0
                if waitpid(processID, &status, WNOHANG) == processID { return }
            } else if kill(processID, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Process \(processID) still exists after \(timeout) seconds")
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

private final class ProcessExitRecorder: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var recordedStatus: Int32?
    private var recordedGeneration: UInt64?

    var status: Int32? { lock.withLock { recordedStatus } }
    var generation: UInt64? { lock.withLock { recordedGeneration } }

    init(expectedFulfillmentCount: Int) {
        expectation = XCTestExpectation(description: "process exit")
        expectation.expectedFulfillmentCount = expectedFulfillmentCount
    }

    func record(status: Int32, generation: UInt64) {
        lock.withLock {
            recordedStatus = status
            recordedGeneration = generation
        }
        expectation.fulfill()
    }
}

private struct ProcessFixture {
    let directory: URL
    let scriptURL: URL
    let logURL: URL
    var runtime: InstalledRuntime {
        InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .native,
            executableURL: scriptURL
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
