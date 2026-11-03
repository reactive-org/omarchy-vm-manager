#if DEBUG
import Foundation
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

/// Excluded debug fixture. The only executable invocation is a fixed local
/// shell/printf/sleep fixture; original SSH/Ansible argv never reaches it.
actor FixtureStreamRunner: ProvisioningProcessRunner {
    private let fake = FixtureTransportRunner(holdFeatures: false)
    private let local: LocalProvisioningProcessRunner
    private let directory: URL
    init(input: ProvisioningValidatedFrozenContext, terminal: ProvisioningTerminal, layout: ProvisioningPackageLayout) throws {
        local = try BundledProvisioning.localRuntime(for: input, layout: layout, terminal: terminal).runner
        directory = input.storage.directory.standardizedFileURL
    }
    func run(_ invocation: ProvisioningProcessInvocation) async -> ProvisioningProcessResult {
        if invocation.purpose != .features { return await fake.run(invocation) }
        let localInvocation = ProvisioningProcessInvocation(id: invocation.id, commandID: invocation.commandID, context: invocation.context,
            purpose: invocation.purpose, executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '\\033[32mstream-fixture\\033[0m\\r☃\\n'; /bin/sleep 0.3"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
            workingDirectory: directory, input: .closed, output: .terminalStream, timeoutSeconds: 3)
        return await local.run(localInvocation)
    }
    func interrupt(invocationID: UUID) async { await local.interrupt(invocationID: invocationID); await fake.interrupt(invocationID: invocationID) }
}
#endif
