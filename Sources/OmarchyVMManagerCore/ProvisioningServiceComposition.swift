import Foundation

/// Product composition is installed once without probing tools, constructing a
/// process runner, starting a helper or operating a VM. Execution stays gated.
extension VMManager {
    public func installProvisioningService(layout: ProvisioningPackageLayout) async throws -> ProvisioningService {
        try await installProductProvisioningService(layout: layout)
    }
}
