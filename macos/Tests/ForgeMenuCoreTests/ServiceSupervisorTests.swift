import Darwin
import Foundation
import XCTest
@testable import ForgeMenuCore

private final class RecordingProcessHost: ForgeProcessHosting, @unchecked Sendable {
    var onExit: (@Sendable (Int32, TimeInterval, UInt64) -> Void)?
    private let lock = NSLock()
    private var operations: [String] = []
    private var endpoints: [LoopbackEndpoint] = []
    private var executables: [URL] = []
    private var generations: [UInt64] = []
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    var operationDelay: TimeInterval = 0

    func start(runtime: InstalledRuntime, endpoint: LoopbackEndpoint, generation: UInt64) async throws {
        begin("start")
        defer { end() }
        if operationDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(operationDelay * 1_000_000_000)) }
        lock.withLock {
            endpoints.append(endpoint)
            executables.append(runtime.executableURL)
            generations.append(generation)
        }
    }

    func stop(gracePeriod: TimeInterval) async {
        begin("stop")
        defer { end() }
        if operationDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(operationDelay * 1_000_000_000)) }
    }

    func emitUnexpectedExit(status: Int32, runtime: TimeInterval, generation: UInt64? = nil) {
        let selected = generation ?? lock.withLock { generations.last ?? 0 }
        onExit?(status, runtime, selected)
    }
    func recordedOperations() -> [String] { lock.withLock { operations } }
    func recordedEndpoints() -> [LoopbackEndpoint] { lock.withLock { endpoints } }
    func recordedExecutables() -> [URL] { lock.withLock { executables } }
    func recordedGenerations() -> [UInt64] { lock.withLock { generations } }
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

private final class StubRuntimeInstaller: RuntimeInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: InstalledRuntime?
    private var results: [Result<InstalledRuntime, Error>]
    private var installCalls = 0

    init(current: InstalledRuntime? = StubRuntimeInstaller.fixture(), results: [Result<InstalledRuntime, Error>] = []) {
        self.current = current
        self.results = results
    }

    func installedCurrentRuntime() async throws -> InstalledRuntime? { lock.withLock { current } }

    func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        let result: Result<InstalledRuntime, Error> = lock.withLock {
            installCalls += 1
            return results.isEmpty ? .success(Self.fixture()) : results.removeFirst()
        }
        await progress(.resolving)
        await progress(.downloading(progress: 0.5))
        await progress(.verifying)
        await progress(.installing)
        let runtime = try result.get()
        lock.withLock { current = runtime }
        await progress(.ready)
        return runtime
    }

    func calls() -> Int { lock.withLock { installCalls } }

    static func fixture(path: String = "/runtime/forge3", version: String = "1.2.3") -> InstalledRuntime {
        InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: version)!,
            architecture: .native,
            executableURL: URL(fileURLWithPath: path)
        )
    }
}

private actor ControlledRuntimeInstaller: RuntimeInstalling {
    private let ignoresCancellation: Bool
    private var current: InstalledRuntime?
    private var nextCallID = 0
    private var callbacks: [Int: @Sendable (RuntimeInstallationPhase) async -> Void] = [:]
    private var pending: [Int: CheckedContinuation<InstalledRuntime, Error>] = [:]
    private var cancelledBeforePending: Set<Int> = []
    private var observedCancellations: Set<Int> = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(current: InstalledRuntime? = nil, ignoresCancellation: Bool = false) {
        self.current = current
        self.ignoresCancellation = ignoresCancellation
    }

    func installedCurrentRuntime() async throws -> InstalledRuntime? { current }

    func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        nextCallID += 1
        let callID = nextCallID
        callbacks[callID] = progress
        let ready = requestWaiters.filter { $0.0 <= nextCallID }
        requestWaiters.removeAll { $0.0 <= nextCallID }
        ready.forEach { $0.1.resume() }
        await progress(.resolving)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledBeforePending.remove(callID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[callID] = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation(callID) }
        }
    }

    func waitForRequests(_ count: Int) async {
        if nextCallID >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func emit(_ phase: RuntimeInstallationPhase, callID: Int = 1) async {
        guard let callback = callbacks[callID] else { return }
        await callback(phase)
    }

    func complete(_ result: Result<InstalledRuntime, Error>, callID: Int = 1) {
        guard let continuation = pending.removeValue(forKey: callID) else { return }
        if case .success(let runtime) = result { current = runtime }
        continuation.resume(with: result)
    }

    func setCurrent(_ runtime: InstalledRuntime?) { current = runtime }
    func calls() -> Int { nextCallID }
    func wasCancelled(_ callID: Int) -> Bool { observedCancellations.contains(callID) }

    private func observeCancellation(_ callID: Int) {
        observedCancellations.insert(callID)
        guard !ignoresCancellation else { return }
        cancel(callID)
    }

    private func cancel(_ callID: Int) {
        if let continuation = pending.removeValue(forKey: callID) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforePending.insert(callID)
        }
    }
}

private final class SequenceRuntimeInstaller: RuntimeInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [InstalledRuntime]

    init(_ runtimes: [InstalledRuntime]) { self.runtimes = runtimes }

    func installedCurrentRuntime() async throws -> InstalledRuntime? {
        lock.withLock {
            guard !runtimes.isEmpty else { return nil }
            return runtimes.count == 1 ? runtimes[0] : runtimes.removeFirst()
        }
    }

    func installLatest(
        progress: @escaping @Sendable (RuntimeInstallationPhase) async -> Void
    ) async throws -> InstalledRuntime {
        throw RuntimeInstallerError.network("unexpected install")
    }
}

private let cachedRuntimeInstaller = StubRuntimeInstaller()

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
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

private actor SupervisorRuntimeNetwork: RuntimeNetworkClient {
    private let responses: [URL: Data]
    private(set) var requestedURLs: [URL] = []

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        requestedURLs.append(request.url)
        guard let data = responses[request.url] else {
            throw RuntimeInstallerError.network("unexpected test URL")
        }
        await progress(0, Int64(data.count))
        await progress(Int64(data.count), Int64(data.count))
        return RuntimeDownload(data: data, responseURL: request.url)
    }

    func requestCount() -> Int { requestedURLs.count }
}

private final class FailOncePermissionCommitHook: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func failIfNeeded(path: String) throws {
        try lock.withLock {
            guard shouldFail else { return }
            shouldFail = false
            throw RuntimeFilesystemError.posix(
                EACCES,
                operation: "commit staged runtime",
                path: path
            )
        }
    }
}

private final class SupervisorRuntimeValidator: RuntimeExecutableValidating, @unchecked Sendable {
    func validate(executableURL: URL, expectedArchitecture: RuntimeArchitecture) throws {}
}

private struct SupervisorVersionInspector: RuntimeExecutableVersionIdentityInspecting {
    func inspectVersionIdentity(
        of executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableVersionIdentity {
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: expectedIdentity)
        return RuntimeExecutableVersionIdentity(version: expectedVersion)
    }
}

private struct SupervisorExecutionProbe: RuntimeExecutionProbing {
    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion
    ) async throws -> RuntimeExecutionProbeResult {
        .succeeded
    }
}

private struct SupervisorQuarantineManager: RuntimeQuarantineManaging {
    func hasQuarantine(
        at executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> Bool {
        false
    }

    func refreshExecutableRemovingQuarantine(
        from executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableIdentity {
        XCTFail("unexpected quarantine refresh")
        return expectedIdentity
    }
}

private actor SupervisorRuntimeArchive: RuntimeArchiveHandling {
    private let executable: Data

    init(executable: Data) {
        self.executable = executable
    }

    func inspect(
        archiveURL: URL,
        temporaryDirectory: URL,
        limits: RuntimeInstallerLimits
    ) async throws -> RuntimeArchiveInspection {
        let tarURL = temporaryDirectory.appendingPathComponent("supervisor-fixture.tar")
        let tar = supervisorTar(executable: executable)
        try tar.write(to: tarURL)
        return try SafeTarXZArchiveHandler.parseTar(tar, tarURL: tarURL, limits: limits)
    }

    nonisolated func extractExecutable(
        from inspection: RuntimeArchiveInspection,
        to destination: URL
    ) throws {
        try executable.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.path
        )
    }
}

private func supervisorTar(executable: Data) -> Data {
    var header = Data(repeating: 0, count: 512)
    writeSupervisorTar("package/forge3", to: &header, range: 0..<100)
    writeSupervisorTar("0000700\0", to: &header, range: 100..<108)
    writeSupervisorTar("0000000\0", to: &header, range: 108..<116)
    writeSupervisorTar("0000000\0", to: &header, range: 116..<124)
    writeSupervisorTar(String(format: "%011o\0", executable.count), to: &header, range: 124..<136)
    writeSupervisorTar("00000000000\0", to: &header, range: 136..<148)
    writeSupervisorTar("        ", to: &header, range: 148..<156)
    header[156] = Character("0").asciiValue!
    writeSupervisorTar("ustar\0", to: &header, range: 257..<263)
    writeSupervisorTar("00", to: &header, range: 263..<265)
    writeSupervisorTar(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), to: &header, range: 148..<156)

    var tar = header
    tar.append(executable)
    if executable.count % 512 != 0 {
        tar.append(Data(repeating: 0, count: 512 - executable.count % 512))
    }
    tar.append(Data(repeating: 0, count: 1_024))
    return tar
}

private func writeSupervisorTar(_ string: String, to data: inout Data, range: Range<Int>) {
    let bytes = Array(string.utf8.prefix(range.count))
    data.replaceSubrange(range.lowerBound..<(range.lowerBound + bytes.count), with: bytes)
}

final class ServiceSupervisorTests: XCTestCase {
    func testPublishedSnapshotRevisionsAreStrictlyMonotonic() async throws {
        let process = RecordingProcessHost()
        let revisions = Locked<[UInt64]>([])
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: cachedRuntimeInstaller,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_050)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.snapshot([]), .hold]]) },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            revisions.withValue { $0.append(snapshot.revision) }
            if snapshot.phase == .ready { ready.fulfill() }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        await supervisor.setEnabled(false)

        let values = revisions.value
        XCTAssertGreaterThan(values.count, 3)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy(<))
    }

    func testSilentInitialStreamTriggersIndependentReadinessWatchdog() async throws {
        let process = RecordingProcessHost()
        let failed = expectation(description: "silent stream failed readiness")
        failed.assertForOverFulfill = false
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: cachedRuntimeInstaller,
            endpointAllocator: SequenceEndpointAllocator([
                LoopbackEndpoint(port: 50_051), LoopbackEndpoint(port: 50_052)
            ]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) },
            configuration: .init(
                readinessTimeout: 0.05,
                readinessPollInterval: 0.01,
                restartBackoff: .init(baseDelay: 0.5, maximumDelay: 0.5)
            )
        )
        await supervisor.installCallbacks { snapshot in
            if case .failed(let message) = snapshot.phase,
               message.contains("Timed out waiting") {
                failed.fulfill()
            }
        }
        await supervisor.setEnabled(true)
        await fulfillment(of: [failed], timeout: 1)
        let didStop = await waitUntil {
            process.recordedOperations().contains("stop")
        }
        XCTAssertTrue(didStop)
        await supervisor.stopForTermination()
    }

    func testDownloadProgressSnapshotsAreCoalescedAndLatestValueWins() async throws {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/coalesced-progress/forge3")
        let installer = ControlledRuntimeInstaller()
        let phases = Locked<[ServicePhase]>([])
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_053)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) },
            configuration: .init(installationProgressPublishInterval: 0.05)
        )
        await supervisor.installCallbacks { snapshot in
            phases.withValue { $0.append(snapshot.phase) }
        }
        let start = Task { await supervisor.setEnabled(true) }
        await installer.waitForRequests(1)
        for value in stride(from: 0.01, through: 0.99, by: 0.01) {
            await installer.emit(.downloading(progress: value))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        await installer.complete(.success(runtime))
        await start.value

        let downloads = phases.value.compactMap { phase -> Double? in
            guard case .installing(.downloading(let progress)) = phase else { return nil }
            return progress
        }
        XCTAssertLessThan(downloads.count, 20)
        XCTAssertEqual(downloads.last ?? 0, 0.99, accuracy: 0.0001)
        await supervisor.stopForTermination()
    }

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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_005)]),
            clientFactory: { _ in client },
            configuration: .init(readinessTimeout: 1, readinessPollInterval: 0.01)
        )
        await supervisor.installCallbacks { snapshot in
            if snapshot.activeConversations.first?.id == "current" { current.fulfill() }
        }
        await supervisor.setEnabled(true)
        let firstSubscriptionDeadline = Date().addingTimeInterval(1)
        while await client.calls() < 1, Date() < firstSubscriptionDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
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
            runtimeInstaller: cachedRuntimeInstaller,
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
            runtimeInstaller: cachedRuntimeInstaller,
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

    func testDisabledPreferenceDoesNotConsultInstallerUntilServiceIsNeeded() async {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/needed/forge3")
        let installer = ControlledRuntimeInstaller()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_039)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        await supervisor.setDesiredEnabled(false, revision: 1)
        let installCallsBeforeNeed = await installer.calls()
        XCTAssertEqual(installCallsBeforeNeed, 0)
        XCTAssertTrue(process.recordedExecutables().isEmpty)

        let start = Task { await supervisor.setDesiredEnabled(true, revision: 2) }
        await installer.waitForRequests(1)
        await installer.complete(.success(runtime))
        await start.value
        let didLaunch = await waitUntil { process.recordedExecutables() == [runtime.executableURL] }
        XCTAssertTrue(didLaunch)
        XCTAssertEqual(process.recordedExecutables(), [runtime.executableURL])
        await supervisor.stopForTermination()
    }

    func testFirstActualNeedInstallsThenAutoLaunchesSelectedRuntime() async throws {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/installed/forge3")
        let installer = ControlledRuntimeInstaller()
        let phases = Locked<[ServicePhase]>([])
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_040)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks { snapshot in
            phases.withValue { $0.append(snapshot.phase) }
        }

        let start = Task { await supervisor.setDesiredEnabled(true, revision: 1) }
        await installer.waitForRequests(1)
        await installer.emit(.downloading(progress: 1.7))
        await installer.emit(.verifying)
        await installer.emit(.installing)
        await installer.emit(.ready)
        await installer.complete(.success(runtime))
        await start.value
        let didLaunch = await waitUntil { process.recordedExecutables() == [runtime.executableURL] }
        XCTAssertTrue(didLaunch)

        let installCalls = await installer.calls()
        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(process.recordedExecutables(), [runtime.executableURL])
        XCTAssertEqual(process.recordedEndpoints(), [LoopbackEndpoint(port: 50_040)])
        XCTAssertTrue(phases.value.contains(.installing(.downloading(progress: 1))))
        XCTAssertTrue(phases.value.contains(.installing(.verifying)))
        XCTAssertTrue(phases.value.contains(.installing(.installing)))
        await supervisor.stopForTermination()
    }

    func testFailedFirstInstallRequiresRetryAndLaunchesAfterSuccess() async {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/retry/forge3")
        let installer = StubRuntimeInstaller(
            current: nil,
            results: [
                .failure(RuntimeInstallerError.network("offline")),
                .success(runtime)
            ]
        )
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_041)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        await supervisor.setDesiredEnabled(true, revision: 1)
        let didFail = await waitUntil {
            if case .installationFailed = await supervisor.snapshot.phase { return true }
            return false
        }
        XCTAssertTrue(didFail)
        let failedPhase = await supervisor.snapshot.phase
        XCTAssertEqual(failedPhase, .installationFailed(.download))
        XCTAssertTrue(process.recordedEndpoints().isEmpty)

        await supervisor.retryInstallation()
        let didLaunch = await waitUntil { process.recordedExecutables() == [runtime.executableURL] }
        XCTAssertTrue(didLaunch)
        XCTAssertEqual(installer.calls(), 2)
        XCTAssertEqual(process.recordedExecutables(), [runtime.executableURL])
        await supervisor.stopForTermination()
    }

    func testPermissionFailureCleansStagingAndRetryAutoLaunchesInstalledRuntime() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-supervisor-permission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            makeSupervisorTreeOwnerWritable(base)
            try? FileManager.default.removeItem(at: base)
        }

        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let root = base.appendingPathComponent("runtime", isDirectory: true)
        let archiveData = Data("permission-retry-archive".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let network = SupervisorRuntimeNetwork(responses: [
            RuntimeReleaseURLs.latestManifest: Data("{\"version\":\"1.2.3\"}".utf8),
            archiveURL: archiveData,
            checksumURL: Data(
                "\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8
            )
        ])
        let validator = SupervisorRuntimeValidator()
        let permissionFault = FailOncePermissionCommitHook()
        let store = RuntimeStore(
            rootURL: root,
            validator: validator,
            commitHooks: .init(beforeActivationRename: {
                try permissionFault.failIfNeeded(path: root.appendingPathComponent("current").path)
            })
        )
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: store,
                archive: SupervisorRuntimeArchive(executable: Data("forge3-fixture".utf8)),
                validator: validator,
                versionInspector: SupervisorVersionInspector(),
                executionProbe: SupervisorExecutionProbe(),
                quarantineManager: SupervisorQuarantineManager()
            )
        )
        let process = RecordingProcessHost()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_054)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        await supervisor.setDesiredEnabled(true, revision: 1)
        let didFail = await waitUntil {
            await supervisor.snapshot.phase == .installationFailed(.filesystem(.permissionDenied))
        }
        XCTAssertTrue(didFail)
        let failedSnapshot = await supervisor.snapshot
        XCTAssertEqual(
            failedSnapshot.phase,
            .installationFailed(.filesystem(.permissionDenied)),
            "the POSIX permission identity must survive installer and supervisor boundaries"
        )
        let failedPresentation = PopoverPresentation.make(snapshot: failedSnapshot)
        XCTAssertEqual(
            failedPresentation.actionableError,
            "Runtime folder access was denied. Check permissions and retry."
        )
        XCTAssertTrue(failedPresentation.retryInstallationEnabled)
        XCTAssertTrue(process.recordedExecutables().isEmpty)
        let failedRequestCount = await network.requestCount()
        XCTAssertEqual(failedRequestCount, 3)

        let temporaryRoot = root.appendingPathComponent("tmp", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("versions/1.2.3/arm64", isDirectory: true).path
            ),
            "a failed real-store commit must roll back the moved staging directory"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))

        await supervisor.retryInstallation()
        let expectedExecutable = root.appendingPathComponent("versions/1.2.3/arm64/forge3")
        let didLaunch = await waitUntil {
            process.recordedExecutables() == [expectedExecutable]
        }
        XCTAssertTrue(didLaunch)
        XCTAssertEqual(process.recordedExecutables(), [expectedExecutable])
        let retriedRequestCount = await network.requestCount()
        XCTAssertEqual(retriedRequestCount, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
        XCTAssertEqual(try store.current(architecture: .arm64)?.executableURL, expectedExecutable)
        await supervisor.stopForTermination()
    }

    func testConcurrentEnabledRequestsCoalesceIntoOneInstallAndStart() async {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/coalesced/forge3")
        let installer = ControlledRuntimeInstaller()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_042)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        let first = Task { await supervisor.setDesiredEnabled(true, revision: 1) }
        await installer.waitForRequests(1)
        let second = Task { await supervisor.setDesiredEnabled(true, revision: 2) }
        await installer.complete(.success(runtime))
        await first.value
        await second.value
        let didLaunch = await waitUntil { process.recordedExecutables() == [runtime.executableURL] }
        XCTAssertTrue(didLaunch)

        let installCalls = await installer.calls()
        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(process.recordedExecutables(), [runtime.executableURL])
        await supervisor.stopForTermination()
    }

    func testDisableRestartAndQuitReturnPromptlyWhenInstallerIgnoresCancellation() async {
        for action in ["disable", "restart", "quit"] {
            let process = RecordingProcessHost()
            let installer = ControlledRuntimeInstaller(ignoresCancellation: true)
            let supervisor = ServiceSupervisor(
                processHost: process,
                runtimeInstaller: installer,
                endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_049)]),
                clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
            )
            await supervisor.installCallbacks()
            await supervisor.setDesiredEnabled(true, revision: 1)
            await installer.waitForRequests(1)

            let startedAt = Date()
            switch action {
            case "disable": await supervisor.setDesiredEnabled(false, revision: 2)
            case "restart": await supervisor.restart()
            default: await supervisor.stopForTermination()
            }
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25, action)
            let phase = await supervisor.snapshot.phase
            if action == "disable" { XCTAssertEqual(phase, .disabled) }
            if action == "quit" { XCTAssertEqual(phase, .stopped) }
            XCTAssertTrue(process.recordedExecutables().isEmpty)

            if action == "restart" {
                await installer.waitForRequests(2)
                await supervisor.stopForTermination()
                await installer.complete(.success(StubRuntimeInstaller.fixture(path: "/late-old/forge3")), callID: 1)
                await installer.complete(.success(StubRuntimeInstaller.fixture(path: "/late-new/forge3")), callID: 2)
            } else {
                await installer.complete(.success(StubRuntimeInstaller.fixture(path: "/late/forge3")))
            }
            await Task.yield()
            XCTAssertTrue(process.recordedExecutables().isEmpty)
        }
    }

    func testDisableDuringInstallCancelsAndNeverStartsProcess() async {
        let process = RecordingProcessHost()
        let installer = ControlledRuntimeInstaller()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_043)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        let start = Task { await supervisor.setDesiredEnabled(true, revision: 1) }
        await installer.waitForRequests(1)
        let disable = Task { await supervisor.setDesiredEnabled(false, revision: 2) }
        await start.value
        await disable.value

        let disabledPhase = await supervisor.snapshot.phase
        XCTAssertEqual(disabledPhase, .disabled)
        XCTAssertTrue(process.recordedExecutables().isEmpty)
        await installer.emit(.ready)
        let phaseAfterLateProgress = await supervisor.snapshot.phase
        XCTAssertEqual(phaseAfterLateProgress, .disabled)
    }

    func testRestartDuringInstallCancelsOldAttemptAndStartsOneReplacement() async {
        let process = RecordingProcessHost()
        let runtime = StubRuntimeInstaller.fixture(path: "/restart-install/forge3")
        let installer = ControlledRuntimeInstaller()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_048)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        let start = Task { await supervisor.setDesiredEnabled(true, revision: 1) }
        await installer.waitForRequests(1)
        let restart = Task { await supervisor.restart() }
        await installer.waitForRequests(2)
        await installer.complete(.success(runtime), callID: 2)
        await start.value
        await restart.value
        let didLaunch = await waitUntil { process.recordedExecutables() == [runtime.executableURL] }
        XCTAssertTrue(didLaunch)

        let installCalls = await installer.calls()
        XCTAssertEqual(installCalls, 2)
        XCTAssertEqual(process.recordedExecutables(), [runtime.executableURL])
        await supervisor.stopForTermination()
    }

    func testQuitDuringInstallCancelsAndStopsWithoutLaunching() async {
        let process = RecordingProcessHost()
        let installer = ControlledRuntimeInstaller()
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_044)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        let start = Task { await supervisor.setEnabled(true) }
        await installer.waitForRequests(1)
        let quit = Task { await supervisor.stopForTermination() }
        await start.value
        await quit.value

        let stoppedPhase = await supervisor.snapshot.phase
        XCTAssertEqual(stoppedPhase, .stopped)
        XCTAssertTrue(process.recordedExecutables().isEmpty)
    }

    func testLateInstallerCallbacksAndCompletionCannotMutateOrStartSupersededLifecycle() async {
        let process = RecordingProcessHost()
        let oldRuntime = StubRuntimeInstaller.fixture(path: "/old/forge3")
        let newRuntime = StubRuntimeInstaller.fixture(path: "/new/forge3", version: "1.2.4")
        let installer = ControlledRuntimeInstaller(ignoresCancellation: true)
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([LoopbackEndpoint(port: 50_045)]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) }
        )
        await supervisor.installCallbacks()

        let start = Task { await supervisor.setDesiredEnabled(true, revision: 1) }
        await installer.waitForRequests(1)
        let disable = Task { await supervisor.setDesiredEnabled(false, revision: 2) }
        while !(await installer.wasCancelled(1)) {
            await Task.yield()
        }
        await disable.value
        let phaseBeforeLateCompletion = await supervisor.snapshot.phase
        XCTAssertEqual(phaseBeforeLateCompletion, .disabled)
        await installer.emit(.ready)
        let phaseAfterLateProgress = await supervisor.snapshot.phase
        XCTAssertEqual(phaseAfterLateProgress, .disabled)
        await installer.complete(.success(oldRuntime))
        await start.value
        XCTAssertTrue(process.recordedExecutables().isEmpty)

        await installer.setCurrent(newRuntime)
        await supervisor.setDesiredEnabled(true, revision: 3)
        let didLaunchNewRuntime = await waitUntil { process.recordedExecutables() == [newRuntime.executableURL] }
        XCTAssertTrue(didLaunchNewRuntime)
        XCTAssertEqual(process.recordedExecutables(), [newRuntime.executableURL])
        let currentPhase = await supervisor.snapshot.phase
        await installer.emit(.downloading(progress: 0.9), callID: 1)
        let phaseAfterLateCallback = await supervisor.snapshot.phase
        XCTAssertEqual(phaseAfterLateCallback, currentPhase)
        await supervisor.stopForTermination()
    }

    func testRestartSelectsRuntimeForNewLifecycleAndIgnoresOldExitCallback() async {
        let process = RecordingProcessHost()
        let firstRuntime = StubRuntimeInstaller.fixture(path: "/runtime-one/forge3")
        let secondRuntime = StubRuntimeInstaller.fixture(path: "/runtime-two/forge3", version: "1.2.4")
        let installer = SequenceRuntimeInstaller([firstRuntime, secondRuntime])
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: installer,
            endpointAllocator: SequenceEndpointAllocator([
                LoopbackEndpoint(port: 50_046), LoopbackEndpoint(port: 50_047)
            ]),
            clientFactory: { _ in ScriptedConversationClient(scripts: [[.hold]]) },
            configuration: .init(restartBackoff: .init(baseDelay: 0.01, maximumDelay: 0.01))
        )
        await supervisor.installCallbacks()

        await supervisor.setEnabled(true)
        let didStartFirst = await waitUntil { process.recordedGenerations().count == 1 }
        XCTAssertTrue(didStartFirst)
        let firstGeneration = process.recordedGenerations()[0]
        await supervisor.restart()
        let didRestart = await waitUntil { process.recordedExecutables().count == 2 }
        XCTAssertTrue(didRestart)
        XCTAssertEqual(process.recordedExecutables(), [firstRuntime.executableURL, secondRuntime.executableURL])
        XCTAssertNotEqual(process.recordedGenerations()[0], process.recordedGenerations()[1])

        process.emitUnexpectedExit(status: 9, runtime: 0, generation: firstGeneration)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(process.recordedEndpoints().count, 2)
        let phaseAfterOldExit = await supervisor.snapshot.phase
        XCTAssertNotEqual(phaseAfterOldExit, .restarting(attempt: 1, delay: 0.01))
        await supervisor.stopForTermination()
    }

    func testUnexpectedExitSchedulesRestartWithNewEndpoint() async {
        let process = RecordingProcessHost()
        let client = ScriptedConversationClient(scripts: [[.hold], [.hold]])
        let supervisor = ServiceSupervisor(
            processHost: process,
            runtimeInstaller: cachedRuntimeInstaller,
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
        let didStart = await waitUntil { process.recordedGenerations().count == 1 }
        XCTAssertTrue(didStart)
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

private func makeSupervisorTreeOwnerWritable(_ url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    if (info.st_mode & S_IFMT) == S_IFDIR {
        _ = chmod(url.path, 0o700)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for child in children { makeSupervisorTreeOwnerWritable(child) }
        }
    } else if (info.st_mode & S_IFMT) == S_IFREG {
        _ = chmod(url.path, 0o600)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
