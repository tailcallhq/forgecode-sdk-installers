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
    public enum InstallationProgress: Equatable, Sendable {
        case indeterminate(label: String)
        case determinate(value: Double, label: String)
    }

    public let retryInstallationEnabled: Bool
    public let installationProgress: InstallationProgress?
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
                case .connecting, .reconnecting: bodyMessage = "Connecting"
                case .disconnected: bodyMessage = "Conversations unavailable"
                }
            case .installing(let phase):
                bodyMessage = installationBodyMessage(phase)
            case .installationFailed:
                bodyMessage = "Runtime installation failed"
            case .starting, .restarting:
                bodyMessage = "Connecting"
            case .failed:
                bodyMessage = "Conversations unavailable"
            case .disabled, .stopped:
                bodyMessage = "The ForgeCode service is not running"
            }
        } else {
            bodyMessage = nil
        }

        let phaseError: String?
        switch snapshot.phase {
        case .failed(let message): phaseError = message
        case .installationFailed(let failure): phaseError = installationFailureMessage(failure)
        default: phaseError = nil
        }
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
            retryInstallationEnabled: isInstallationFailure(snapshot.phase),
            installationProgress: installationProgress(snapshot.phase),
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
        case .installing(let phase):
            return ("ForgeCode", installationDetail(phase), .active)
        case .installationFailed:
            return ("ForgeCode", "Install failed", .warning)
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
            case .connecting, .reconnecting: return "Connecting"
            case .disconnected: return "Unavailable"
            }
        case .installing: return "Installing"
        case .installationFailed: return "Unavailable"
        case .starting, .restarting: return "Connecting"
        case .failed: return "Unavailable"
        case .disabled, .stopped: return "Off"
        }
    }

    /// The app and the bundled server version independently, since a release
    /// of either can move without the other. The server line only appears once
    /// the running helper has reported it.
    private static func versionLabel(snapshot: ServiceSnapshot) -> String? {
        guard let app = snapshot.appVersion else {
            return snapshot.sdkVersion.map { "Server \($0)" }
        }
        guard let server = snapshot.sdkVersion else { return app }
        return "\(app) · Server \(server)"
    }

    private static func endpointTooltip(_ snapshot: ServiceSnapshot) -> String? {
        guard let endpoint = snapshot.endpoint else { return nil }
        let address = endpoint.webSocketURL.absoluteString
        var lines = [address]
        if let app = snapshot.appVersion { lines.append("ForgeCode \(app)") }
        if let server = snapshot.sdkVersion { lines.append("Server \(server)") }
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
        case .disabled, .installing, .installationFailed, .failed, .stopped: return false
        }
    }

    private static func isInstallationFailure(_ phase: ServicePhase) -> Bool {
        if case .installationFailed = phase { return true }
        return false
    }

    private static func installationFailureMessage(_ failure: RuntimeInstallationFailure) -> String {
        switch failure {
        case .download:
            return "Runtime download failed. Check your connection and retry."
        case .verification:
            return "Runtime verification failed. Retry the installation."
        case .filesystem(.permissionDenied):
            return "Runtime folder access was denied. Check permissions and retry."
        case .filesystem(.diskFull):
            return "Not enough disk space. Free space and retry."
        case .filesystem(.readOnlyFilesystem):
            return "Runtime storage is read-only. Choose writable storage and retry."
        case .filesystem(.io), .filesystem(.other), .other:
            return "Runtime installation failed. Retry the installation."
        }
    }

    private static func installationProgress(_ phase: ServicePhase) -> InstallationProgress? {
        guard case .installing(let installPhase) = phase else { return nil }
        switch installPhase {
        case .resolving:
            return .indeterminate(label: "Resolving ForgeCode runtime")
        case .downloading(let progress):
            let bounded = min(1, max(0, progress))
            return .determinate(
                value: bounded,
                label: "Downloading ForgeCode runtime, \(Int(bounded * 100)) percent"
            )
        case .verifying:
            return .indeterminate(label: "Verifying ForgeCode runtime")
        case .installing:
            return .indeterminate(label: "Installing ForgeCode runtime")
        case .ready:
            return .indeterminate(label: "Starting ForgeCode service")
        }
    }

    private static func installationDetail(_ phase: RuntimeInstallationPhase) -> String {
        switch phase {
        case .resolving: return "Resolving runtime"
        case .downloading(let progress): return "Downloading \(Int(min(1, max(0, progress)) * 100))%"
        case .verifying: return "Verifying runtime"
        case .installing: return "Installing runtime"
        case .ready: return "Runtime ready"
        }
    }

    private static func installationBodyMessage(_ phase: RuntimeInstallationPhase) -> String {
        switch phase {
        case .resolving: return "Finding the ForgeCode runtime"
        case .downloading: return "Downloading the ForgeCode runtime"
        case .verifying: return "Verifying the downloaded runtime"
        case .installing: return "Installing the ForgeCode runtime"
        case .ready: return "Starting the ForgeCode service"
        }
    }

    private static func isInactive(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .disabled, .stopped: return true
        default: return false
        }
    }
}
