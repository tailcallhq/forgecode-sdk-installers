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
        printf 'api_key=sk-integrationsecret\n'
        sleep 30
        """#)
        defer { fixture.remove() }
        let host = ForgeProcessHost(
            configuration: .init(logURL: fixture.logURL)
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
            configuration: .init(logURL: logURL)
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
            configuration: .init(logURL: fixture.logURL)
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
            configuration: .init(logURL: fixture.logURL)
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
            configuration: .init(logURL: logURL)
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
            configuration: .init(logURL: fixture.logURL)
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
            configuration: .init(logURL: logURL)
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
