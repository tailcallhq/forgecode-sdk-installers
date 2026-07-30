import Foundation

public enum RuntimeInstallationPhase: Equatable, Sendable {
    case resolving
    case downloading(progress: Double)
    case verifying
    case installing
    case ready

    public var boundedDownloadProgress: Double? {
        guard case .downloading(let progress) = self else { return nil }
        return min(1, max(0, progress))
    }
}

public enum RuntimeInstallationFailure: Equatable, Sendable {
    case download
    case verification
    case filesystem(RuntimeFilesystemFailure)
    case other
}

public enum ServicePhase: Equatable, Sendable {
    case disabled
    case installing(RuntimeInstallationPhase)
    case installationFailed(RuntimeInstallationFailure)
    case starting
    case ready
    case restarting(attempt: Int, delay: TimeInterval)
    case failed(String)
    case stopped
}

public struct ServiceSnapshot: Equatable, Sendable {
    /// Monotonically increases each time the supervisor publishes a snapshot.
    /// Consumers must ignore revisions older than the newest one they applied.
    public var revision: UInt64
    public var phase: ServicePhase
    public var endpoint: LoopbackEndpoint?
    /// SDK version reported by `rpc.discover` as `info.version`. Versioned
    /// independently of the app, so both are tracked separately.
    public var sdkVersion: String?
    /// The app's own `CFBundleShortVersionString`. Constant for a given build.
    public var appVersion: String?

    public init(
        revision: UInt64 = 0,
        phase: ServicePhase = .stopped,
        endpoint: LoopbackEndpoint? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil
    ) {
        self.revision = revision
        self.phase = phase
        self.endpoint = endpoint
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
    }
}

/// Small value-type gate shared by UI consumers and tests so asynchronous
/// callback hops cannot apply an older service snapshot after a newer one.
public struct ServiceSnapshotRevisionGate: Sendable {
    public private(set) var latestRevision: UInt64?

    public init(latestRevision: UInt64? = nil) {
        self.latestRevision = latestRevision
    }

    public mutating func accept(_ snapshot: ServiceSnapshot) -> Bool {
        if let latestRevision, snapshot.revision <= latestRevision { return false }
        latestRevision = snapshot.revision
        return true
    }
}

public enum ForgeCoreError: LocalizedError, Equatable {
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case connection(String)
    case timeout(String)
    case invalidConsoleOrigin(String)
    case missingExecutable(String)
    case processAlreadyRunning
    case processLaunch(String)
    case portAllocation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return "ForgeCode returned an unexpected response: \(message)"
        case .rpc(let code, let message):
            return "ForgeCode RPC error \(code): \(message)"
        case .connection(let message):
            return "Cannot connect to the local ForgeCode service: \(message)"
        case .timeout(let operation):
            return "Timed out while \(operation)."
        case .invalidConsoleOrigin(let value):
            return "The ForgeCode console origin is invalid: \(value)"
        case .missingExecutable(let path):
            return "The selected forge3 runtime is missing or not executable at \(path). Try reinstalling the runtime."
        case .processAlreadyRunning:
            return "The ForgeCode service process is already running."
        case .processLaunch(let message):
            return "Could not start the ForgeCode service: \(message)"
        case .portAllocation(let message):
            return "Could not select a loopback port for the ForgeCode service: \(message)"
        }
    }
}
