import Foundation
import XCTest
@testable import ForgeMenuCore

private final class RecordingProcessHost: ForgeProcessHosting, @unchecked Sendable {
    var onExit: (@Sendable (Int32, TimeInterval) -> Void)?
    private let lock = NSLock()
    private var operations: [String] = []
    private var endpoints: [LoopbackEndpoint] = []
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    var operationDelay: TimeInterval = 0

    func start(endpoint: LoopbackEndpoint) async throws {
        begin("start")
        defer { end() }
        if operationDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(operationDelay * 1_000_000_000)) }
        lock.withLock { endpoints.append(endpoint) }
    }

    func stop(gracePeriod: TimeInterval) async {
        begin("stop")
        defer { end() }
        if operationDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(operationDelay * 1_000_000_000)) }
    }

    func emitUnexpectedExit(status: Int32, runtime: TimeInterval) { onExit?(status, runtime) }
    func recordedOperations() -> [String] { lock.withLock { operations } }
    func recordedEndpoints() -> [LoopbackEndpoint] { lock.withLock { endpoints } }
    func maxConcurrentOperations() -> Int { lock.withLock { maximumActiveOperations } }

    private func begin(_ operation: String) {
        lock.withLock {
            operations.append(operation)
            activeOperations += 1
            maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        }
    }
    private func end() { lock.withLock { activeOperations -= 1 } }
}

private struct SequenceEndpointAllocator: LoopbackEndpointAllocating {
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var endpoints: [LoopbackEndpoint]
        init(_ endpoints: [LoopbackEndpoint]) { self.endpoints = endpoints }
    }
    let storage: Storage
    init(_ endpoints: [LoopbackEndpoint]) { storage = Storage(endpoints) }
    func allocate() throws -> LoopbackEndpoint {
        try storage.lock.withLock {
            guard !storage.endpoints.isEmpty else { throw ForgeCoreError.portAllocation("test allocator exhausted") }
            return storage.endpoints.removeFirst()
        }
    }
}

private actor ScriptedConversationClient: ForgeRPCClientProtocol {
    enum Step: Sendable {
        case snapshot([ActiveConversation])
        case failure(String)
        case delayedSnapshot([ActiveConversation], nanoseconds: UInt64, ignoreCancellation: Bool)
        case hold
    }

    private var scripts: [[Step]]
    private(set) var streamCallCount = 0
    private(set) var versionCallCount = 0
    private(set) var listCallCount = 0
    private let version: String?
    private var listResults: [[ActiveConversation]]

    init(
        scripts: [[Step]],
        version: String? = "0.1.0",
        listResults: [[ActiveConversation]] = []
    ) {
        self.scripts = scripts
        self.version = version
        self.listResults = listResults
    }

    func activeRootConversationStream() -> AsyncThrowingStream<[ActiveConversation], Error> {
        streamCallCount += 1
        let steps = scripts.isEmpty ? [.hold] : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in steps {
                    switch step {
                    case .snapshot(let values): continuation.yield(values)
                    case .failure(let message):
                        continuation.finish(throwing: ForgeCoreError.connection(message))
                        return
                    case .delayedSnapshot(let values, let nanoseconds, let ignoreCancellation):
                        do { try await Task.sleep(nanoseconds: nanoseconds) }
                        catch { if !ignoreCancellation { continuation.finish(throwing: CancellationError()); return } }
                        continuation.yield(values)
                    case .hold:
                        do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                        catch { continuation.finish(throwing: CancellationError()); return }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func activeRootConversations() async throws -> [ActiveConversation] {
        listCallCount += 1
        guard !listResults.isEmpty else { return [] }
        return listResults.count == 1 ? listResults[0] : listResults.removeFirst()
    }

    func sdkVersion() async throws -> String {
        versionCallCount += 1
        guard let version else { throw ForgeCoreError.connection("version unavailable") }
        return version
    }

    func calls() -> Int { streamCallCount }
    func versionCalls() -> Int { versionCallCount }
    func listCalls() -> Int { listCallCount }
}

final class ServiceSupervisorTests: XCTestCase {
    func testStartInjectsSameEndpointAndBecomesReadyFromFirstSnapshot() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_001)
        let client = ScriptedConversationClient(scripts: [[
            .snapshot([ActiveConversation(id: "root", title: "Root")]), .hold
        ]])
        let captured = Locked<[LoopbackEndpoint]>([])
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { selected in captured.withValue { $0.append(selected) }; return client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.phase == .ready, snapshot.activeConversations.count == 1 { ready.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        let snapshot = await supervisor.snapshot
        XCTAssertEqual(process.recordedEndpoints(), [endpoint])
        XCTAssertEqual(captured.value, [endpoint])
        XCTAssertEqual(snapshot.endpoint, endpoint)
        XCTAssertEqual(snapshot.conversationStreamState, .subscribed)
        XCTAssertEqual(snapshot.activeConversations, [ActiveConversation(id: "root", title: "Root")])
        await supervisor.stopForTermination()
    }

    func testSDKVersionIsReadOnceAndClearedOnStop() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_010)
        let client = ScriptedConversationClient(scripts: [[
            .snapshot([ActiveConversation(id: "a", title: "A")]),
            .snapshot([ActiveConversation(id: "b", title: "B")]),
            .hold
        ]], version: "0.1.0")
        let versioned = expectation(description: "version published")
        versioned.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.sdkVersion == "0.1.0" { versioned.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [versioned], timeout: 2)

        let running = await supervisor.snapshot
        XCTAssertEqual(running.sdkVersion, "0.1.0")
        let versionCalls = await client.versionCalls()
        XCTAssertEqual(versionCalls, 1, "the version must be read once per running helper")

        await supervisor.stopForTermination()
        let stopped = await supervisor.snapshot
        XCTAssertNil(stopped.sdkVersion)
    }

    func testAppVersionIsIndependentOfTheServerVersion() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_030)
        let client = ScriptedConversationClient(scripts: [[
            .snapshot([ActiveConversation(id: "a", title: "A")]), .hold
        ]], version: "0.1.190")
        let versioned = expectation(description: "server version published")
        versioned.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01),
            appVersion: "1.0.0"
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.sdkVersion == "0.1.190" { versioned.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [versioned], timeout: 2)

        let running = await supervisor.snapshot
        XCTAssertEqual(running.appVersion, "1.0.0")
        XCTAssertEqual(running.sdkVersion, "0.1.190")

        await supervisor.stopForTermination()
        let stopped = await supervisor.snapshot
        XCTAssertNil(stopped.sdkVersion, "the server version is service state")
        XCTAssertEqual(
            stopped.appVersion,
            "1.0.0",
            "the app version is not service state and must survive a stop"
        )
    }

    func testPlaceholderTitleIsUpdatedWithoutAStreamEmission() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_020)
        // The stream emits once and then holds, exactly as the SDK behaves
        // while a run is in flight: no further list emission until it ends.
        let client = ScriptedConversationClient(
            scripts: [[
                .snapshot([
                    ActiveConversation(id: "a", title: "Untitled"),
                    ActiveConversation(id: "b", title: "Kept")
                ]),
                .hold
            ]],
            listResults: [[
                ActiveConversation(id: "a", title: "Generated Title"),
                ActiveConversation(id: "b", title: "Changed Elsewhere")
            ]]
        )
        let titled = expectation(description: "title reconciled")
        titled.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { _ in client },
            configuration: .init(
                readinessTimeout: 1,
                readinessPollInterval: 0.01,
                titleRefreshInterval: 0.05
            )
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.activeConversations.first?.title == "Generated Title" { titled.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [titled], timeout: 3)

        let snapshot = await supervisor.snapshot
        XCTAssertEqual(snapshot.activeConversations, [
            ActiveConversation(id: "a", title: "Generated Title"),
            // A row that already had a real title is never overwritten by the
            // reconciliation pass; the stream stays authoritative for it.
            ActiveConversation(id: "b", title: "Kept")
        ])
        await supervisor.stopForTermination()
    }

    func testTitleRefreshStopsWhenNoPlaceholdersRemain() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_021)
        let client = ScriptedConversationClient(
            scripts: [[.snapshot([ActiveConversation(id: "a", title: "Real")]), .hold]]
        )
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { _ in client },
            configuration: .init(
                readinessTimeout: 1,
                readinessPollInterval: 0.01,
                titleRefreshInterval: 0.02
            )
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.phase == .ready { ready.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        try await Task.sleep(nanoseconds: 200_000_000)

        let listCalls = await client.listCalls()
        XCTAssertEqual(listCalls, 0, "no polling when every row already has a title")
        await supervisor.stopForTermination()
    }

    func testVersionFailureDoesNotAffectServiceState() async throws {
        let process = RecordingProcessHost()
        let endpoint = LoopbackEndpoint(port: 50_011)
        let client = ScriptedConversationClient(scripts: [[
            .snapshot([ActiveConversation(id: "a", title: "A")]), .hold
        ]], version: nil)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([endpoint]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.phase == .ready, snapshot.activeConversations.count == 1 { ready.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        let snapshot = await supervisor.snapshot
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertNil(snapshot.sdkVersion)
        XCTAssertNil(snapshot.streamError)
        await supervisor.stopForTermination()
    }

    func testStreamInterruptionClearsRowsAndReconnectsWithAuthoritativeSnapshot() async throws {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [
            [.snapshot([ActiveConversation(id: "old", title: "Old")]), .failure("lost")],
            [.snapshot([ActiveConversation(id: "new", title: "New")]), .hold]
        ])
        let reconnected = expectation(description: "reconnected")
        reconnected.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_002)]),
            clientFactory: { _ in client },
            configuration: .init(
                readinessTimeout: 1,
                readinessPollInterval: 0.01,
                streamReconnectBackoff: .init(baseDelay: 0.01, maximumDelay: 0.01)
            )
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.activeConversations == [ActiveConversation(id: "new", title: "New")] {
                reconnected.fulfill()
            }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [reconnected], timeout: 2)
        let calls = await client.calls()
        let finalSnapshot = await supervisor.snapshot
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalSnapshot.activeConversations.map(\.id), ["new"])
        await supervisor.stopForTermination()
    }

    func testManualRefreshImmediatelyResubscribesAndReplacesRows() async throws {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [
            [.snapshot([ActiveConversation(id: "first", title: "First")]), .hold],
            [.snapshot([ActiveConversation(id: "second", title: "Second")]), .hold]
        ])
        let first = expectation(description: "first")
        first.assertForOverFulfill = false
        let second = expectation(description: "second")
        second.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_003)]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.activeConversations.first?.id == "first" { first.fulfill() }
            if snapshot.activeConversations.first?.id == "second" { second.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [first], timeout: 2)
        await supervisor.refreshNow()
        await fulfillment(of: [second], timeout: 2)
        let calls = await client.calls()
        let finalSnapshot = await supervisor.snapshot
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalSnapshot.activeConversations.map(\.id), ["second"])
        await supervisor.stopForTermination()
    }

    func testDisableClearsConversationAndStreamState() async throws {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [[
            .snapshot([ActiveConversation(id: "active", title: "Active")]), .hold
        ]])
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_004)]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if !snapshot.activeConversations.isEmpty { ready.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        await supervisor.setEnabled(false)
        let snapshot = await supervisor.snapshot
        XCTAssertEqual(snapshot.phase, .disabled)
        XCTAssertNil(snapshot.endpoint)
        XCTAssertTrue(snapshot.activeConversations.isEmpty)
        XCTAssertEqual(snapshot.conversationStreamState, .disconnected)
        XCTAssertNil(snapshot.streamError)
    }

    func testLateSnapshotFromSupersededSubscriptionCannotOverwriteNewGeneration() async throws {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [
            [.delayedSnapshot([ActiveConversation(id: "late", title: "Late")], nanoseconds: 200_000_000, ignoreCancellation: true), .hold],
            [.snapshot([ActiveConversation(id: "current", title: "Current")]), .hold]
        ])
        let current = expectation(description: "current")
        current.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_005)]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.activeConversations.first?.id == "current" { current.fulfill() }
        }
        await supervisor.setEnabled(true)
        await supervisor.refreshNow()
        await fulfillment(of: [current], timeout: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let finalSnapshot = await supervisor.snapshot
        XCTAssertEqual(finalSnapshot.activeConversations.map(\.id), ["current"])
        await supervisor.stopForTermination()
    }

    func testConcurrentLifecycleCommandsRemainSerialized() async {
        let process = RecordingProcessHost()
        process.operationDelay = 0.03
        let client = ScriptedConversationClient(scripts: [[.hold], [.hold]])
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([
                LoopbackEndpoint(port: 50_010), LoopbackEndpoint(port: 50_011)
            ]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks()
        async let enable: Void = supervisor.setDesiredEnabled(true, revision: 1)
        async let restart: Void = supervisor.restart()
        async let disable: Void = supervisor.setDesiredEnabled(false, revision: 2)
        _ = await (enable, restart, disable)
        let finalPhase = await supervisor.snapshot.phase
        XCTAssertEqual(process.maxConcurrentOperations(), 1)
        XCTAssertEqual(finalPhase, .disabled)
    }

    func testLatestDesiredStateRevisionWinsWhenOlderTaskArrivesLater() async {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [[.hold]])
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_012)]),
            clientFactory: { _ in client }
        )
        await supervisor.installCallbacks()
        await supervisor.setDesiredEnabled(false, revision: 2)
        await supervisor.setDesiredEnabled(true, revision: 1)
        let finalPhase = await supervisor.snapshot.phase
        XCTAssertEqual(finalPhase, .disabled)
        XCTAssertTrue(process.recordedEndpoints().isEmpty)
    }

    func testUnexpectedExitSchedulesRestartWithNewEndpoint() async {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [[.hold], [.hold]])
        let supervisor = ServiceSupervisor(
            processHost: process,
            endpointAllocator: SequenceEndpointAllocator([
                LoopbackEndpoint(port: 50_020), LoopbackEndpoint(port: 50_021)
            ]),
            clientFactory: { _ in client },
            configuration: .init(
                readinessTimeout: 1,
                readinessPollInterval: 0.01,
                restartBackoff: .init(baseDelay: 0.01, maximumDelay: 0.01)
            )
        )
        await supervisor.installCallbacks()
        await supervisor.setEnabled(true)
        process.emitUnexpectedExit(status: 9, runtime: 1)
        let deadline = Date().addingTimeInterval(2)
        while process.recordedEndpoints().count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(process.recordedEndpoints(), [LoopbackEndpoint(port: 50_020), LoopbackEndpoint(port: 50_021)])
        await supervisor.stopForTermination()
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
