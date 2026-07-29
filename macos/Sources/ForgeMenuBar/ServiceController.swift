import ForgeMenuCore
import Foundation

@MainActor
final class ServiceController {
    var onSnapshotChanged: ((ServiceSnapshot) -> Void)?

    private(set) var snapshot = ServiceSnapshot() {
        didSet { onSnapshotChanged?(snapshot) }
    }

    private let supervisor: ServiceSupervisor
    private var desiredStateRevision: UInt64 = 0
    private var snapshotRevisionGate = ServiceSnapshotRevisionGate()

    init(supervisor: ServiceSupervisor) {
        self.supervisor = supervisor
    }

    /// The service runs for the lifetime of the app: it starts here at launch
    /// and is stopped by `stopForTermination()` when the app quits.
    func start() {
        desiredStateRevision &+= 1
        let revision = desiredStateRevision
        Task { [weak self] in
            guard let self else { return }
            await supervisor.installCallbacks { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await supervisor.setDesiredEnabled(true, revision: revision)
        }
    }

    func refreshNow() {
        Task { await supervisor.refreshNow() }
    }

    func retryInstallation() {
        Task { await supervisor.retryInstallation() }
    }

    func stopForTermination() async {
        await supervisor.stopForTermination()
    }

    private func apply(_ snapshot: ServiceSnapshot) {
        guard snapshotRevisionGate.accept(snapshot) else { return }
        self.snapshot = snapshot
    }
}
