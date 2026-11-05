import Foundation

public struct FactoryDockerAdmission: Codable, Equatable, Sendable, CustomStringConvertible {
    public let context: String
    let endpoint: String
    let engineSHA256: String
    let toolSHA256: String
    public var description: String { "FactoryDockerAdmission(redacted)" }
}
public struct FactoryDockerClient: Sendable {
    let executable: URL
    let pin: ProvisioningExecutablePin
    let runner: any FactoryBuildProcessRunning
    let home: URL
    public init(executable: URL, home: URL, runner: any FactoryBuildProcessRunning) throws {
        self.executable = executable; pin = try .init(executable); self.home = home; self.runner = runner
    }
    var environment: [String: String] { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": home.path, "LC_ALL": "C", "DOCKER_CLI_HINTS": "false"] }
    func command(_ arguments: [String], directory: URL, timeout: Int = 30, stream: Bool = false, output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Data {
        _ = try pin.verify()
        let result = try await runner.run(.init(executable: executable, arguments: arguments, directory: directory, environment: environment, timeoutSeconds: timeout, streaming: stream), output: output)
        _ = try pin.verify()
        guard result.status == 0 else { throw FactoryBuildFailure.commandFailed }
        return result.output
    }
    public func inspect() async throws -> FactoryDockerAdmission {
        let contextData = try await command(["context", "show"], directory: home)
        guard let context = String(data: contextData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              matches(context, "[A-Za-z0-9][A-Za-z0-9_.-]{0,63}") else { throw FactoryBuildFailure.dockerUnavailable }
        let data = try await command(["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"], directory: home)
        guard case .string(let endpoint) = try PlainDataParser.parse(data, format: .json), endpoint.hasPrefix("unix:///"),
              endpoint.utf8.count <= 1024, !endpoint.contains("\n"), !endpoint.contains("\0"),
              URL(string: endpoint)?.user == nil else { throw FactoryBuildFailure.remoteEngine }
        return try await identity(context: context, endpoint: endpoint)
    }
    private func identity(context: String, endpoint: String) async throws -> FactoryDockerAdmission {
        guard endpoint.hasPrefix("unix:///"), endpoint.utf8.count <= 1024,
              !endpoint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              matches(context, "[A-Za-z0-9][A-Za-z0-9_.-]{0,63}") else { throw FactoryBuildFailure.remoteEngine }
        let data = try await command(["--host", endpoint, "info", "--format", "{\"architecture\":{{json .Architecture}},\"os\":{{json .OSType}},\"id\":{{json .ID}}}"], directory: home)
        guard case .object(let doc) = try PlainDataParser.parse(data, format: .json), Set(doc.keys) == ["architecture", "os", "id"],
              doc["os"] == .string("linux"), [.string("arm64"), .string("aarch64")].contains(doc["architecture"]),
              case .string(let id) = doc["id"], !id.isEmpty, id.utf8.count <= 256 else { throw FactoryBuildFailure.wrongArchitecture }
        return .init(context: context, endpoint: endpoint, engineSHA256: digest(try canonicalData(doc)), toolSHA256: pin.sha256)
    }
    public func revalidate(_ admission: FactoryDockerAdmission) async throws {
        guard pin.sha256 == admission.toolSHA256 else { throw FactoryBuildFailure.engineChanged }
        let current = try await identity(context: admission.context, endpoint: admission.endpoint)
        guard current.engineSHA256 == admission.engineSHA256 else { throw FactoryBuildFailure.engineChanged }
    }
    func run(_ admission: FactoryDockerAdmission, _ arguments: [String], directory: URL, timeout: Int = 30, stream: Bool = false, output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Data {
        try await revalidate(admission)
        return try await command(["--host", admission.endpoint] + arguments, directory: directory, timeout: timeout, stream: stream, output: output)
    }
}

public protocol FactoryBuildDownloading: Sendable {
    func download(_ input: FactoryRecipe.Download, to destination: URL) async throws
}
private final class FactoryDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let host: String
    private let lock = NSLock()
    private var redirects = 0
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = lock.withLock { redirects += 1; return redirects <= 3 }
        completionHandler(allowed && request.url?.scheme == "https" && request.url?.host == host && request.url?.user == nil && request.url?.password == nil && request.url?.port == nil && task.countOfBytesReceived < 256 * 1024 * 1024 ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 256 * 1024 * 1024 || totalBytesExpectedToWrite > 256 * 1024 * 1024 { downloadTask.cancel() }
    }
}
public struct FactoryBuildDownloader: FactoryBuildDownloading {
    public init() {}
    public func download(_ input: FactoryRecipe.Download, to destination: URL) async throws {
        guard input.url.scheme == "https", ["codeload.github.com", "nodejs.org"].contains(input.url.host), input.url.user == nil,
              input.url.password == nil, input.url.port == nil else { throw FactoryBuildFailure.downloadFailed }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 900
        let delegate = FactoryDownloadDelegate(host: input.url.host!)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: input.url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == input.url.host,
              (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256 * 1024 * 1024,
              !FileManager.default.fileExists(atPath: destination.path) else { throw FactoryBuildFailure.downloadFailed }
        try FileManager.default.copyItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        guard try factoryFileHash(destination) == input.sha256 else { throw FactoryBuildFailure.downloadFailed }
    }
}
