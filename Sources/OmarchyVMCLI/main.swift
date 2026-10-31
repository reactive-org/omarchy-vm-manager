import Foundation
import OmarchyVMManagerCore

func output(_ value: GuestCommandResponse) -> Never {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    FileHandle.standardOutput.write(data + Data([10]))
    exit(value.ok ? 0 : (value.error?.code == "wait-timeout" ? 124 : 1))
}
func managerApp() throws -> URL {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), executable.deletingLastPathComponent().lastPathComponent == "MacOS" else {
        throw VMFailure(code: "app-required", message: "Run the bundled CLI or bin/omarchy-vm after make app.")
    }
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/OmarchyVMManager").path) else { throw VMFailure(code: "app-required", message: "The manager app is unavailable.") }
    return app
}

var requestID = UUID()
do {
    if Array(CommandLine.arguments.dropFirst()) == ["--version"] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "commandProtocol": 1], options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10])); exit(0)
    }
    let parsed = try GuestCLIInvocation.parse(Array(CommandLine.arguments.dropFirst()))
    if parsed.help { FileHandle.standardOutput.write(Data((GuestCLIInvocation.usage + "\n").utf8)); exit(0) }
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
            catch let error as VMFailure where error.code == "manager-unavailable" { Thread.sleep(forTimeInterval: 0.2) }
        }
        throw VMFailure(code: "manager-unavailable", message: "The manager did not become available. Open it and check its Runtime and registry status.")
    }
} catch {
    let failure = error as? VMFailure ?? VMFailure(code: "cli-failed", message: "The command could not finish.")
    output(GuestCommandResponse(requestID: requestID, ok: false, error: GuestCommandFailure(code: failure.code, message: failure.message)))
}
