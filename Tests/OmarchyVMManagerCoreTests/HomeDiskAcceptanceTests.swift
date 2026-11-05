import Darwin
import Foundation
import Testing
import TryOmarchyKitClient
@testable import OmarchyVMManagerCore

// Never runs as part of ordinary make test. The approval file is created only
// for an explicitly authorized run; all registry/storage paths stay below it.
@Suite("Approved disposable home-disk acceptance")
struct HomeDiskAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMARCHY_HOME_DISK_ACCEPTANCE"] != nil))
    func approvedSeparateHomeAcceptance() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMARCHY_HOME_DISK_ACCEPTANCE"]!)
        let run = file.deletingLastPathComponent().resolvingSymlinksInPath()
        guard run.deletingLastPathComponent() == project.appendingPathComponent(".build/home-disk-poc"),
              let runID = UUID(uuidString: run.lastPathComponent), file.lastPathComponent == "approval.json" else { throw refusal("Approval must be in a fresh private test UUID area.") }
        struct Approval: Decodable { let schemaVersion: Int; let approvedDisposableVMs: Bool; let runID: UUID; let factory: String; let kit: String; let lock: String; let diagnosticOnly: Bool? }
        let approval = try JSONDecoder().decode(Approval.self, from: PrivateFiles.read(file))
        guard approval.schemaVersion == 1, approval.approvedDisposableVMs, approval.runID == runID else { throw refusal("Disposable VM approval missing.") }
        try PrivateFiles.directory(run)
        let support = run.appendingPathComponent("support")
        let diagnostic = approval.diagnosticOnly == true
        if !diagnostic {
            guard !FileManager.default.fileExists(atPath: support.path) else { throw refusal("Prior test storage is preserved; use a new run UUID.") }
            try PrivateFiles.directory(support, create: true)
        } else { try PrivateFiles.directory(support) }
        let vault = MemoryOwnerVault()
        let defaults = OwnerDefaultsStore(applicationSupport: support, vault: vault)
        if !diagnostic { _ = try defaults.save(configuration: OwnerConfiguration(username: "homepoc", fullName: "Disposable Home Test", hostnamePrefix: "homepoc", timezone: "UTC"), password: Data(UUID().uuidString.utf8)) }
        let kit = TryOmarchyKit(bundleURL: URL(fileURLWithPath: approval.kit))
        let lock = try Data(contentsOf: URL(fileURLWithPath: approval.lock))
        guard KitVerifier.sha256(lock) == RuntimePin.lockSHA256 else { throw refusal("Runtime pin changed.") }
        let registry = try RegistryStore(applicationSupport: support)
        let existing = try registry.load()
        if diagnostic {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let ledger = try decoder.decode([VMProfile].self, from: PrivateFiles.read(run.appendingPathComponent("profiles.json")))
            guard existing.count == 1, ledger.count == 1, existing[0].id == ledger[0].id,
                  existing[0].homeDisk == ledger[0].homeDisk, existing[0].ownerSetup == ledger[0].ownerSetup,
                  existing[0].name == "Home POC Source", existing[0].ownerSetup?.configuration.username == "homepoc",
                  try ManagedOwnerStorage(root: ManagerStorage(applicationSupport: support).root(for: existing[0])).completed(existing[0]) else { throw refusal("Diagnostics require this run's exact completed disposable source.") }
        } else { guard existing.isEmpty else { throw refusal("Test registry must be empty.") } }
        let runtime = TryOmarchyRuntime(managedKit: kit, lockData: lock, applicationSupport: support, ownerSecrets: vault)
        let manager = VMManager(runtime: runtime, profiles: existing, applicationSupport: support, enforcePOCPolicy: true,
            registry: registry, sshProbe: ManagedSSHProbe(), ownerDefaults: defaults)
        let catalog = try FactoryCatalog(applicationSupport: support, kit: kit, lockData: lock)
        await manager.installFactoryCatalog(catalog)
        let service = GuestCommandService(manager: manager, applicationSupport: support)
        let storage = ManagerStorage(applicationSupport: support)
        var created: [UUID] = existing.map(\.id)
        let factory: FactoryIdentity
        func progress(_ phase: String) async throws {
            let snapshots = await manager.snapshots()
            let object: [String: Any] = ["phase": phase, "runID": runID.uuidString, "guests": snapshots.map {
                ["id": $0.id.uuidString, "state": $0.state.label, "active": $0.sessionID != nil,
                 "ssh": $0.sshReadiness.label, "owner": $0.ownerSetupReadiness.label,
                 "failure": $0.lastFailure?.message ?? ""] as [String: Any]
            }]
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), name: "progress.json", in: run)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try PrivateFiles.write(encoder.encode(snapshots.map(\.profile)), name: "profiles.json", in: run)
            let events = await manager.eventLog().map { ["vmID": $0.vmID.uuidString, "sessionID": $0.sessionID.uuidString, "text": $0.text] }
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]), name: "events.json", in: run)
        }
        func command(_ args: [String]) async throws -> GuestCommandResponse {
            let request = try #require(GuestCLIInvocation.parse(args).request)
            let response = await service.execute(request)
            guard response.ok else { throw refusal(response.error?.message ?? "CLI request failed.") }
            return response
        }
        func create(_ name: String, _ options: [String]) async throws -> UUID {
            let response = try await command(["create", name, "--factory", factory.selector, "--memory", "4GiB", "--cpus", "4", "--clipboard", "off", "--guest-touch-id", "off"] + options)
            let id = try #require(response.guest?.id); created.append(id)
            try await progress("created-" + name)
            return id
        }
        func boot(_ id: UUID, _ phase: String) async throws -> VMSnapshot {
            try await manager.start(id, launchIntent: .background)
            let deadline = ContinuousClock.now.advanced(by: .seconds(900))
            while ContinuousClock.now < deadline {
                try await progress(phase)
                let snapshot = try #require(await manager.snapshots().first(where: { $0.id == id }))
                if snapshot.sessionID == nil { throw refusal(snapshot.lastFailure?.message ?? "Guest exited before readiness.") }
                if snapshot.state == .running, case .ready = snapshot.sshReadiness, snapshot.ownerSetupReadiness == .configured { return snapshot }
                try await Task.sleep(for: .seconds(2))
            }
            throw refusal("Guest owner/SSH readiness timed out; inspect the disposable root.")
        }
        func stop(_ id: UUID) async throws {
            guard let session = await manager.snapshots().first(where: { $0.id == id })?.sessionID else { return }
            await manager.shutDown(id)
            for _ in 0..<120 {
                if await manager.snapshots().first(where: { $0.id == id })?.sessionID == nil {
                    guard await manager.eventLog().contains(where: { $0.vmID == id && $0.sessionID == session && $0.text == "Exited (0)" }) else { throw refusal("Shutdown did not record a clean matching exit.") }
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            try await manager.forceStop(id, confirmed: true)
            for _ in 0..<30 {
                if await manager.snapshots().first(where: { $0.id == id })?.sessionID == nil { throw refusal("Disposable guest required a forced stop.") }
                try await Task.sleep(for: .seconds(1))
            }
            throw refusal("Disposable guest still owns its runtime handle after termination.")
        }
        func guest(_ snapshot: VMSnapshot, _ mode: String, system: Int, home: Int) async throws {
            let profile = snapshot.profile, sessionID = try #require(snapshot.sessionID)
            let ssh = ManagedSSHStorage(root: storage.root(for: profile))
            let args = ssh.arguments(profile: profile, user: "homepoc")
            let identity = try await Task.detached { try Self.ssh(args, input: nil) }.value
            let report = try JSONDecoder().decode(ManagedSSHProbe.Identity.self, from: identity)
            guard report.vmID == profile.id, report.sessionToken == sessionID, report.user == "homepoc", report.uid == 1000 else { throw refusal("Guest identity changed.") }
            let code = try Data(contentsOf: project.appendingPathComponent("Scripts/home_disk_acceptance_guest.py"))
            let diskID = profile.homeDisk?.id.uuidString ?? "single"
            let remote = "/usr/bin/python3 -I - \(mode) \(runID.uuidString) \(diskID) \(system) \(home)"
            let output = try await Task.detached { try Self.ssh(Array(args.dropLast()) + [remote], input: code) }.value
            try PrivateFiles.write(output, name: "guest-\(mode)-\(profile.id.uuidString).json", in: run)
            try await progress(mode)
        }
        // The normal import verifier checks every file and source contract.
        try await progress("importing-factory")
        factory = diagnostic ? try catalog.identity(for: existing[0].factory!.selector) : try await manager.importFactory(URL(fileURLWithPath: approval.factory))
        do {
            if diagnostic {
                try await guest(try await boot(existing[0].id, "diagnostic-reboot"), "diagnostic", system: 64, home: 64)
                try await stop(existing[0].id)
                try await progress("diagnostic-complete-guests-stopped")
                return
            }
            let source = try await create("Home POC Source", [])
            let first = try await boot(source, "source-first-boot")
            guard first.profile.diskGiB == 64, first.profile.homeDisk?.sizeGiB == 64 else { throw refusal("Creation defaults differ.") }
            try await guest(first, "seed", system: 64, home: 64)
            try await stop(source)
            let replacement = try await create("Home POC Replacement", ["--reuse-home-from", source.uuidString, "--system-disk", "80GiB"])
            do { _ = try await manager.deletionRequest(source); throw refusal("Pending clone did not protect its source.") }
            catch let error as VMFailure where error.code == "home-disk-unavailable" { }
            let second = try await boot(replacement, "replacement-first-boot")
            try await guest(second, "verify-replacement", system: 80, home: 64)
            try await guest(second, "modify", system: 80, home: 64)
            var original = stat(), clone = stat()
            guard lstat(storage.homeImage(first.profile).path, &original) == 0,
                  lstat(storage.homeImage(second.profile).path, &clone) == 0,
                  original.st_ino != clone.st_ino else { throw refusal("Home files are not independent.") }
            try await stop(replacement)
            _ = try await command(["update", replacement.uuidString, "--system-disk", "96GiB", "--home-disk", "80GiB"])
            try await guest(try await boot(replacement, "replacement-grown-reboot"), "verify-modified", system: 96, home: 80)
            try await stop(replacement)
            try await guest(try await boot(source, "original-rollback-reboot"), "verify-source", system: 64, home: 64)
            try await stop(source)
            let single = try await create("Home POC Single Disk", ["--separate-home", "off", "--system-disk", "64GiB"])
            try await guest(try await boot(single, "single-disk-first-boot"), "single-seed", system: 64, home: 0)
            try await stop(single)
            try await guest(try await boot(single, "single-disk-reboot"), "single-verify", system: 64, home: 0)
            try await stop(single)
            try await progress("passed-all-guests-stopped")
        } catch {
            for id in created { do { try await stop(id) } catch { Issue.record("Disposable cleanup requires inspection: \(id)") } }
            try await progress("failed-guests-preserved")
            throw error
        }
    }

    private func refusal(_ message: String) -> VMFailure { VMFailure(code: "home-poc-failed", message: message) }

    private static func ssh(_ arguments: [String], input: Data?) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); p.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 1); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0, output.count <= 65_536 else {
            throw VMFailure(code: "home-poc-ssh", message: "Disposable guest check failed: " + String(decoding: diagnostic.prefix(2048), as: UTF8.self))
        }
        return output
    }
}
