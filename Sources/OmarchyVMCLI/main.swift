import Foundation
import OmarchyVMManagerCore

func output(_ value: GuestCommandResponse) -> Never {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    FileHandle.standardOutput.write(data + Data([10]))
    exit(value.ok ? 0 : (value.error?.code == "wait-timeout" ? 124 : 1))
}
func managerApp() throws -> URL {
    guard let executable = Bundle.main.executableURL else { throw VMFailure(code: "app-required", message: "The bundled CLI is required.") }
    let app = try AppChannel.current.enclosingApp(for: executable)
    guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/OmarchyVMManager").path) else { throw VMFailure(code: "app-required", message: "The manager app is unavailable.") }
    return app
}

var requestID = UUID()
do {
    if Array(CommandLine.arguments.dropFirst()) == ["--version"] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "commandProtocol": 1, "appChannel": AppChannel.current.rawValue], options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10])); exit(0)
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "factory-build", arguments.contains("--help") || arguments.contains("-h") { print(FactoryBuildCLI.help); exit(0) }
    if let (factory, follow) = try FactoryBuildCLI.parse(arguments) {
        _ = try managerApp()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        let client = ManagerCommandClient(endpoint: ManagerCommandEndpoint(applicationSupport: support))
        var request = GuestCommandRequest(command: .factoryBuild); request.factoryBuild = factory
        if factory.operation != .logs { output(try client.send(request)) }
        var display = ProvisioningTerminalDisplay(), cursor: UInt64 = 0
        var pages = 0
        repeat {
            request.factoryBuild?.cursor = cursor
            let response = try client.send(request)
            guard response.ok, let reply = response.factoryBuild else { output(response) }
            if reply.reset == true { display.reset(); FileHandle.standardOutput.write(Data("\r\n[Earlier build output is unavailable.]\r\n".utf8)) }
            if let bytes = reply.bytes { FileHandle.standardOutput.write(display.consume(bytes)) }
            cursor = reply.sequence ?? cursor; pages += 1
            if !follow && pages >= 4 { exit(0) } // At most the retained 256 KiB snapshot.
            if reply.bytes?.isEmpty != false && (!follow || reply.jobs?.first?.active != true) { exit(0) }
            if follow { try await Task.sleep(for: .milliseconds(200)) }
        } while !Task.isCancelled
        exit(0)
    }
    if !arguments.contains("--help"), !arguments.contains("-h"),
       let tools = try ProvisioningToolsInvocation.parse(arguments) {
        let report = try await HomebrewProvisioningDependencies(configuration: .host(overrides: tools.overrides)).inspect()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
        exit(0)
    }
    if !arguments.contains("--help"), !arguments.contains("-h"), let setup = try ProvisioningSetupCLI.parse(arguments) {
        let layout = ProvisioningPackageLayout(contents: try managerApp().appendingPathComponent("Contents"))
        func printSetup(_ data: Data) { FileHandle.standardOutput.write(data + Data([10])) }
        switch setup {
        case .presets:
            printSetup(try JSONSerialization.data(withJSONObject: ["version": 1, "presets": BundledProvisioning.presets, "executionEnabled": BundledProvisioning.executionEnabled], options: [.sortedKeys])); exit(0)
        case .plan(let repository): printSetup(try BundledProvisioning.plan(repository: repository, layout: layout)); exit(0)
        case .preset(let name): printSetup(try BundledProvisioning.plan(preset: name, layout: layout)); exit(0)
        default: break
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        let client = ProvisioningExternalClient(endpoint: ManagerCommandEndpoint(applicationSupport: support))
        switch setup {
        case .attach(let id, let interactive):
            try await ProvisioningCLITerminal.attach(client: client, workflowID: id, interactive: interactive); exit(0)
        case .prepareCreation(let id, let source):
            let reply = try await client.request(.prepareCreation, previewID: id, source: source)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .creation(let id):
            let reply = try await client.request(.creation, previewID: id)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .createPreview(let vm, let id, let source):
            let reply = try await client.request(.previewCreate, previewID: id, vmID: vm, source: source)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .preview(let id):
            let reply = try await client.request(.preview, previewID: id)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .taskSource(let id, let name, let offset):
            let reply = try await client.request(.taskSource, previewID: id, taskName: name, offset: offset)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .prepareApply(let id):
            let reply = try await client.request(.prepareApply, previewID: id)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .apply(let id, let consent):
            let reply = try await client.request(.apply, previewID: id, consent: consent)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .prepareAction(let id, let action, let reviewID):
            let reply = try await client.request(.prepareAction, workflowID: id, action: action, actionReviewID: reviewID)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .performAction(let id, let consent):
            let reply = try await client.request(.performAction, workflowID: id, actionConsent: consent)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        case .events(let id):
            var prior: UInt64?
            while !Task.isCancelled {
                let reply = try await client.request(.status, workflowID: id)
                guard reply.failure == nil, let row = reply.workflows?.first else { throw VMFailure(code: "setup-unavailable", message: "The workflow is unavailable. No setup was submitted.") }
                if prior != row.sequence { printSetup(try JSONEncoder().encode(reply)); prior = row.sequence }
                if !row.canCancel { await client.close(); exit(0) }
                try await Task.sleep(for: .milliseconds(250))
            }
            await client.close(); exit(0)
        default:
            let operation: ProvisioningExternalOperation
            let id: UUID?
            switch setup {
            case .capabilities: operation = .capabilities; id = nil
            case .list: operation = .list; id = nil
            case .status(let value): operation = .status; id = value
            case .cancel(let value): operation = .cancel; id = value
            default: throw VMFailure(code: "usage", message: "Unsupported setup command.")
            }
            let reply = try await client.request(operation, workflowID: id)
            printSetup(try JSONEncoder().encode(reply)); await client.close(); exit(reply.failure == nil ? 0 : 1)
        }
    }
    let parsed = try GuestCLIInvocation.parse(Array(CommandLine.arguments.dropFirst()))
    if parsed.help { FileHandle.standardOutput.write(Data((GuestCLIInvocation.usage.replacingOccurrences(of: "omarchy-vm", with: AppChannel.current.cliName) + "\n").utf8)); exit(0) }
    _ = try managerApp()
    let request = parsed.request!; requestID = request.requestID
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    let client = ManagerCommandClient(endpoint: ManagerCommandEndpoint(applicationSupport: support))
    do { output(try client.send(request)) }
    catch let failure as VMFailure where failure.code == "manager-unavailable" {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", try managerApp().path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VMFailure(code: "manager-unavailable", message: "The manager could not be opened. Open it manually and retry.") }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            do { output(try client.send(request)) }
            catch let error as VMFailure where error.code == "manager-unavailable" { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw VMFailure(code: "manager-unavailable", message: "The manager did not become available. Open it and check its Runtime and registry status.")
    }
} catch {
    let failure = error as? VMFailure ?? VMFailure(code: "cli-failed", message: "The command could not finish.")
    output(GuestCommandResponse(requestID: requestID, ok: false, error: GuestCommandFailure(code: failure.code, message: failure.message)))
}
