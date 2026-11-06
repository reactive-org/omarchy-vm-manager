import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

private final class GETLedger: @unchecked Sendable {
    let lock = NSLock()
    private var values: [URLRequest] = []
    func add(_ request: URLRequest) { lock.withLock { values.append(request) } }
    func reset() { lock.withLock { values = [] } }
    var requests: [URLRequest] { lock.withLock { values } }
}
private final class ThemeGETProtocol: URLProtocol, @unchecked Sendable {
    static let ledger = GETLedger()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.ledger.add(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>SYNTHETIC ONLY</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct ThemeToolFiles: ProvisioningToolFiles {
    var available = true
    func executable(_ path: String) -> ProvisioningExecutable? {
        available && path == "/fixture/bin/gh" ? .init(identity: .init(path: path, fingerprint: "synthetic"), resolvedPath: path) : nil
    }
    func directory(_ path: String) -> ProvisioningInstallation? { nil }
}
private actor ThemeProbe: ProvisioningToolProbing {
    var calls: [ProvisioningProbeRequest] = []
    let reply: ProvisioningProbeResult
    init(_ reply: ProvisioningProbeResult) { self.reply = reply }
    func run(_ request: ProvisioningProbeRequest) -> ProvisioningProbeResult { calls.append(request); return reply }
}
@Suite("Theme GET and GitHub CLI adapters — socket-free fakes", .serialized) struct ProvisioningThemeNetworkTests {
    @Test func repositoryValidationUsesGETWithoutCookiesCredentialsOrCaching() async throws {
        ThemeGETProtocol.ledger.reset()
        let http = ProvisioningThemeHTTP(configuration: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ThemeGETProtocol.self]; return config
        })
        let response = try await http.get(URL(string: "https://github.com/example/omarchy-fixture-theme")!, body: false)
        #expect(response.status == 200 && response.data.isEmpty)
        let request = try #require(ThemeGETProtocol.ledger.requests.first)
        #expect(request.httpMethod == "GET" && request.cachePolicy == .reloadIgnoringLocalCacheData && !request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
        let catalogue = try await http.get(ThemeSelection.catalogueURL, body: true)
        #expect(String(decoding: catalogue.data, as: UTF8.self).contains("SYNTHETIC ONLY"))
        let count = ThemeGETProtocol.ledger.requests.count
        await #expect(throws: ThemeSelectionFailure.inaccessible) { _ = try await http.get(URL(string: "http://127.0.0.1/secret")!, body: false) }
        #expect(ThemeGETProtocol.ledger.requests.count == count)
    }
    @Test func redirectsStayOnTheApprovedHostStripCredentialsAndAreBounded() throws {
        let policy = ThemeRedirectPolicy(origin: "github.com")
        var request = URLRequest(url: URL(string: "https://github.com/example/renamed-theme")!)
        request.setValue("SYNTHETIC-ONLY", forHTTPHeaderField: "Authorization"); request.setValue("fixture", forHTTPHeaderField: "Cookie")
        let clean = try #require(policy.admit(request))
        #expect(clean.httpMethod == "GET" && clean.value(forHTTPHeaderField: "Authorization") == nil && clean.value(forHTTPHeaderField: "Cookie") == nil)
        for target in ["https://example.com/a/b", "https://github.com/login", "http://github.com/example/theme", "https://github.com/example/theme?token=x"] {
            #expect(ThemeRedirectPolicy(origin: "github.com").admit(URLRequest(url: URL(string: target)!)) == nil)
        }
        for _ in 0..<4 { #expect(policy.admit(request) != nil) }
        #expect(policy.admit(request) == nil)
        #expect(ThemeRedirectPolicy(origin: "raw.githubusercontent.com").admit(URLRequest(url: URL(string: "https://raw.githubusercontent.com/other/repo/file")!)) == nil)
    }
    @Test func starLookupUsesOnlyTheExistingGhReadOnlyProbeAndStrictMetadata() async throws {
        let reply = ProvisioningProbeResult(output: Data(#"{"data":{"r0":{"stargazerCount":12},"r1":null},"errors":[{"type":"NOT_FOUND","path":["r1"]}]}"#.utf8))
        let probe = ThemeProbe(reply)
        let stars = ProvisioningThemeStars(files: ThemeToolFiles(), probe: probe, directories: ["/fixture/bin"], home: "/private/tmp/synthetic-home")
        let urls = ["https://github.com/example/alpha-theme", "https://github.com/example/beta-theme"]
        #expect(try await stars.counts(for: urls) == [urls[0]: 12])
        let request = try #require(await probe.calls.first)
        #expect(request.arguments.prefix(4) == ["api", "--hostname", "github.com", "graphql"])
        #expect(request.arguments.last?.contains("repository(owner:") == true && request.timeout == 30 && request.outputLimit == 256 * 1024)
        #expect(request.environment["GH_PROMPT_DISABLED"] == "1" && request.environment["GH_TOKEN"] == nil && request.environment["GITHUB_TOKEN"] == nil)
        await #expect(throws: ThemeSelectionFailure.starsUnavailable) { _ = try await ProvisioningThemeStars(files: ThemeToolFiles(available: false), probe: probe, directories: ["/fixture/bin"]).counts(for: urls) }
        #expect(await probe.calls.count == 1)
    }
    @Test(arguments: ["missing", "null", "boolean", "negative", "unknown-alias", "unexpected-error", "timeout", "nonzero"])
    func incompleteOrUntrustedStarRepliesCannotChooseATheme(kind: String) async throws {
        let json: String
        switch kind {
        case "missing": json = #"{"data":{}}"#
        case "null": json = #"{"data":{"r0":null}}"#
        case "boolean": json = #"{"data":{"r0":{"stargazerCount":true}}}"#
        case "negative": json = #"{"data":{"r0":{"stargazerCount":-1}}}"#
        case "unknown-alias": json = #"{"data":{"r0":null},"errors":[{"type":"NOT_FOUND","path":["r1"]}]}"#
        case "unexpected-error": json = #"{"data":{"r0":null},"errors":[{"type":"FORBIDDEN","path":["r0"]}]}"#
        default: json = #"{"data":{"r0":{"stargazerCount":12}}}"#
        }
        let reply = kind == "timeout" ? ProvisioningProbeResult.failed(.timeout) : ProvisioningProbeResult(status: kind == "nonzero" ? 1 : 0, output: Data(json.utf8))
        let stars = ProvisioningThemeStars(files: ThemeToolFiles(), probe: ThemeProbe(reply), directories: ["/fixture/bin"])
        await #expect(throws: ThemeSelectionFailure.starsUnavailable) { _ = try await stars.counts(for: ["https://github.com/example/theme"]) }
    }
}
