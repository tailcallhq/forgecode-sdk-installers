import Foundation

public struct PopoverPresentation: Equatable, Sendable {
    public enum ServiceTone: Equatable, Sendable {
        case normal
        case active
        case warning
        case inactive
    }

    public let serviceTitle: String
    public let serviceDetail: String
    public let serviceTone: ServiceTone
    public let endpointAddress: String?
    public let canOpenFrontend: Bool
    public enum InstallationProgress: Equatable, Sendable {
        case indeterminate(label: String)
        case determinate(value: Double, label: String)
    }

    public let retryInstallationEnabled: Bool
    public let installationProgress: InstallationProgress?
    public let actionableError: String?

    public static func make(snapshot: ServiceSnapshot) -> PopoverPresentation {
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
            canOpenFrontend: canOpenFrontend(snapshot),
            retryInstallationEnabled: isInstallationFailure(snapshot.phase),
            installationProgress: installationProgress(snapshot.phase),
            actionableError: phaseError
        )
    }

    private static func serviceHeader(
        snapshot: ServiceSnapshot
    ) -> (title: String, detail: String, tone: ServiceTone) {
        switch snapshot.phase {
        case .ready:
            return ("ForgeCode", "Running", .normal)
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

    private static func canOpenFrontend(_ snapshot: ServiceSnapshot) -> Bool {
        guard snapshot.endpoint != nil else { return false }
        switch snapshot.phase {
        case .ready: return true
        default: return false
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
}
