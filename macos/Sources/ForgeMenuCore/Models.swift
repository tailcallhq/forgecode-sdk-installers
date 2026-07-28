import Foundation

public struct ActiveConversation: Equatable, Sendable, Identifiable {
    /// Shown until the SDK's title extension stores a generated title.
    public static let placeholderTitle = "Untitled"

    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static func isPlaceholderTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderTitle
    }

    public var hasPlaceholderTitle: Bool { Self.isPlaceholderTitle(title) }
}

public enum ConversationStreamState: Equatable, Sendable {
    case disconnected
    case connecting
    case subscribed
    case reconnecting(attempt: Int, delay: TimeInterval)
}

public enum ServicePhase: Equatable, Sendable {
    case disabled
    case starting
    case ready
    case restarting(attempt: Int, delay: TimeInterval)
    case failed(String)
    case stopped
}

public struct ServiceSnapshot: Equatable, Sendable {
    public var phase: ServicePhase
    public var endpoint: LoopbackEndpoint?
    public var activeConversations: [ActiveConversation]
    public var conversationStreamState: ConversationStreamState
    public var streamError: String?
    /// SDK version reported by `rpc.discover` as `info.version`.
    ///
    /// Tracked separately from `appVersion` even though the app ships 1:1 with
    /// forge3: this is what the *running* helper reports, so a disagreement is
    /// real information (a dev build, or a helper that is not the one
    /// packaged) rather than something to assume away.
    public var sdkVersion: String?
    /// The app's `CFBundleShortVersionString`, i.e. the version of the forge3
    /// release it was packaged with. Constant for a given build.
    public var appVersion: String?

    public init(
        phase: ServicePhase = .stopped,
        endpoint: LoopbackEndpoint? = nil,
        activeConversations: [ActiveConversation] = [],
        conversationStreamState: ConversationStreamState = .disconnected,
        streamError: String? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil
    ) {
        self.phase = phase
        self.endpoint = endpoint
        self.activeConversations = activeConversations
        self.conversationStreamState = conversationStreamState
        self.streamError = streamError
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
    }
}

public enum ForgeCoreError: LocalizedError, Equatable {
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case connection(String)
    case timeout(String)
    case streamInterrupted(String)
    case invalidConsoleOrigin(String)
    case missingExecutable(String)
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
        case .streamInterrupted(let message):
            return "The active-conversation stream was interrupted: \(message)"
        case .invalidConsoleOrigin(let value):
            return "The ForgeCode console origin is invalid: \(value)"
        case .missingExecutable(let path):
            return "The bundled forge3 helper is missing or not executable at \(path). Reinstall the app."
        case .processLaunch(let message):
            return "Could not start the ForgeCode service: \(message)"
        case .portAllocation(let message):
            return "Could not select a loopback port for the ForgeCode service: \(message)"
        }
    }
}
