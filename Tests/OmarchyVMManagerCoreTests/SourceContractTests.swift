import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Pinned source contracts")
struct SourceContractTests {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("UI opts into guest foregrounding while CLI opens the lifecycle owner in the background")
    func launchEntryPoints() throws {
        let model = try String(contentsOf: repository.appendingPathComponent("Sources/OmarchyVMManagerApp/AppModel.swift"), encoding: .utf8)
        #expect(model.contains("manager.start(id, launchIntent: .foreground)"))
        #expect(model.contains("confirmed: true, launchIntent: .foreground"))
        let cli = try String(contentsOf: repository.appendingPathComponent("Sources/OmarchyVMCLI/main.swift"), encoding: .utf8)
        #expect(cli.contains("[\"-g\", \"-j\""))
    }

    @Test("upstream source and stock lock name the reviewed baseline")
    func baseline() throws {
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Config/TryOmarchyUpstream.lock.json"))) as! [String: Any]
        #expect(lock["commit"] as? String == UpstreamBaseline.commit)
        #expect(lock["kitSHA256"] as? String == UpstreamBaseline.stockSHA256)
        #expect(lock["focusAwareClipboard"] as? Bool == false)
        let source = try String(contentsOf: repository.appendingPathComponent("Vendor/try-omarchy/macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift"), encoding: .utf8)
        #expect(source.contains("public static let version = 1"))
        let package = try String(contentsOf: repository.appendingPathComponent("Vendor/try-omarchy/macos/Package.swift"), encoding: .utf8)
        #expect(package.contains("swift-tools-version: 6.0"))
        #expect(package.contains("TryOmarchyKitClient"))
    }

    @Test("prepared POC roots are distinct UUIDs under the manager directory")
    func preparedRoots() {
        let support = URL(fileURLWithPath: "/private/tmp/source-contract")
        let roots = POCProfiles.all.map { POCProfiles.root(for: $0, applicationSupport: support) }
        #expect(Set(roots).count == 2)
        for (index, root) in roots.enumerated() {
            #expect(root.deletingLastPathComponent().path == "/private/tmp/source-contract/Omarchy VM Manager/VMs")
            #expect(root.lastPathComponent == POCProfiles.all[index].id.uuidString)
        }
    }
}

@Test("committed runtime lock matches the compiled pin and reproducible patch")
func committedRuntimeProvenance() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lockData = try Data(contentsOf: repository.appendingPathComponent("Config/TryOmarchyRuntime.lock.json"))
    #expect(KitVerifier.sha256(lockData) == RuntimePin.lockSHA256)
    let lock = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
    try KitVerifier.validate(lock, policy: .debugPOC)
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Config/TryOmarchyClipboardPatch.json"))) as! [String: String]
    #expect(lock.patchCommit == metadata["commit"])
    #expect(lock.patchSHA256 == metadata["patchSHA256"])
    let patch = try Data(contentsOf: repository.appendingPathComponent("Patches/0001-focus-aware-clipboard.patch"))
    #expect(KitVerifier.sha256(patch) == lock.patchSHA256)
}

@Test("POC CPU defaults satisfy the pinned shell's stricter minimum")
func runtimeCPUMinimum() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: repository.appendingPathComponent("Vendor/try-omarchy/macos/run-qemu-gpu.sh"), encoding: .utf8)
    #expect(source.contains("vcpu_count >= 4 && vcpu_count <= host_cpu_count"))
    #expect(POCHostPolicy.minimumVMCPUs == 4)
    #expect(POCProfiles.all.allSatisfy { $0.cpus >= POCHostPolicy.minimumVMCPUs })
}

@Test("manager SDK is prepared from the exact helper patch source")
func matchingExecutionSDK() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Config/TryOmarchyClipboardPatch.json"))) as! [String: String]
    let source = repository.appendingPathComponent(".build/runtime-source").resolvingSymlinksInPath()
    let head = try String(contentsOf: source.appendingPathComponent(".git/HEAD"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(head == metadata["commit"])
    let lock = try JSONDecoder().decode(RuntimeProvenance.self, from: Data(contentsOf: repository.appendingPathComponent("Config/TryOmarchyRuntime.lock.json")))
    #expect(lock.manualPauseVersion == 1)
    #expect(lock.launchIntentVersion == 1)
}
