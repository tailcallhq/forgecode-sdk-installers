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
            configuration: .init(executableURL: fixture.scriptURL, logURL: fixture.logURL)
        )
        let endpoint = LoopbackEndpoint(port: 55_432)

        try await host.start(endpoint: endpoint)
        try await waitForFile(fixture.logURL, containing: "127.0.0.1:55432")
        let started = Date()
        await host.stop(gracePeriod: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let log = try String(contentsOf: fixture.logURL)
        XCTAssertTrue(log.contains("--log-format\njson\nws\n--addr\n127.0.0.1:55432"))
        XCTAssertTrue(log.contains("FORGE_DATA_DIR=unset"))
        XCTAssertTrue(log.contains("FORGE_CONFIG_DIR=unset"))
        XCTAssertFalse(log.contains("sk-integrationsecret"))
        XCTAssertTrue(log.contains("<redacted>"))
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
                executableURL: fixture.scriptURL,
                logURL: fixture.logURL,
                maximumBufferedOutputBytes: 4_096
            )
        )

        try await host.start(endpoint: LoopbackEndpoint(port: 55_434))
        try await waitForFile(fixture.logURL, containing: "output truncated")
        await host.stop(gracePeriod: 0.1)

        let log = try String(contentsOf: fixture.logURL)
        XCTAssertTrue(log.contains("output truncated"))
        XCTAssertLessThan(log.utf8.count, 15_000)
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
            configuration: .init(executableURL: fixture.scriptURL, logURL: fixture.logURL)
        )

        try await host.start(endpoint: LoopbackEndpoint(port: 55_433))
        try await waitForFile(fixture.logURL, containing: "ready")
        let started = Date()
        await host.stop(gracePeriod: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testRuntimePathsRequireUniversalHelperLocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Forge Menu Bar.app")
        let helper = bundle.appendingPathComponent("Contents/Helpers/forge3")
        let library = directory.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let paths = try RuntimePaths.resolve(bundleURL: bundle, libraryDirectory: library)
        XCTAssertEqual(paths.forgeExecutable, helper)
        XCTAssertEqual(paths.serviceLog, library.appendingPathComponent("Logs/ForgeMenuBar/forge3.jsonl"))
    }

    private func waitForFile(_ url: URL, containing value: String) async throws {
        let deadline = Date().addingTimeInterval(2)
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
