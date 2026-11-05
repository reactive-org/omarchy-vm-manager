import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Manual app release checks — no VMs or network")
struct AppReleaseCheckerTests {
    private func release(_ tag: String, draft: Bool = false, app: Bool = true, state: String = "uploaded", flavor: String = "notarized", channel: AppChannel = .development, prerelease: Bool? = nil) -> [String: Any] {
        let prefix = channel == .development ? "Omarchy-VM-Manager-Dev" : "Omarchy-VM-Manager"
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease ?? tag.contains("-"),
         "html_url": "https://untrusted.example/ignored",
         "assets": [["name": app ? "\(prefix)-\(tag)-macOS-arm64-\(flavor).zip" : "TryOmarchyKit.zip", "state": state]]]
    }

    private func checker(_ releases: [[String: Any]], status: Int = 200, headers: [String: String] = [:], channel: AppChannel = .development) throws -> AppReleaseChecker {
        let data = try JSONSerialization.data(withJSONObject: releases)
        return AppReleaseChecker(channel: channel) { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    @Test("semantic precedence includes numeric prereleases, stable releases and build metadata")
    func versionOrdering() throws {
        let tags = ["v0.9.0", "v0.10.0-dev.2", "v0.10.0-dev.10", "v0.10.0-rc.1", "v0.10.0", "v0.10.1-dev.1", "v1.0.0"]
        let versions = try tags.map { try #require(AppReleaseVersion($0)) }
        for (lower, higher) in zip(versions, versions.dropFirst()) { #expect(lower < higher) }
        #expect(AppReleaseVersion("v0.10.0-dev.1+build.2") == AppReleaseVersion("0.10.0-dev.1+other"))
        #expect(AppReleaseVersion("1.0.0-1")! < AppReleaseVersion("1.0.0-alpha")!)
        #expect(AppReleaseVersion("1.0.0-alpha")! < AppReleaseVersion("1.0.0-alpha.1")!)
        #expect(AppReleaseVersion("1.0.0-dev.99999999999999999999")! < AppReleaseVersion("1.0.0-dev.100000000000000000000")!)
    }

    @Test("unknown and malformed tags cannot become app versions")
    func invalidVersions() {
        for tag in ["", "development", "runtime-kit-abc", "v1.2", "v01.2.3", "v1.02.3", "v1.2.3-dev.01", "v1.2.3-", "v1.2.3+", "v1.2.3/other", "v1.2.3\n", "v1.2.3-β", "v99999999999999999999.0.0"] {
            #expect(AppReleaseVersion(tag) == nil, "Rejected \(tag)")
        }
    }

    @Test("selects the highest app version regardless of order, ignoring drafts, runtime and incomplete releases")
    func selection() async throws {
        let checker = try checker([
            release("v0.10.0-dev.2"), release("runtime-kit-abcdef"), release("v20.0.0-dev.1", app: false),
            release("v30.0.0-dev.1", draft: true), release("v40.0.0-dev.1", state: "new"),
            release("v50.0.0-dev.1", flavor: "development"), release("v0.10.0-dev.10"), release("v0.9.0"), release("v0.10.0-dev.3")
        ])
        let result = try await checker.check(installedTag: "v0.10.0-dev.2", shortVersion: "0.10.0")
        guard case .available(let release) = result else { Issue.record("Expected an update"); return }
        #expect(release.tag == "v0.10.0-dev.10")
        #expect(release.url.absoluteString == "https://github.com/reactive-org/omarchy-vm-manager/releases/tag/v0.10.0-dev.10")
    }

    @Test("stable updates stay stable, including the historical stable app with a prerelease tag")
    func currentVersions() async throws {
        let checker = try checker([release("v0.10.0", channel: .stable), release("v20.0.0-dev.10"),
            release("v30.0.0", channel: .stable, prerelease: true), release("v40.0.0", channel: .development)], channel: .stable)
        #expect(try await checker.check(installedTag: "v0.10.0", shortVersion: "0.10.0") == .upToDate)
        #expect(try await checker.check(installedTag: "v0.11.0-dev.1", shortVersion: "0.11.0") == .upToDate)
        guard case .available(let release) = try await checker.check(installedTag: "v0.10.0-dev.10", shortVersion: "0.10.0") else {
            Issue.record("Stable release should supersede prerelease"); return
        }
        #expect(release.tag == "v0.10.0")
        let samePrerelease = try self.checker([self.release("v0.10.0-dev.10")])
        #expect(try await samePrerelease.check(installedTag: "v0.10.0-dev.10", shortVersion: "0.10.0") == .upToDate)
    }

    @Test("Dev never offers stable, legacy stable-identity prereleases, or incorrectly labelled releases")
    func devIsolation() async throws {
        let checker = try checker([release("v9.0.0", channel: .stable), release("v9.0.0-dev.1", channel: .stable),
            release("v8.0.0-dev.1", prerelease: false), release("v7.0.0-rc.1"), release("v0.10.0-dev.2")])
        guard case .available(let update) = try await checker.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") else {
            Issue.record("Expected the Dev download only"); return
        }
        #expect(update.tag == "v0.10.0-dev.2")
    }

    @Test("no eligible app releases is distinct from up to date")
    func noReleases() async throws {
        for releases in [[], [release("runtime-kit-abcdef")], [release("v0.10.0-dev.2", app: false)]] {
            let checker = try checker(releases)
            #expect(try await checker.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") == .noReleases)
        }
    }

    @Test("missing or mismatched local identity never sends a request or claims up to date")
    func missingIdentity() async {
        let checker = AppReleaseChecker { _ in Issue.record("Unexpected network request"); throw URLError(.badURL) }
        for (tag, version): (String?, String?) in [(nil, "0.10.0"), ("v0.10.0-dev.1", nil), ("v0.9.0-dev.1", "0.10.0"), ("development", "0.10.0")] {
            await #expect(throws: AppReleaseCheckError.unknownInstalledVersion) {
                try await checker.check(installedTag: tag, shortVersion: version)
            }
        }
    }

    @Test("HTTP, malformed data, timeout and offline failures are actionable")
    func failures() async throws {
        for (status, headers, expected): (Int, [String: String], AppReleaseCheckError) in [
            (429, [:], .rateLimited), (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
            (403, ["Retry-After": "60"], .rateLimited), (403, [:], .server(403)), (500, [:], .server(500)), (404, [:], .server(404))
        ] {
            let checker = try checker([], status: status, headers: headers)
            await #expect(throws: expected) { try await checker.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") }
        }
        for data in [Data("not json".utf8), Data("{}".utf8), Data("[{\"tag_name\":12}]".utf8)] {
            let checker = AppReleaseChecker { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            await #expect(throws: AppReleaseCheckError.invalidResponse) { try await checker.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") }
        }
        for (code, expected): (URLError.Code, AppReleaseCheckError) in [(.timedOut, .timedOut), (.notConnectedToInternet, .network)] {
            let checker = AppReleaseChecker { _ in throw URLError(code) }
            await #expect(throws: expected) { try await checker.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") }
        }
        let cancelled = AppReleaseChecker { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await cancelled.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0") }
    }

    @Test("pagination uses fixed GitHub requests and includes later app releases")
    func pagination() async throws {
        let first = try JSONSerialization.data(withJSONObject: [release("runtime-kit-abcdef")])
        let second = try JSONSerialization.data(withJSONObject: [release("v0.10.0-dev.10")])
        let checker = AppReleaseChecker(channel: .development) { request in
            #expect(request.url?.host == "api.github.com")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.timeoutInterval == 15)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let firstPage = page == "1"
            #expect(firstPage || page == "2")
            return (firstPage ? first : second, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: firstPage ? ["Link": "<https://untrusted.example/>; rel=\"next\""] : [:])!)
        }
        guard case .available(let release) = try await checker.check(installedTag: "v0.10.0-dev.2", shortVersion: "0.10.0") else {
            Issue.record("Expected later-page release"); return
        }
        #expect(release.tag == "v0.10.0-dev.10")
        let endless = try self.checker([], headers: ["Link": "<next>; rel=\"next\""])
        await #expect(throws: AppReleaseCheckError.tooManyReleases) {
            try await endless.check(installedTag: "v0.10.0-dev.1", shortVersion: "0.10.0")
        }
    }
}
