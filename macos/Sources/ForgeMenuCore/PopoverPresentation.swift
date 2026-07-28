import Foundation

public struct PopoverPresentation: Equatable, Sendable {
    public enum ServiceTone: Equatable, Sendable {
        case normal
        case active
        case warning
        case inactive
    }

    public struct ConversationRow: Equatable, Sendable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public let serviceTitle: String
    public let serviceDetail: String
    public let serviceTone: ServiceTone
    public let endpointAddress: String?
    public let endpointPortLabel: String?
    public let versionLabel: String?
    public let endpointTooltip: String?
    public let canOpenFrontend: Bool
    public let conversations: [ConversationRow]
    /// Right-hand text of the collapsed "Conversations" disclosure row.
    public let conversationsSummary: String
    /// Whether the disclosure row can be expanded. There is nothing to show
    /// when the service is off, so the row stays inert rather than opening an
    /// empty list.
    public let canExpandConversations: Bool
    public let bodyMessage: String?
    public let refreshEnabled: Bool
    public let restartEnabled: Bool
    public let actionableError: String?

    public static func make(snapshot: ServiceSnapshot) -> PopoverPresentation {
        let rows = isInactive(snapshot.phase) ? [] : snapshot.activeConversations.map {
            ConversationRow(id: $0.id, title: $0.title)
        }
        let bodyMessage: String?
        if rows.isEmpty {
            switch snapshot.phase {
            case .ready:
                switch snapshot.conversationStreamState {
                case .subscribed: bodyMessage = "No active conversations"
                case .connecting, .reconnecting: bodyMessage = "Connecting…"
                case .disconnected: bodyMessage = "Conversations unavailable"
                }
            case .starting, .restarting:
                bodyMessage = "Connecting…"
            case .failed:
                bodyMessage = "Conversations unavailable"
            case .disabled, .stopped:
                bodyMessage = "Start ForgeCode to view active conversations"
            }
        } else {
            bodyMessage = nil
        }

        let phaseError: String?
        if case .failed(let message) = snapshot.phase { phaseError = message } else { phaseError = nil }
        let header = serviceHeader(snapshot: snapshot)
        return PopoverPresentation(
            serviceTitle: header.title,
            serviceDetail: header.detail,
            serviceTone: header.tone,
            endpointAddress: snapshot.endpoint?.webSocketURL.absoluteString,
            endpointPortLabel: snapshot.endpoint.map { "Port \($0.port)" },
            versionLabel: versionLabel(snapshot: snapshot),
            endpointTooltip: endpointTooltip(snapshot),
            canOpenFrontend: canOpenFrontend(snapshot),
            conversations: rows,
            conversationsSummary: conversationsSummary(snapshot: snapshot, rows: rows),
            canExpandConversations: !isInactive(snapshot.phase),
            bodyMessage: bodyMessage,
            refreshEnabled: refreshEnabled(snapshot),
            restartEnabled: !isInactive(snapshot.phase),
            actionableError: phaseError ?? snapshot.streamError
        )
    }

    private static func serviceHeader(
        snapshot: ServiceSnapshot
    ) -> (title: String, detail: String, tone: ServiceTone) {
        switch snapshot.phase {
        case .ready:
            switch snapshot.conversationStreamState {
            case .subscribed:
                let count = snapshot.activeConversations.count
                return ("ForgeCode", count == 1 ? "1 running" : "\(count) running", .normal)
            case .connecting:
                return ("ForgeCode", "Connecting", .active)
            case .reconnecting:
                return ("ForgeCode", "Reconnecting", .warning)
            case .disconnected:
                return ("ForgeCode", "Unavailable", .warning)
            }
        case .starting:
            return ("ForgeCode", "Starting", .active)
        case .restarting:
            return ("ForgeCode", "Restarting", .active)
        case .failed:
            return ("ForgeCode", "Unavailable", .warning)
        case .disabled:
            return ("ForgeCode", "Off", .inactive)
        case .stopped:
            return ("ForgeCode", "Stopped", .inactive)
        }
    }

    private static func conversationsSummary(
        snapshot: ServiceSnapshot,
        rows: [ConversationRow]
    ) -> String {
        if isInactive(snapshot.phase) { return "Off" }
        if !rows.isEmpty { return rows.count == 1 ? "1 running" : "\(rows.count) running" }
        switch snapshot.phase {
        case .ready:
            switch snapshot.conversationStreamState {
            case .subscribed: return "None running"
            case .connecting, .reconnecting: return "Connecting…"
            case .disconnected: return "Unavailable"
            }
        case .starting, .restarting: return "Connecting…"
        case .failed: return "Unavailable"
        case .disabled, .stopped: return "Off"
        }
    }

    /// One version, shown once. The app releases 1:1 with the forge3 it
    /// bundles, so the two versions agree on every published build and
    /// repeating the same number twice would be noise.
    ///
    /// The server is still shown separately when it genuinely disagrees —
    /// a dev build reports `0.1.0-dev`, and a mismatch on a real build means
    /// the running helper is not the one packaged, which is worth seeing
    /// rather than hiding.
    private static func versionLabel(snapshot: ServiceSnapshot) -> String? {
        guard let app = snapshot.appVersion else {
            return snapshot.sdkVersion.map { "Server \($0)" }
        }
        guard let server = snapshot.sdkVersion, server != app else { return "Version \(app)" }
        return "Version \(app) · Server \(server)"
    }

    private static func endpointTooltip(_ snapshot: ServiceSnapshot) -> String? {
        guard let endpoint = snapshot.endpoint else { return nil }
        let address = endpoint.webSocketURL.absoluteString
        var lines = [address]
        if let app = snapshot.appVersion { lines.append("ForgeCode \(app)") }
        // Same rule as versionLabel: the server line is redundant when it
        // matches the app version it shipped with.
        if let server = snapshot.sdkVersion, server != snapshot.appVersion {
            lines.append("Server \(server)")
        }
        return lines.joined(separator: "\n")
    }

    private static func canOpenFrontend(_ snapshot: ServiceSnapshot) -> Bool {
        guard snapshot.endpoint != nil else { return false }
        switch snapshot.phase {
        case .ready: return true
        default: return false
        }
    }

    private static func refreshEnabled(_ snapshot: ServiceSnapshot) -> Bool {
        switch snapshot.phase {
        case .starting, .ready, .restarting: return snapshot.endpoint != nil
        case .disabled, .failed, .stopped: return false
        }
    }

    private static func isInactive(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .disabled, .stopped: return true
        default: return false
        }
    }
}
