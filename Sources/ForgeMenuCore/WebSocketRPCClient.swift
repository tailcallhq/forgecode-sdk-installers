import Foundation

public protocol ForgeRPCClientProtocol: Sendable {
    func activeRootConversationStream() async -> AsyncThrowingStream<[ActiveConversation], Error>
    func activeRootConversations() async throws -> [ActiveConversation]
    func sdkVersion() async throws -> String
}

public actor WebSocketRPCClient: ForgeRPCClientProtocol {
    private let endpoint: URL
    private let timeout: TimeInterval
    private let session: URLSession
    private var nextID: UInt64 = 0

    public init(
        endpoint: URL,
        timeout: TimeInterval = 8,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = session
    }

    public func activeRootConversationStream() -> AsyncThrowingStream<[ActiveConversation], Error> {
        let request = ForgeRPCParser.makeConversationListStreamRequest(
            id: makeID(prefix: "conversation-list-stream")
        )
        let endpoint = self.endpoint
        let timeout = self.timeout
        let session = self.session

        return AsyncThrowingStream { continuation in
            let producer = Task {
                let socket = session.webSocketTask(with: endpoint)
                socket.resume()
                defer { socket.cancel(with: .normalClosure, reason: nil) }
                do {
                    let encoded = try JSONEncoder().encode(request)
                    try await Self.withTimeout(
                        seconds: timeout,
                        operation: "sending the active-conversation subscription",
                        onCancel: { socket.cancel(with: .goingAway, reason: nil) }
                    ) {
                        try await socket.send(.data(encoded))
                    }

                    let pointerData = try await Self.receiveData(
                        from: socket,
                        timeout: timeout,
                        operation: "waiting for the active-conversation stream pointer"
                    )
                    _ = try ForgeRPCParser.parseStreamPointer(
                        from: pointerData,
                        expectedID: request.id,
                        expectedMethod: request.method
                    )

                    var previousSequence: UInt64?
                    while !Task.isCancelled {
                        let data = try await Self.receiveData(
                            from: socket,
                            timeout: 86_400,
                            operation: "waiting for an active-conversation stream frame"
                        )
                        guard let frame = try ForgeRPCParser.parseStreamFrame(
                            from: data,
                            expectedRequestID: request.id,
                            expectedMethod: request.method
                        ) else { continue }
                        try ForgeRPCParser.validateNextSequence(frame.sequence, after: previousSequence)
                        previousSequence = frame.sequence
                        switch frame {
                        case .snapshot(_, let conversations):
                            continuation.yield(conversations)
                        case .error(_, let code, let message):
                            throw ForgeCoreError.rpc(code: code, message: message)
                        case .complete:
                            throw ForgeCoreError.streamInterrupted("the server completed the subscription")
                        }
                    }
                    throw CancellationError()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    public func activeRootConversations() async throws -> [ActiveConversation] {
        let request = ForgeRPCParser.makeConversationListRequest(
            id: makeID(prefix: "conversation-list")
        )
        let data = try await performOneShot(request)
        return try ForgeRPCParser.parseConversationList(from: data, expectedID: request.id)
    }

    public func sdkVersion() async throws -> String {
        let request = ForgeRPCParser.makeDiscoverRequest(id: makeID(prefix: "discover"))
        let data = try await performOneShot(request)
        return try ForgeRPCParser.parseSDKVersion(from: data, expectedID: request.id)
    }

    private func makeID(prefix: String) -> String {
        nextID += 1
        return "forge-menubar-\(prefix)-\(nextID)"
    }

    private func performOneShot(_ request: RPCRequest) async throws -> Data {
        let task = session.webSocketTask(with: endpoint)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        do {
            let encoded = try JSONEncoder().encode(request)
            try await Self.withTimeout(
                seconds: timeout,
                operation: "sending a Forge RPC request",
                onCancel: { task.cancel(with: .goingAway, reason: nil) }
            ) {
                try await task.send(.data(encoded))
            }
            while true {
                let data = try await Self.receiveData(
                    from: task,
                    timeout: timeout,
                    operation: "waiting for a Forge RPC response"
                )
                if (try? ForgeRPCParser.parseResponseID(from: data)) == request.id { return data }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ForgeCoreError {
            throw error
        } catch {
            throw ForgeCoreError.connection(error.localizedDescription)
        }
    }

    private static func receiveData(
        from task: URLSessionWebSocketTask,
        timeout: TimeInterval,
        operation: String
    ) async throws -> Data {
        try await withTimeout(
            seconds: timeout,
            operation: operation,
            onCancel: { task.cancel(with: .goingAway, reason: nil) }
        ) {
            while true {
                switch try await task.receive() {
                case .data(let data): return data
                case .string(let string):
                    if let data = string.data(using: .utf8) { return data }
                @unknown default: continue
                }
            }
        }
    }

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: String,
        onCancel: @escaping @Sendable () -> Void = {},
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let holder = TimeoutRaceHolder<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let race = TimeoutRace(continuation: continuation, onCancel: onCancel)
                holder.install(race)
                guard !Task.isCancelled else {
                    race.cancelFromParent()
                    return
                }
                let operationTask = Task {
                    do { race.resolve(.success(try await body())) }
                    catch { race.resolve(.failure(error)) }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    } catch { return }
                    race.cancelUnderlyingOperation()
                    race.resolve(.failure(ForgeCoreError.timeout(operation)))
                }
                race.install(operationTask: operationTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            holder.cancelFromParent()
        }
    }
}

private final class TimeoutRaceHolder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var race: TimeoutRace<Value>?
    private var parentCancelled = false

    func install(_ race: TimeoutRace<Value>) {
        lock.lock()
        self.race = race
        let cancelled = parentCancelled
        lock.unlock()
        if cancelled { race.cancelFromParent() }
    }

    func cancelFromParent() {
        lock.lock()
        parentCancelled = true
        let race = self.race
        lock.unlock()
        race?.cancelFromParent()
    }
}

private final class TimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let onCancel: @Sendable () -> Void
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolved = false
    private var underlyingOperationCancelled = false

    init(
        continuation: CheckedContinuation<Value, Error>,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onCancel = onCancel
    }

    func install(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func cancelFromParent() {
        cancelUnderlyingOperation()
        resolve(.failure(CancellationError()))
    }

    func cancelUnderlyingOperation() {
        lock.lock()
        guard !underlyingOperationCancelled else {
            lock.unlock()
            return
        }
        underlyingOperationCancelled = true
        lock.unlock()
        onCancel()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}
