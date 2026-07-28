import Foundation
import XCTest
@testable import ForgeMenuCore

final class CoreBehaviorTests: XCTestCase {
    func testRunServiceDefaultsTrueAndPersists() throws {
        let suite = "CoreBehaviorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.runService)
        preferences.runService = false
        XCTAssertFalse(AppPreferences(defaults: defaults).runService)
    }

    func testConsoleOriginPreferencePersistsAndClears() throws {
        let suite = "ConsoleOriginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.consoleOrigin = "http://127.0.0.1:5173"
        XCTAssertEqual(AppPreferences(defaults: defaults).consoleOrigin, "http://127.0.0.1:5173")
        preferences.consoleOrigin = nil
        XCTAssertNil(preferences.consoleOrigin)
    }

    func testConsoleOriginResolutionPriorityAndValidation() throws {
        XCTAssertEqual(
            try ConsoleURLBuilder.resolvedOrigin(preference: nil, environment: [:]).absoluteString,
            "https://console.forgecode.dev"
        )
        XCTAssertEqual(
            try ConsoleURLBuilder.resolvedOrigin(
                preference: "https://preference.example",
                environment: [ConsoleURLBuilder.environmentKey: "http://127.0.0.1:5173"]
            ).absoluteString,
            "http://127.0.0.1:5173"
        )
        XCTAssertThrowsError(try ConsoleURLBuilder.validateOrigin("file:///tmp"))
        XCTAssertThrowsError(try ConsoleURLBuilder.validateOrigin("https://example.com/path"))
        XCTAssertThrowsError(try ConsoleURLBuilder.validateOrigin("https://example.com?token=secret"))
        XCTAssertThrowsError(try ConsoleURLBuilder.validateOrigin("https://user@example.com"))
    }

    func testConversationURLPercentEncodesIDWithoutOriginLeakage() throws {
        let origin = try ConsoleURLBuilder.validateOrigin("http://127.0.0.1:5173")
        let url = try ConsoleURLBuilder.conversationURL(
            conversationID: "root/a?next=#fragment ü",
            origin: origin
        )
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 5173)
        XCTAssertEqual(url.query, nil)
        XCTAssertEqual(url.fragment, nil)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/c/root%2Fa%3Fnext%3D%23fragment%20%C3%BC")
    }

    func testConsoleAndConversationURLsCarryConnectEndpoint() throws {
        let origin = try ConsoleURLBuilder.validateOrigin("https://console.forgecode.dev")
        let endpoint = LoopbackEndpoint(port: 9_755)

        let console = try ConsoleURLBuilder.consoleURL(origin: origin, endpoint: endpoint)
        XCTAssertEqual(console.absoluteString, "https://console.forgecode.dev/?connect=127.0.0.1:9755")

        let conversation = try ConsoleURLBuilder.conversationURL(
            conversationID: "abc-123",
            origin: origin,
            endpoint: endpoint
        )
        XCTAssertEqual(
            conversation.absoluteString,
            "https://console.forgecode.dev/c/abc-123?connect=127.0.0.1:9755"
        )

        let withoutEndpoint = try ConsoleURLBuilder.consoleURL(origin: origin, endpoint: nil)
        XCTAssertNil(withoutEndpoint.query)
    }

    func testRestartBackoffCapsAndResetsAfterStableRun() {
        let backoff = RestartBackoff(baseDelay: 1, maximumDelay: 8, stableRunThreshold: 120)
        XCTAssertEqual(backoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(backoff.delay(forAttempt: 2), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 4), 8)
        XCTAssertEqual(backoff.delay(forAttempt: 12), 8)
        XCTAssertEqual(backoff.nextAttempt(previousAttempt: 4, runtime: 20), 5)
        XCTAssertEqual(backoff.nextAttempt(previousAttempt: 4, runtime: 121), 1)
    }

    func testRedactorRemovesCommonSecrets() {
        let input = "authorization=Bearer abc.DEF api_key=sk-test12345678 refresh_token: supersecret ghp_abcdefghijk"
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("abc.DEF"))
        XCTAssertFalse(output.contains("sk-test12345678"))
        XCTAssertFalse(output.contains("supersecret"))
        XCTAssertFalse(output.contains("ghp_abcdefghijk"))
        XCTAssertTrue(output.contains("<redacted>"))
    }

    func testJSONRedactorRecursivelyRemovesSensitiveValues() throws {
        let input = #"{"level":"info","authorization":"Bearer top-secret","nested":{"api-key":"sk-jsonsecret123","safe":"visible"},"items":[{"refresh_token":"refresh-secret"}]}"#
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("top-secret"))
        XCTAssertFalse(output.contains("sk-jsonsecret123"))
        XCTAssertFalse(output.contains("refresh-secret"))
        XCTAssertTrue(output.contains("visible"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.utf8)))
    }

    func testSanitizedEnvironmentDropsUnrelatedSecretsAndKeepsForgeConfiguration() {
        let sanitized = ForgeProcessHost.sanitizedEnvironment(
            inherited: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin:/bin",
                "AWS_SECRET_ACCESS_KEY": "do-not-inherit",
                "OPENAI_API_KEY": "do-not-inherit",
                "FORGE_CONFIG_DIR": "/tmp/forge-config",
                "RUST_LOG": "warn"
            ],
            overrides: ["FORGE_DATA_DIR": "/tmp/forge-data"]
        )
        XCTAssertEqual(sanitized["HOME"], "/Users/test")
        XCTAssertEqual(sanitized["FORGE_CONFIG_DIR"], "/tmp/forge-config")
        XCTAssertEqual(sanitized["FORGE_DATA_DIR"], "/tmp/forge-data")
        XCTAssertNil(sanitized["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(sanitized["OPENAI_API_KEY"])
    }

    func testLoopbackEndpointUsesExactAddressAndURL() {
        let endpoint = LoopbackEndpoint(port: 54_321)
        XCTAssertEqual(endpoint.address, "127.0.0.1:54321")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "ws://127.0.0.1:54321")
    }

    func testSystemAllocatorStartsAtFrontendDefaultAndIncrements() throws {
        let endpoint = try SystemLoopbackEndpointAllocator().allocate()
        XCTAssertGreaterThanOrEqual(endpoint.port, SystemLoopbackEndpointAllocator.preferredPort)
        XCTAssertEqual(endpoint.webSocketURL.host, "127.0.0.1")
    }

    func testRotatingLogWriterRedactsAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.log")
        let writer = RotatingLogWriter(logURL: url, maximumBytes: 30, retainedFiles: 2)
        writer.append("api_key=sk-abcdefghijk\n")
        writer.append("a second line that rotates\n")
        let current = try String(contentsOf: url)
        let rotated = try String(contentsOf: URL(fileURLWithPath: url.path + ".1"))
        XCTAssertFalse(current.contains("sk-abcdefghijk"))
        XCTAssertFalse(rotated.contains("sk-abcdefghijk"))
        XCTAssertTrue(rotated.contains("<redacted>"))
    }
}
