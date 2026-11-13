import Darwin
import Foundation
import Testing
@testable import DevVMProvisioningCore
@testable import OmarchyVMManagerCore

private let themeFixtureURL = "https://github.com/example/omarchy-fixture-theme"
private actor AppearanceHTTP: ThemeHTTPFetching {
    var calls: [(URL, Bool)] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func get(_ url: URL, body: Bool) -> ThemeHTTPResponse {
        calls.append((url, body))
        let data = Data("<figure class='themes__theme'><a href='\(themeFixtureURL)'>Fixture</a></figure>".utf8)
        return .init(status: status, url: url, data: body ? data : Data())
    }
}
private struct AppearanceStars: ThemeStarProviding {
    func counts(for repositories: [String]) -> [String: Int] { Dictionary(uniqueKeysWithValues: repositories.map { ($0, 42) }) }
}
@Suite("Theme and layout selection — fake HTTP/local fixtures") struct ProvisioningSelectionAppearanceTests {
    @Test func repositoryGETAndSelectedLayoutAreFrozenWithoutMutatingTheSource() async throws {
        let http = AppearanceHTTP(), resolver = ThemeResolver(http: http, stars: AppearanceStars())
        let f = try await CreationFixture(themeResolver: resolver), layout = f.root.appendingPathComponent("chosen.lua")
        let bytes = Data("-- SYNTHETIC Lua; never executed\nreturn {}\n".utf8); try bytes.write(to: layout)
        let source = ProvisioningSetupSource(profiles: ["developer"], appearance: .init(theme: themeFixtureURL + ".git/", layoutFile: layout.path))
        let review = try await f.service.prepareCreation(source: source)
        let frozen = try #require(await f.service.creations[review.id]?.frozen)
        let options = try #require(frozen.plan.document.object?["features"]?.object?["options"]?.object?["workstation"]?.object)
        #expect(options["theme"] == .string(themeFixtureURL) && options["layout"] == .string(ProvisioningService.selectionLayout) && options["remove_layout"] == .bool(false))
        #expect(frozen.plan.snapshot.data(for: ProvisioningService.selectionLayout) == bytes)
        #expect(!String(decoding: review.proposal, as: UTF8.self).contains(f.root.path))
        #expect(ProvisioningAppearanceSummary(proposal: review.proposal).layoutIncluded)
        #expect(try await f.service.prepareCreation(id: review.id, source: source) == review)
        #expect(await http.calls.count == 1)
        try Data("-- changed after preview\n".utf8).write(to: layout)
        #expect(try await f.service.creation(review.id) == review)
        #expect(frozen.plan.snapshot.data(for: ProvisioningService.selectionLayout) == bytes)
        let next = try await f.service.prepareCreation(source: source)
        #expect(next.inputDigest != review.inputDigest && next.reviewIdentity != review.reviewIdentity)
        _ = try await f.create(review)
        await f.assertInert(); await f.close()
    }
    @Test func markerIsResolvedOnceBeforeReviewAndLookupDoesNotReselect() async throws {
        let http = AppearanceHTTP(), f = try await CreationFixture(themeResolver: .init(http: http, stars: AppearanceStars()))
        let source = ProvisioningSetupSource(profiles: ["developer"], appearance: .init(theme: "most-starred"))
        let review = try await f.service.prepareCreation(source: source)
        #expect(ProvisioningAppearanceSummary(proposal: review.proposal).theme == themeFixtureURL)
        #expect(try await f.service.prepareCreation(id: review.id, source: source) == review)
        let calls = await http.calls
        #expect(calls.count == 2 && calls[0].1 && !calls[1].1)
        await f.assertInert(); await f.close()
    }
    @Test func removingLayoutPreservesOtherWorkstationSettingsAndDoesNotFetchATheme() async throws {
        let http = AppearanceHTTP(), manifest = "schema_version: 1\nid: appearance-fixture\nsetup: {profiles: [developer], options: {builtin.workstation: {font_size: '14', theme: '\(themeFixtureURL)'}}}\n"
        let f = try await CreationFixture(manifest: manifest, themeResolver: .init(http: http, stars: AppearanceStars()))
        let original = try Data(contentsOf: f.source.appendingPathComponent("vm.yml"))
        let review = try await f.service.prepareCreation(source: .init(directory: f.source.path, appearance: .init(removeLayout: true)))
        let frozen = try #require(await f.service.creations[review.id]?.frozen)
        let config = frozen.plan.document.object?["features"]?.object?["options"]?.object?["workstation"]?.object
        #expect(config?["font_size"] == .string("14") && config?["theme"] == .string(themeFixtureURL) && config?["remove_layout"] == .bool(true))
        #expect(ProvisioningAppearanceSummary(proposal: review.proposal).layoutRemoved)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("vm.yml")) == original)
        #expect(await http.calls.isEmpty)
        await f.assertInert(); await f.close()
    }
    @Test(arguments: ["symlink", "fifo", "oversized", "binary", "empty"])
    func unsafeLayoutsAreRefusedBeforeNetworkOrVMWork(kind: String) async throws {
        let http = AppearanceHTTP(), f = try await CreationFixture(themeResolver: .init(http: http, stars: AppearanceStars()))
        let file = f.root.appendingPathComponent("unsafe.lua")
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.source.appendingPathComponent("vm.yml"))
        case "fifo": #expect(mkfifo(file.path, 0o600) == 0)
        case "oversized": try Data(repeating: 32, count: 256 * 1024 + 1).write(to: file)
        case "binary": try Data([255, 0, 255]).write(to: file)
        default: try Data().write(to: file)
        }
        await #expect(throws: ProvisioningAppearanceFailure.invalidLayout) {
            _ = try await f.service.prepareCreation(source: .init(profiles: ["developer"], appearance: .init(theme: themeFixtureURL, layoutFile: file.path)))
        }
        #expect(await http.calls.isEmpty)
        #expect(await f.service.creations.isEmpty)
        await f.assertInert(); await f.close()
    }
    @Test func inaccessibleThemeAndDisabledWorkstationCannotProduceAUsableReview() async throws {
        let http = AppearanceHTTP(status: 404), f = try await CreationFixture(themeResolver: .init(http: http, stars: AppearanceStars()))
        await #expect(throws: ThemeSelectionFailure.inaccessible) { _ = try await f.service.prepareCreation(source: .init(profiles: ["developer"], appearance: .init(theme: themeFixtureURL))) }
        #expect(await f.service.creations.isEmpty)
        await f.assertInert(); await f.close()
        let g = try await CreationFixture(manifest: "schema_version: 1\nid: disabled-workstation\nsetup: {features: {enable: [cli], disable: [workstation]}}\n", themeResolver: .init(http: AppearanceHTTP(), stars: AppearanceStars()))
        await #expect(throws: ProvisioningAppearanceFailure.workstationDisabled) { _ = try await g.service.prepareCreation(source: .init(directory: g.source.path, appearance: .init(theme: themeFixtureURL))) }
        await g.assertInert(); await g.close()
    }
    @Test func cliAndStrictIPCShareTheAppearanceSelectionAndTypedFailures() async throws {
        let f = try await CreationFixture(themeResolver: .init(http: AppearanceHTTP(status: 404), stars: AppearanceStars())), id = UUID()
        if case .prepareCreation(_, let source) = try ProvisioningSetupCLI.parse(["setup", "prepare-create", id.uuidString, "--preset", "developer", "--theme", "random", "--theme-min-stars", "0", "--layout-file", "/private/tmp/fixture.lua"]) {
            #expect(source.appearance == .init(theme: "random", minimumStars: 0, layoutFile: "/private/tmp/fixture.lua"))
        } else { Issue.record("Appearance CLI arguments were lost") }
        let endpoint = ManagerCommandEndpoint(directory: f.root.appendingPathComponent("appearance-ipc"))
        let server = try ProvisioningExternalServer(endpoint: endpoint, service: f.service); defer { server.stop() }
        let client = ProvisioningExternalClient(endpoint: endpoint)
        let reply = try await client.request(.prepareCreation, previewID: id, source: .init(profiles: ["developer"], appearance: .init(theme: themeFixtureURL)))
        #expect(reply.failure == "theme-unavailable" && reply.creationReview == nil)
        await client.close(); await f.assertInert(); await f.close()
    }
    @Test(arguments: ["negative", "bool", "fraction", "null", "extra", "both", "relative", "unsafe-url"])
    func strictAppearanceWireRejectsMalformedInputs(kind: String) throws {
        var request = ProvisioningExternalRequest(sequence: 1, operation: .prepareCreation)
        request.previewID = UUID(); request.source = .init(profiles: ["developer"], appearance: .init(theme: themeFixtureURL))
        var object = try #require(JSONSerialization.jsonObject(with: helperJSON(request)) as? [String: Any])
        var source = try #require(object["source"] as? [String: Any]), appearance = try #require(source["appearance"] as? [String: Any])
        switch kind {
        case "negative": appearance["minimumStars"] = -1
        case "bool": appearance["minimumStars"] = true
        case "fraction": appearance["minimumStars"] = 0.5
        case "null": appearance["theme"] = NSNull()
        case "extra": appearance["command"] = "forbidden"
        case "both": appearance["layoutFile"] = "/private/tmp/layout.lua"; appearance["removeLayout"] = true
        case "relative": appearance["layoutFile"] = "layout.lua"
        default: appearance["theme"] = "https://example.com/theme"
        }
        source["appearance"] = appearance; object["source"] = source
        #expect(throws: Error.self) { _ = try ProvisioningExternalRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }
}
