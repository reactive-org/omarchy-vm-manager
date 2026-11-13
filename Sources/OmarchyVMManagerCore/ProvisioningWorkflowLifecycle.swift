import DevVMProvisioningCore
import Foundation

struct ProvisioningPreparationLease: Sendable, Equatable { let token: UUID, jobID: UUID; let target: GuestBinding }
struct ProvisioningRestartLease: Sendable, Equatable { let token: UUID, workflowID: UUID; let target: GuestBinding }
enum ProvisioningSSHAdmission: Sendable { case waiting, ready }
protocol ProvisioningHelperLifecycleObserving: Sendable {
    func waitForExit(jobID: UUID, identity: ProvisioningHelperIdentity, timeout: Duration) async -> Bool
}
protocol ProvisioningServiceLaunching: ProvisioningManagerSessionDispatching, ProvisioningTransportHelperLaunching, ProvisioningHelperLifecycleObserving {}

extension ProvisioningCoordinator {
    func beginPreparation(jobID: UUID, target: GuestBinding, cancel: @escaping @Sendable () async -> Void) async throws -> ProvisioningPreparationLease {
        try await managerBeginPreparation(jobID: jobID, target: target, cancel: cancel)
    }
}
