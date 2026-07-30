import Foundation

public actor ServiceSupervisor {
    public struct Configuration: Sendable {
        public let readinessTimeout: TimeInterval
        public let readinessPollInterval: TimeInterval
        public let terminationGracePeriod: TimeInterval
        public let restartBackoff: RestartBackoff
        /// Minimum interval between determinate download publications. Other
        /// installation phase transitions remain immediate.
        public let installationProgressPublishInterval: TimeInterval

        public init(
            readinessTimeout: TimeInterval = 30,
            readinessPollInterval: TimeInterval = 0.5,
            terminationGracePeriod: TimeInterval = 3,
            restartBackoff: RestartBackoff = RestartBackoff(),
            installationProgressPublishInterval: TimeInterval = 0.1
        ) {
            self.readinessTimeout = readinessTimeout
            self.readinessPollInterval = readinessPollInterval
            self.terminationGracePeriod = terminationGracePeriod
            self.restartBackoff = restartBackoff
            self.installationProgressPublishInterval = max(0, installationProgressPublishInterval)
        }
    }

    public typealias ClientFactory = @Sendable (LoopbackEndpoint) -> ForgeRPCClientProtocol
    public typealias SnapshotHandler = @Sendable (ServiceSnapshot) -> Void

    public private(set) var snapshot = ServiceSnapshot()

    private let processHost: ForgeProcessHosting
    private let runtimeInstaller: any RuntimeInstalling
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
    private var probeTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var readinessWatchdogTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var installationProgressTask: Task<Void, Never>?
    private var pendingInstallationProgress: RuntimeInstallationPhase?
    private var lastInstallationProgressPublishedAt: Date?
    private var commandTail: Task<Void, Never>?

    public init(
        processHost: ForgeProcessHosting,
        runtimeInstaller: any RuntimeInstalling,
        endpointAllocator: LoopbackEndpointAllocating = SystemLoopbackEndpointAllocator(),
        clientFactory: @escaping ClientFactory,
        logger: AppLogger = .shared,
        configuration: Configuration = Configuration(),
        appVersion: String? = AppVersion.currentDescription,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await ServiceSupervisor.systemSleep(seconds)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processHost = processHost
        self.runtimeInstaller = runtimeInstaller
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
        processHost.onExit = { [weak self] status, runtime, generation in
            Task { await self?.processExited(status: status, runtime: runtime, generation: generation) }
        }
        snapshotHandler?(snapshot)
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !terminating else { return }
        latestDesiredStateRevision &+= 1
        if !enabled { cancelInstallForSupersedingLifecycle() }
        await applyDesiredEnabled(enabled, revision: latestDesiredStateRevision)
    }

    public func setDesiredEnabled(_ enabled: Bool, revision: UInt64) async {
        guard !terminating, revision > latestDesiredStateRevision else { return }
        latestDesiredStateRevision = revision
        if !enabled { cancelInstallForSupersedingLifecycle() }
        await applyDesiredEnabled(enabled, revision: revision)
    }

    private func applyDesiredEnabled(_ enabled: Bool, revision: UInt64) async {
        await enqueueLifecycle { supervisor in
            guard revision == supervisor.latestDesiredStateRevision else { return }
            let wasEnabled = supervisor.desiredEnabled
            supervisor.desiredEnabled = enabled
            if enabled {
                guard !wasEnabled else { return }
                await supervisor.startLocked()
            } else {
                await supervisor.stopLocked(finalPhase: .disabled)
            }
        }
    }

    public func restart() async {
        cancelInstallForSupersedingLifecycle()
        await enqueueLifecycle { supervisor in
            guard supervisor.desiredEnabled, !supervisor.terminating else { return }
            await supervisor.stopLocked(finalPhase: .stopped)
            await supervisor.startLocked()
        }
    }

    public func retryInstallation() async {
        await enqueueLifecycle { supervisor in
            guard supervisor.desiredEnabled, !supervisor.terminating else { return }
            guard case .installationFailed = supervisor.snapshot.phase else { return }
            await supervisor.startLocked()
        }
    }

    public func stopForTermination() async {
        terminating = true
        cancelInstallForSupersedingLifecycle()
        latestDesiredStateRevision &+= 1
        let terminationRevision = latestDesiredStateRevision
        desiredEnabled = false
        await enqueueLifecycle { supervisor in
            guard terminationRevision == supervisor.latestDesiredStateRevision else { return }
            supervisor.desiredEnabled = false
            await supervisor.stopLocked(finalPhase: .stopped)
        }
    }

    /// Re-probes the running service: verifies it still answers RPCs and
    /// re-reads the reported SDK version. Independent of lifecycle commands.
    public func refreshNow() {
        guard desiredEnabled, !terminating, let client else { return }
        subscriptionGeneration &+= 1
        startHealthProbe(
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
        installTask?.cancel()
        cancelInstallationProgress()
        generation &+= 1
        subscriptionGeneration &+= 1
        clearServiceIdentity()
        snapshot.endpoint = nil
        snapshot.phase = .installing(.resolving)
        publishSnapshot()
        lastInstallationProgressPublishedAt = now()

        let processGeneration = generation
        let currentSubscriptionGeneration = subscriptionGeneration
        installTask = Task { [weak self, runtimeInstaller] in
            do {
                let runtime: InstalledRuntime
                if let cached = try await runtimeInstaller.installedCurrentRuntime() {
                    runtime = cached
                    await self?.applyInstallationProgress(.ready, generation: processGeneration)
                } else {
                    runtime = try await runtimeInstaller.installLatest { [weak self] phase in
                        await self?.applyInstallationProgress(phase, generation: processGeneration)
                    }
                }
                try Task.checkCancellation()
                await self?.runtimePreparationCompleted(
                    .success(runtime),
                    generation: processGeneration,
                    subscriptionGeneration: currentSubscriptionGeneration
                )
            } catch {
                await self?.runtimePreparationCompleted(
                    .failure(error),
                    generation: processGeneration,
                    subscriptionGeneration: currentSubscriptionGeneration
                )
            }
        }
    }

    private func runtimePreparationCompleted(
        _ result: Result<InstalledRuntime, Error>,
        generation expectedGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) async {
        guard lifecycleIsCurrent(expectedGeneration) else { return }
        installTask = nil
        switch result {
        case .success(let runtime):
            await enqueueLifecycle { supervisor in
                guard supervisor.lifecycleIsCurrent(expectedGeneration),
                      expectedSubscriptionGeneration == supervisor.subscriptionGeneration
                else { return }
                await supervisor.spawnLocked(
                    runtime: runtime,
                    generation: expectedGeneration,
                    subscriptionGeneration: expectedSubscriptionGeneration
                )
            }
        case .failure(let error):
            if error is CancellationError || error as? RuntimeInstallerError == .cancelled { return }
            guard lifecycleIsCurrent(expectedGeneration) else { return }
            client = nil
            snapshot.endpoint = nil
            handleInstallationFailure(error)
        }
    }

    private func spawnLocked(
        runtime: InstalledRuntime,
        generation expectedGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) async {
        guard lifecycleIsCurrent(expectedGeneration),
              expectedSubscriptionGeneration == subscriptionGeneration
        else { return }
        do {
            let endpoint = try endpointAllocator.allocate()
            guard lifecycleIsCurrent(expectedGeneration),
                  expectedSubscriptionGeneration == subscriptionGeneration
            else { return }
            let newClient = clientFactory(endpoint)
            client = newClient
            snapshot.endpoint = endpoint
            snapshot.phase = .starting
            publishSnapshot()

            guard lifecycleIsCurrent(expectedGeneration),
                  expectedSubscriptionGeneration == subscriptionGeneration
            else { return }
            try await processHost.start(
                runtime: runtime,
                endpoint: endpoint,
                generation: expectedGeneration
            )
            guard lifecycleIsCurrent(expectedGeneration),
                  expectedSubscriptionGeneration == subscriptionGeneration
            else {
                await processHost.stop(gracePeriod: configuration.terminationGracePeriod)
                return
            }
            startHealthProbe(
                client: newClient,
                processGeneration: expectedGeneration,
                subscriptionGeneration: expectedSubscriptionGeneration,
                initialReadiness: true
            )
        } catch is CancellationError {
            return
        } catch {
            guard lifecycleIsCurrent(expectedGeneration) else { return }
            client = nil
            snapshot.endpoint = nil
            handleStartFailure(error)
        }
    }

    private func stopLocked(finalPhase: ServicePhase) async {
        installTask?.cancel()
        installTask = nil
        cancelBackgroundTasks()
        cancelInstallationProgress()
        generation &+= 1
        subscriptionGeneration &+= 1
        await processHost.stop(gracePeriod: configuration.terminationGracePeriod)
        client = nil
        snapshot.endpoint = nil
        snapshot.phase = finalPhase
        clearServiceIdentity()
        publishSnapshot()
    }

    private func applyInstallationProgress(
        _ phase: RuntimeInstallationPhase,
        generation expectedGeneration: UInt64
    ) {
        guard lifecycleIsCurrent(expectedGeneration), isInstallationPhase(snapshot.phase) else { return }
        let bounded: RuntimeInstallationPhase
        if case .downloading(let progress) = phase {
            bounded = .downloading(progress: min(1, max(0, progress)))
        } else {
            bounded = phase
        }

        if case .downloading = bounded {
            // Determinate updates are handled by the coalescing path below.
        } else {
            installationProgressTask?.cancel()
            installationProgressTask = nil
            if let pendingInstallationProgress {
                self.pendingInstallationProgress = nil
                snapshot.phase = .installing(pendingInstallationProgress)
                publishSnapshot()
            }
            snapshot.phase = .installing(bounded)
            publishSnapshot()
            lastInstallationProgressPublishedAt = now()
            return
        }

        guard configuration.installationProgressPublishInterval > 0,
              let lastPublished = lastInstallationProgressPublishedAt
        else {
            snapshot.phase = .installing(bounded)
            publishSnapshot()
            lastInstallationProgressPublishedAt = now()
            return
        }

        let elapsed = now().timeIntervalSince(lastPublished)
        if elapsed >= configuration.installationProgressPublishInterval {
            snapshot.phase = .installing(bounded)
            publishSnapshot()
            lastInstallationProgressPublishedAt = now()
            return
        }

        pendingInstallationProgress = bounded
        guard installationProgressTask == nil else { return }
        let delay = configuration.installationProgressPublishInterval - max(0, elapsed)
        installationProgressTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            await self.flushPendingInstallationProgress(generation: expectedGeneration)
        }
    }

    private func flushPendingInstallationProgress(generation expectedGeneration: UInt64) {
        installationProgressTask = nil
        guard lifecycleIsCurrent(expectedGeneration),
              isInstallationPhase(snapshot.phase),
              let pendingInstallationProgress
        else {
            self.pendingInstallationProgress = nil
            return
        }
        self.pendingInstallationProgress = nil
        snapshot.phase = .installing(pendingInstallationProgress)
        publishSnapshot()
        lastInstallationProgressPublishedAt = now()
    }

    private func cancelInstallationProgress() {
        installationProgressTask?.cancel()
        installationProgressTask = nil
        pendingInstallationProgress = nil
        lastInstallationProgressPublishedAt = nil
    }

    private func cancelInstallForSupersedingLifecycle() {
        generation &+= 1
        subscriptionGeneration &+= 1
        installTask?.cancel()
        installTask = nil
        cancelInstallationProgress()
    }

    private func lifecycleIsCurrent(_ expectedGeneration: UInt64) -> Bool {
        desiredEnabled && !terminating && expectedGeneration == generation
    }

    private func isInstallationPhase(_ phase: ServicePhase) -> Bool {
        if case .installing = phase { return true }
        return false
    }

    private func startHealthProbe(
        client: ForgeRPCClientProtocol,
        processGeneration: UInt64,
        subscriptionGeneration: UInt64,
        initialReadiness: Bool
    ) {
        probeTask?.cancel()
        readinessWatchdogTask?.cancel()
        if initialReadiness {
            readinessWatchdogTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.sleep(self.configuration.readinessTimeout) } catch { return }
                await self.initialReadinessTimedOut(
                    processGeneration: processGeneration,
                    subscriptionGeneration: subscriptionGeneration
                )
            }
        } else {
            readinessWatchdogTask = nil
        }
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.runHealthProbe(
                client: client,
                processGeneration: processGeneration,
                subscriptionGeneration: subscriptionGeneration,
                initialReadiness: initialReadiness
            )
        }
    }

    /// Polls `rpc.discover` until the service answers, then marks it ready and
    /// records the reported SDK version. Failures inside the readiness window
    /// retry on the poll interval; persistent failure fails the lifecycle and
    /// schedules a restart.
    private func runHealthProbe(
        client: ForgeRPCClientProtocol,
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64,
        initialReadiness: Bool
    ) async {
        let readinessDeadline = now().addingTimeInterval(configuration.readinessTimeout)

        while subscriptionIsCurrent(
            processGeneration: expectedProcessGeneration,
            subscriptionGeneration: expectedSubscriptionGeneration
        ) {
            do {
                let raw = try await client.sdkVersion()
                guard subscriptionIsCurrent(
                    processGeneration: expectedProcessGeneration,
                    subscriptionGeneration: expectedSubscriptionGeneration
                ) else { return }
                readinessWatchdogTask?.cancel()
                readinessWatchdogTask = nil
                // Normalize through semver so a `v` prefix or stray whitespace
                // from the server renders identically to the app's own version.
                snapshot.sdkVersion = AppVersion.parse(raw)?.description ?? raw
                snapshot.phase = .ready
                restartAttempt = 0
                publishSnapshot()
                return
            } catch is CancellationError {
                return
            } catch {
                guard subscriptionIsCurrent(
                    processGeneration: expectedProcessGeneration,
                    subscriptionGeneration: expectedSubscriptionGeneration
                ) else { return }

                let message = error.localizedDescription
                if now() >= readinessDeadline {
                    snapshot.phase = .failed(message)
                    publishSnapshot()
                    logger.error("ForgeCode service health probe failed readiness: \(message)")
                    await restartAfterReadinessFailure(processGeneration: expectedProcessGeneration)
                    return
                }

                if !initialReadiness {
                    logger.warning("ForgeCode service health probe failed; retrying: \(message)")
                }
                do { try await sleep(configuration.readinessPollInterval) } catch { return }
            }
        }
    }

    private func initialReadinessTimedOut(
        processGeneration expectedProcessGeneration: UInt64,
        subscriptionGeneration expectedSubscriptionGeneration: UInt64
    ) async {
        readinessWatchdogTask = nil
        guard subscriptionIsCurrent(
            processGeneration: expectedProcessGeneration,
            subscriptionGeneration: expectedSubscriptionGeneration
        ), !isReady(snapshot.phase) else { return }

        let message = "Timed out waiting for the ForgeCode service to become ready."
        snapshot.phase = .failed(message)
        publishSnapshot()
        logger.error(message)
        await restartAfterReadinessFailure(processGeneration: expectedProcessGeneration)
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
            supervisor.scheduleRestart(runtime: 0)
        }
    }

    private func processExited(status: Int32, runtime: TimeInterval, generation exitedGeneration: UInt64) async {
        await enqueueLifecycle { supervisor in
            guard exitedGeneration == supervisor.generation,
                  supervisor.desiredEnabled,
                  !supervisor.terminating
            else { return }
            supervisor.cancelBackgroundTasks()
            supervisor.generation &+= 1
            supervisor.subscriptionGeneration &+= 1
            supervisor.client = nil
            supervisor.snapshot.endpoint = nil
            supervisor.snapshot.phase = .failed("forge3 exited unexpectedly with status \(status).")
            supervisor.publishSnapshot()
            supervisor.scheduleRestart(runtime: runtime)
        }
    }

    private func handleInstallationFailure(_ error: Error) {
        let failure = installationFailure(error)
        logger.error(error.localizedDescription)
        snapshot.phase = .installationFailed(failure)
        publishSnapshot()
    }

    private func installationFailure(_ error: Error) -> RuntimeInstallationFailure {
        switch error {
        case RuntimeInstallerError.network,
             RuntimeInstallerError.networkTimeout,
             RuntimeInstallerError.invalidHTTPStatus,
             RuntimeInstallerError.missingContentLength,
             RuntimeInstallerError.invalidContentLength,
             RuntimeInstallerError.responseTooLarge,
             RuntimeInstallerError.tooManyRedirects,
             RuntimeInstallerError.unsafeRedirect:
            return .download
        case RuntimeInstallerError.checksumMismatch,
             RuntimeInstallerError.invalidChecksumSidecar,
             RuntimeInstallerError.invalidManifest,
             RuntimeInstallerError.malformedArchive,
             RuntimeInstallerError.unsafeArchiveEntry,
             RuntimeInstallerError.archiveLimitExceeded,
             RuntimeInstallerError.missingRuntimeExecutable,
             RuntimeInstallerError.duplicateRuntimeExecutable,
             RuntimeInstallerError.invalidMachO,
             RuntimeInstallerError.wrongArchitecture:
            return .verification
        case RuntimeInstallerError.filesystem(_, _, let failure):
            return .filesystem(failure)
        default:
            return .other
        }
    }

    private func handleStartFailure(_ error: Error) {
        let message = error.localizedDescription
        logger.error(message)
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
        probeTask?.cancel()
        probeTask = nil
        restartTask?.cancel()
        restartTask = nil
        readinessWatchdogTask?.cancel()
        readinessWatchdogTask = nil
    }

    /// Clears only values derived from the running helper. The app's own
    /// version is not service state and must survive stop and restart.
    private func clearServiceIdentity() {
        snapshot.sdkVersion = nil
    }

    private func publishSnapshot() {
        snapshot.revision &+= 1
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
