import Foundation
import XCTest
@testable import ForgeMenuCore

private func blockingDelay(seconds: UInt32) {
    sleep(seconds)
}

final class WebSocketTimeoutTests: XCTestCase {
    func testTimeoutReturnsEvenWhenOperationIgnoresCancellationForever() async throws {
        let started = Date()
        let timeoutHook = expectation(description: "timeout hook")

        do {
            let _: Int = try await WebSocketRPCClient.withTimeout(
                seconds: 0.05,
                operation: "waiting for an unresponsive WebSocket",
                onCancel: { timeoutHook.fulfill() }
            ) {
                // Deliberately block well beyond the deadline. Thread.sleep does
                // not observe Swift Task cancellation, which models a WebSocket
                // receive continuation that cancellation alone does not resume.
                blockingDelay(seconds: 1)
                return 1
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(
                error as? ForgeCoreError,
                .timeout("waiting for an unresponsive WebSocket")
            )
        }

        await fulfillment(of: [timeoutHook], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testParentCancellationReturnsPromptlyAndCancelsUnderlyingOperation() async {
        let cancellationHook = expectation(description: "underlying operation cancelled")
        let started = Date()
        let operation = Task {
            try await WebSocketRPCClient.withTimeout(
                seconds: 30,
                operation: "long WebSocket receive",
                onCancel: { cancellationHook.fulfill() }
            ) {
                blockingDelay(seconds: 1)
                return 1
            }
        }

        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await fulfillment(of: [cancellationHook], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testOperationResultCancelsTimeoutPath() async throws {
        let timeoutHookCalled = LockedFlag()
        let value: Int = try await WebSocketRPCClient.withTimeout(
            seconds: 0.5,
            operation: "fast operation",
            onCancel: { timeoutHookCalled.set() }
        ) {
            42
        }

        XCTAssertEqual(value, 42)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(timeoutHookCalled.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}
