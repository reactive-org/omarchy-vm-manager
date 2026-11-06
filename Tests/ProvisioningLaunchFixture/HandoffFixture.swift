#if DEBUG
import Darwin
import DevVMProvisioningCore
import Foundation
@testable import OmarchyVMManagerCore

enum HandoffFixture {
    static func admission(parent: URL, target: GuestBinding) throws -> ProvisioningTransportAdmission {
        let root = parent.appendingPathComponent("admitted-tools"); try PrivateFiles.directory(root, create: true)
        let bin = root.appendingPathComponent("bin"); try PrivateFiles.directory(bin, create: true)
        for tool in ProvisioningTransportToolAdmission.required {
            let file = root.appendingPathComponent(tool.rawValue)
            try Data("fixture-only-never-execute".utf8).write(to: file); chmod(file.path, 0o700)
            if [.ansiblePlaybook, .ansibleInventory].contains(tool) { try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(tool.rawValue), withDestinationURL: file) }
        }
        let files = LocalProvisioningToolFiles()
        guard let installation = files.directory(root.path)?.identity else { throw ProvisioningJobFailure.invalidRequest }
        let results = try ProvisioningTransportToolAdmission.required.map { tool -> ProvisioningToolResult in
            let ansible = [ProvisioningTool.ansiblePlaybook, .ansibleInventory].contains(tool)
            guard let executable = files.executable((ansible ? bin : root).appendingPathComponent(tool.rawValue).path)?.identity else { throw ProvisioningJobFailure.invalidRequest }
            return .init(tool: tool, status: .available, version: ansible ? "2.21.5" : tool == .brew ? "7.0.0" : tool == .bash ? "3.2.57" : tool == .ssh ? "10.3p1" : nil,
                executable: executable, provider: ansible ? "homebrew" : tool == .brew ? "host" : "macOS", reason: "Synthetic fixture", installation: ansible ? installation : nil)
        }
        let guest = parent.appendingPathComponent("admitted-guest"); try PrivateFiles.directory(guest, create: true)
        let storage = ManagedSSHStorage(root: guest)
        try PrivateFiles.directory(storage.directory, create: true); try PrivateFiles.directory(storage.bootstrap, create: true)
        try PrivateFiles.write(Data("PRIVATE-FIXTURE-NEVER-TRANSFER".utf8), name: "client", in: storage.directory, exclusively: true)
        let manifest: [String: Any] = ["schemaVersion": 1, "vmID": target.vmID.uuidString, "sessionToken": target.sessionID.uuidString, "hostPort": 22222]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: manifest), name: ManagedSSHStorage.manifestName, in: guest)
        let publicKey = "ssh-ed25519 " + FixtureTransportProvider.hostKey.base64EncodedString()
        let bootstrap: [String: Any] = ["schemaVersion": 1, "vmID": target.vmID.uuidString, "sessionToken": target.sessionID.uuidString, "publicKeys": [publicKey]]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: bootstrap), name: "manifest.json", in: storage.bootstrap)
        try PrivateFiles.write(Data((storage.alias(target.vmID) + " " + publicKey + "\n").utf8), name: "known_hosts", in: storage.directory)
        return try .init(root: guest, port: 22222, target: target, report: .init(tools: results), policy: .fixture(root))
    }
}
#endif
