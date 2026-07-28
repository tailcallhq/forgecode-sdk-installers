import ForgeMenuCore
import Foundation

@MainActor
final class ServiceController {
    var onSnapshotChanged: ((ServiceSnapshot) -> Void)?

    private(set) var snapshot = ServiceSnapshot() {
        didSet { onSnapshotChanged?(snapshot) }
    }

    private let preferences: AppPreferences
    private let supervisor: ServiceSupervisor
    private var desiredStateRevision: UInt64 = 0

    init(preferences: AppPreferences, supervisor: ServiceSupervisor) {
        self.preferences = preferences
        self.supervisor = supervisor
    }

    func startAccordingToPreference() {
        let enabled = preferences.runService
        desiredStateRevision &+= 1
        let revision = desiredStateRevision
        Task { [weak self] in
            guard let self else { return }
            await supervisor.installCallbacks { [weak self] snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
            await supervisor.setDesiredEnabled(enabled, revision: revision)
        }
    }

    func setRunService(_ enabled: Bool) {
        preferences.runService = enabled
        desiredStateRevision &+= 1
        let revision = desiredStateRevision
        Task { await supervisor.setDesiredEnabled(enabled, revision: revision) }
    }

    func refreshNow() {
        Task { await supervisor.refreshNow() }
    }

    func restart() {
        Task { await supervisor.restart() }
    }

    func stopForTermination() async {
        await supervisor.stopForTermination()
    }
}
