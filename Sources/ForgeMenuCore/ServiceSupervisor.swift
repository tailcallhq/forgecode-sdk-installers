import Foundation

public actor ServiceSupervisor {
    public struct Configuration: Sendable {
        public let readinessTimeout: TimeInterval
        public let readinessPollInterval: TimeInterval
        public let terminationGracePeriod: TimeInterval
        public let restartBackoff: RestartBackoff
        public let streamReconnectBackoff: RestartBackoff
        /// How often titles are reconciled while a run is in flight. The SDK
        /// only re-emits the conversation list when a run starts or ends, so a
        /// title generated mid-run needs a light poll to appear on its own.
        public let titleRefreshInterval: TimeInterval

        public init(
            readinessTimeout: TimeInterval = 30,
            readinessPollInterval: TimeInterval = 0.5,
            terminationGracePeriod: TimeInterval = 3,
            restartBackoff: RestartBackoff = RestartBackoff(),
            streamReconnectBackoff: RestartBackoff = RestartBackoff(
                baseDelay: 1,
                maximumDelay: 30,
                stableRunThreshold: 60
            ),
            titleRefreshInterval: TimeInterval = 3
        ) {
            self.readinessTimeout = readinessTimeout
            self.readinessPollInterval = readinessPollInterval
            self.terminationGracePeriod = terminationGracePeriod
            self.restartBackoff = restartBackoff
            self.streamReconnectBackoff = streamReconnectBackoff
            self.titleRefreshInterval = titleRefreshInterval
        }
    }

    public typealias ClientFactory = @Sendable (LoopbackEndpoint) -> ForgeRPCClientProtocol
    public typealias SnapshotHandler = @Sendable (ServiceSnapshot) -> Void

    public private(set) var snapshot = ServiceSnapshot()

    private let processHost: ForgeProcessHosting
    private let endpointAllocator: LoopbackEndpointAllocating
    private let clientFactory: ClientFactory
    private let logger: AppLogger
    private let configuration: Configuration
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private var snapshotHandler: SnapshotHandler?
    private var client: ForgeRPCClientProtocol?
    private var desiredEnabled = false
    private var latestDesiredStateRevision: UInt64 = 0
    private var terminating = false
    private var restartAttempt = 0
    private var generation: UInt64 = 0
    private var subscriptionGeneration: UInt64 = 0
    private var subscriptionTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var titleRefreshTask: Task<Void, Never>?
    private var commandTail: Task<Void, Never>?

    public init(
        processHost: ForgeProcessHosting,
        endpointAllocator: LoopbackEndpointAllocating = SystemLoopbackEndpointAllocator(),
        clientFactory: @escaping ClientFactory,
        logger: AppLogger = .shared,
        configuration: Configuration = Configuration(),
        appVersion: String? = AppVersion.current,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await ServiceSupervisor.systemSleep(seconds)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processHost = processHost
        self.endpointAllocator = endpointAllocator
        self.clientFactory = clientFactory
        self.logger = logger
        self.configuration = configuration
        self.sleep = sleep
        self.now = now
        // Constant for the lifetime of the process, so it is never cleared
        // alongside the service-derived identity.
        snapshot.appVersion = appVersion
    }

    public func installCallbacks(snapshotHandler: SnapshotHandler? = nil) {
        self.snapshotHandler = snapshotHandler
        processHost.onExit = { [weak self] status, runtime in
            Task { await self?.processExited(status: status, runtime: runtime) }
        }
        snapshotHandler?(snapshot)
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !terminating else { return }
        latestDesiredStateRevision &+= 1
        await applyDesiredEnabled(enabled, revision: latestDesiredStateRevision)
    }

    public func setDesiredEnabled(_ enabled: Bool, revision: UInt64) async {
        guard !terminating, revision > latestDesiredStateRevision else { return }
        latestDesiredStateRevision = revision
        await applyDesiredEnabled(enabled, revision: revision)
    }

    private func applyDesiredEnabled(_ enabled: Bool, revision: UInt64) async {
        await enqueueLifecycle { supervisor in
            guard revision == supervisor.latestDesiredStateRevision else { return }
            supervisor.desiredEnabled = enabled
            if enabled {
                await supervisor.startLocked()
            } else {
                await supervisor.stopLocked(finalPhase: .disabled)
            }
        }
    }

    public func restart() async {
        await enqueueLifecycle { supervisor in
            guard supervisor.desiredEnabled, !supervisor.terminating else { return }
            await supervisor.stopLocked(finalPhase: .stopped)
            await supervisor.startLocked()
        }
    }

    public func stopForTermination() async {
        terminating = true
        latestDesiredStateRevision &+= 1
        let terminationRevision = latestDesiredStateRevision
        desiredEnabled = false
        await enqueueLifecycle { supervisor in
            guard terminationRevision == supervisor.latestDesiredStateRevision else { return }
            supervisor.desiredEnabled = false
            await supervisor.stopLocked(finalPhase: .stopped)
        }
    }

    public func refreshNow() {
        guard desiredEnabled, !terminating, let client else { return }
        subscriptionGeneration &+= 1
        subscriptionTask?.cancel()
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
        clearConversationData()
        snapshot.conversationStreamState = .connecting
        publishSnapshot()
        startSubscription(
            client: client,
            processGeneration: generation,
            subscriptionGeneration: subscriptionGeneration,
            initialReadiness: !isReady(snapshot.phase)
        )
    }

    private func enqueueLifecycle(
        _ operation: @escaping @Sendable (isolated ServiceSupervisor) async -> Void
    ) async {
        let predecessor = commandTail
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await operation(self)
        }
        commandTail = task
        await task.value
    }

    private func startLocked() async {
        guard desiredEnabled, !terminating else { return }
        cancelBackgroundTasks()
        generation &+= 1
        subscriptionGeneration &+= 1
        clearServiceIdentity()
        let processGeneration = generation
        let currentSubscriptionGeneration = subscriptionGeneration

        do {
            let endpoint = try endpointAllocator.allocate()
            let newClient = clientFactory(endpoint)
            client = newClient
            snapshot.endpoint = endpoint
            snapshot.phase = .starting
            clearConversationData()
            snapshot.conversationStreamState = .connecting
            publishSnapshot()
            try await processHost.start(endpoint: endpoint)
            startSubscription(
                client: newClient,
                processGeneration: processGeneration,
                subscriptionGeneration: currentSubscriptionGeneration,
                initialReadiness: true
            )
        } catch {
            client = nil
            snapshot.endpoint = nil
            handleStartFailure(error)
        }
    }

    private func stopLocked(finalPhase: ServicePhase) async {
        cancelBackgroundTasks()
        generation &+= 1
        subscriptionGeneration &+= 1
        await processHost.stop(gracePeriod: configuration.terminationGracePeriod)
        client = nil
        snapshot.endpoint = nil
        snapshot.phase = finalPhase
        clearConversationData()
        clearServiceIdentity()
        publishSnapshot()
    }

    private func startSubscription(
        client: ForgeRPCClientProtocol,
        processGeneration: UInt64,
        subscriptionGeneration: UInt64,
        initialReadiness: Bool
    ) {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSubscriptionLoop(
                client: client,
                processGeneration: processGeneration,
                subscriptionGeneration: subscriptionGeneration,
                initialReadiness: initialReadiness
            )
        }
    }

    private func runSubscriptionLoop(
        client: ForgeRPCClientProtocol,
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64,
        initialReadiness: Bool
    ) async {
        let readinessDeadline = now().addingTimeInterval(configuration.readinessTimeout)
        var reconnectAttempt = 0
        var hasReceivedSnapshot = false

        while subscriptionIsCurrent(
            processGeneration: expectedProcessGeneration,
            subscriptionGeneration: expectedSubscriptionGeneration
        ) {
            do {
                let stream = await client.activeRootConversationStream()
                for try await conversations in stream {
                    guard subscriptionIsCurrent(
                        processGeneration: expectedProcessGeneration,
                        subscriptionGeneration: expectedSubscriptionGeneration
                    ) else { return }
                    hasReceivedSnapshot = true
                    reconnectAttempt = 0
                    snapshot.activeConversations = conversations
                    snapshot.conversationStreamState = .subscribed
                    snapshot.streamError = nil
                    snapshot.phase = .ready
                    restartAttempt = 0
                    publishSnapshot()
                    scheduleTitleRefresh(
                        client: client,
                        processGeneration: expectedProcessGeneration,
                        subscriptionGeneration: expectedSubscriptionGeneration
                    )
                    if snapshot.sdkVersion == nil {
                        await loadSDKVersion(
                            client: client,
                            processGeneration: expectedProcessGeneration
                        )
                    }
                }
                throw ForgeCoreError.streamInterrupted("the connection closed")
            } catch is CancellationError {
                return
            } catch {
                guard subscriptionIsCurrent(
                    processGeneration: expectedProcessGeneration,
                    subscriptionGeneration: expectedSubscriptionGeneration
                ) else { return }

                let message = error.localizedDescription
                clearConversationData()
                snapshot.streamError = message

                if initialReadiness && !hasReceivedSnapshot && now() >= readinessDeadline {
                    snapshot.phase = .failed(message)
                    snapshot.conversationStreamState = .disconnected
                    publishSnapshot()
                    logger.error("ForgeCode active-conversation subscription failed readiness: \(message)")
                    await restartAfterReadinessFailure(processGeneration: expectedProcessGeneration)
                    return
                }

                reconnectAttempt += 1
                let delay: TimeInterval
                if initialReadiness && !hasReceivedSnapshot {
                    delay = configuration.readinessPollInterval
                    snapshot.conversationStreamState = .connecting
                } else {
                    delay = configuration.streamReconnectBackoff.delay(forAttempt: reconnectAttempt)
                    snapshot.conversationStreamState = .reconnecting(attempt: reconnectAttempt, delay: delay)
                }
                publishSnapshot()
                logger.warning("Active-conversation stream interrupted; reconnecting in \(String(format: "%.1f", delay)) seconds: \(message)")
                do { try await sleep(delay) } catch { return }
                guard subscriptionIsCurrent(
                    processGeneration: expectedProcessGeneration,
                    subscriptionGeneration: expectedSubscriptionGeneration
                ) else { return }
                snapshot.conversationStreamState = .connecting
                publishSnapshot()
            }
        }
    }

    /// The SDK re-emits the conversation list only when a run starts or ends,
    /// so a title generated during a run would otherwise stay "Untitled" until
    /// the run finished. While rows are present, re-read the list on a light
    /// interval and merge titles only; membership stays owned by the stream.
    private func scheduleTitleRefresh(
        client: ForgeRPCClientProtocol,
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) {
        titleRefreshTask?.cancel()
        guard configuration.titleRefreshInterval > 0,
              snapshot.activeConversations.contains(where: { $0.hasPlaceholderTitle })
        else {
            titleRefreshTask = nil
            return
        }
        titleRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.runTitleRefreshLoop(
                client: client,
                processGeneration: expectedProcessGeneration,
                subscriptionGeneration: expectedSubscriptionGeneration
            )
        }
    }

    private func runTitleRefreshLoop(
        client: ForgeRPCClientProtocol,
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) async {
        while subscriptionIsCurrent(
            processGeneration: expectedProcessGeneration,
            subscriptionGeneration: expectedSubscriptionGeneration
        ) {
            guard snapshot.activeConversations.contains(where: { $0.hasPlaceholderTitle }) else { return }
            do { try await sleep(configuration.titleRefreshInterval) } catch { return }
            guard subscriptionIsCurrent(
                processGeneration: expectedProcessGeneration,
                subscriptionGeneration: expectedSubscriptionGeneration
            ) else { return }

            let refreshed: [ActiveConversation]
            do {
                refreshed = try await client.activeRootConversations()
            } catch is CancellationError {
                return
            } catch {
                continue
            }
            guard subscriptionIsCurrent(
                processGeneration: expectedProcessGeneration,
                subscriptionGeneration: expectedSubscriptionGeneration
            ) else { return }
            applyRefreshedTitles(refreshed)
        }
    }

    /// Merges titles by conversation id. Rows are neither added nor removed:
    /// the stream remains the sole authority on which conversations run.
    private func applyRefreshedTitles(_ refreshed: [ActiveConversation]) {
        guard !refreshed.isEmpty else { return }
        var titles: [String: String] = [:]
        for conversation in refreshed { titles[conversation.id] = conversation.title }

        var changed = false
        let merged = snapshot.activeConversations.map { current -> ActiveConversation in
            guard current.hasPlaceholderTitle,
                  let title = titles[current.id],
                  title != current.title,
                  !ActiveConversation.isPlaceholderTitle(title)
            else { return current }
            changed = true
            return ActiveConversation(id: current.id, title: title)
        }
        guard changed else { return }
        snapshot.activeConversations = merged
        publishSnapshot()
    }

    /// Reads the SDK version from `rpc.discover` once per running helper. A
    /// failure here is diagnostic only and never affects service state.
    private func loadSDKVersion(
        client: ForgeRPCClientProtocol,
        processGeneration expectedProcessGeneration: UInt64
    ) async {
        do {
            let version = try await client.sdkVersion()
            guard expectedProcessGeneration == generation, snapshot.sdkVersion != version else { return }
            snapshot.sdkVersion = version
            publishSnapshot()
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Could not read the ForgeCode SDK version: \(error.localizedDescription)")
        }
    }

    private func restartAfterReadinessFailure(processGeneration expectedGeneration: UInt64) async {
        await enqueueLifecycle { supervisor in
            guard expectedGeneration == supervisor.generation,
                  supervisor.desiredEnabled,
                  !supervisor.terminating
            else { return }
            supervisor.cancelBackgroundTasks()
            supervisor.generation &+= 1
            supervisor.subscriptionGeneration &+= 1
            await supervisor.processHost.stop(
                gracePeriod: supervisor.configuration.terminationGracePeriod
            )
            supervisor.client = nil
            supervisor.snapshot.endpoint = nil
            supervisor.clearConversationData()
            supervisor.scheduleRestart(runtime: 0)
        }
    }

    private func processExited(status: Int32, runtime: TimeInterval) async {
        await enqueueLifecycle { supervisor in
            guard supervisor.desiredEnabled, !supervisor.terminating else { return }
            supervisor.cancelBackgroundTasks()
            supervisor.generation &+= 1
            supervisor.subscriptionGeneration &+= 1
            supervisor.client = nil
            supervisor.snapshot.endpoint = nil
            supervisor.clearConversationData()
            supervisor.snapshot.phase = .failed("forge3 exited unexpectedly with status \(status).")
            supervisor.publishSnapshot()
            supervisor.scheduleRestart(runtime: runtime)
        }
    }

    private func handleStartFailure(_ error: Error) {
        let message = error.localizedDescription
        logger.error(message)
        clearConversationData()
        snapshot.phase = .failed(message)
        publishSnapshot()
        scheduleRestart(runtime: 0)
    }

    private func scheduleRestart(runtime: TimeInterval) {
        guard desiredEnabled, !terminating else { return }
        restartAttempt = configuration.restartBackoff.nextAttempt(
            previousAttempt: restartAttempt,
            runtime: runtime
        )
        let delay = configuration.restartBackoff.delay(forAttempt: restartAttempt)
        snapshot.phase = .restarting(attempt: restartAttempt, delay: delay)
        snapshot.conversationStreamState = .disconnected
        publishSnapshot()
        logger.warning("Restarting forge3 in \(String(format: "%.1f", delay)) seconds (attempt \(restartAttempt))")
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            await self.enqueueLifecycle { supervisor in
                await supervisor.startLocked()
            }
        }
    }

    private func subscriptionIsCurrent(
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled
            && desiredEnabled
            && !terminating
            && expectedProcessGeneration == generation
            && expectedSubscriptionGeneration == subscriptionGeneration
    }

    private func cancelBackgroundTasks() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        restartTask?.cancel()
        restartTask = nil
        titleRefreshTask?.cancel()
        titleRefreshTask = nil
    }

    private func clearConversationData() {
        snapshot.activeConversations = []
        snapshot.conversationStreamState = .disconnected
        snapshot.streamError = nil
    }

    /// Clears only values derived from the running helper. The app's own
    /// version is not service state and must survive stop and restart.
    private func clearServiceIdentity() {
        snapshot.sdkVersion = nil
    }

    private func publishSnapshot() {
        snapshotHandler?(snapshot)
    }

    private func isReady(_ phase: ServicePhase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    public nonisolated static func systemSleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
