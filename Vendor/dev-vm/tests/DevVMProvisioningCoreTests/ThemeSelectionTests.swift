import Foundation
import Testing
@testable import DevVMProvisioningCore

private let firstTheme = "https://github.com/example/omarchy-alpha-theme"
private let secondTheme = "https://github.com/example/omarchy-beta-theme"
private let themeCatalogue = Data("""
<a href="https://github.com/example/not-a-theme">ignore</a>
<figure class="themes__theme other"><a href="https://github.com/example/omarchy-beta-theme.git/">Beta</a></figure>
<figure class='themes__theme'><a href='https://github.com/example/omarchy-alpha-theme'>Alpha</a></figure>
<figure class="other"><a href="https://github.com/example/ignored">ignore</a></figure>
""".utf8)
private actor ThemeHTTPFixture: ThemeHTTPFetching {
    var calls: [(URL, Bool)] = []
    let status: Int
    let final: URL?
    let catalogue: Data
    init(status: Int = 200, final: URL? = nil, catalogue: Data = themeCatalogue) { self.status = status; self.final = final; self.catalogue = catalogue }
    func get(_ url: URL, body: Bool) async throws -> ThemeHTTPResponse {
        calls.append((url, body))
        return .init(status: status, url: final ?? url, data: body ? catalogue : Data())
    }
}
private actor ThemeStarsFixture: ThemeStarProviding {
    var calls = 0
    let values: [String: Int]
    init(_ values: [String: Int] = [:]) { self.values = values }
    func counts(for repositories: [String]) -> [String: Int] { calls += 1; return values }
}
@Test(arguments: ["http://github.com/example/theme", "https://example.com/a/b", "https://github.com/example/theme/tree/main", "https://github.com/example/theme?token=secret", "https://user@github.com/example/theme", "https://github.com/example/theme.git.git", "https://github.com/example/omarchy--theme", "random;true", "RANDOM", "https://github.com:443/example/theme"])
func unsafeThemeSelectorsAreRefusedBeforeAnyGET(_ value: String) async throws {
    let http = ThemeHTTPFixture(), stars = ThemeStarsFixture()
    await #expect(throws: ThemeSelectionFailure.invalidSelector) { _ = try await ThemeResolver(http: http, stars: stars).resolve(value) }
    #expect(await http.calls.isEmpty)
    #expect(await stars.calls == 0)
}
@Test func directThemeURLNormalizesAndRequiresSuccessfulRepositoryGETOnly() async throws {
    let http = ThemeHTTPFixture(), stars = ThemeStarsFixture()
    let value = try await ThemeResolver(http: http, stars: stars).resolve(firstTheme + ".git/")
    #expect(value == firstTheme)
    let calls = await http.calls
    #expect(calls.count == 1 && calls[0].0.absoluteString == firstTheme && !calls[0].1)
    #expect(await stars.calls == 0)
}
@Test func catalogueMarkersResolveOnceWithLegacyStarThresholdAndStableTies() async throws {
    let http = ThemeHTTPFixture(), stars = ThemeStarsFixture([firstTheme: 10, secondTheme: 9])
    let random = try await ThemeResolver(http: http, stars: stars, choose: { _ in 0 }).resolve("random")
    #expect(random == firstTheme)
    let tied = ThemeStarsFixture([firstTheme: 20, secondTheme: 20])
    #expect(try await ThemeResolver(http: http, stars: tied).resolve("most-starred") == firstTheme)
    let unfiltered = ThemeStarsFixture()
    #expect(try await ThemeResolver(http: http, stars: unfiltered, choose: { _ in 1 }).resolve("random", minimumStars: 0) == secondTheme)
    #expect(await unfiltered.calls == 0)
    let calls = await http.calls
    #expect(calls.count == 6 && calls.filter(\.1).count == 3)
}
@Test(arguments: [301, 401, 403, 404, 429, 500])
func inaccessibleRepositoryNeverPassesThemeValidation(_ status: Int) async throws {
    await #expect(throws: ThemeSelectionFailure.inaccessible) { _ = try await ThemeResolver(http: ThemeHTTPFixture(status: status), stars: ThemeStarsFixture()).resolve(firstTheme) }
}
@Test func themeRedirectsCannotTurnIntoLoginOrArbitraryDestinations() async throws {
    for target in ["https://github.com/login", "https://example.com/a/b", "http://github.com/example/theme", "https://github.com/example/theme?auth=x"] {
        await #expect(throws: ThemeSelectionFailure.inaccessible) { _ = try await ThemeResolver(http: ThemeHTTPFixture(final: URL(string: target)!), stars: ThemeStarsFixture()).resolve(firstTheme) }
    }
    let renamed = "https://github.com/example/omarchy-renamed-theme"
    #expect(try await ThemeResolver(http: ThemeHTTPFixture(final: URL(string: renamed)!), stars: ThemeStarsFixture()).resolve(firstTheme) == renamed)
}
@Test func malformedEmptyAndOversizedCataloguesAndUnusableRankingsAreRefused() async throws {
    for data in [Data(), Data([255]), Data("<a href='https://github.com/example/theme'>outside</a>".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
        #expect(throws: ThemeSelectionFailure.catalogue) { _ = try ThemeSelection.catalogue(data) }
    }
    for values in [[:], [firstTheme: 0]] {
        await #expect(throws: ThemeSelectionFailure.noEligibleThemes) { _ = try await ThemeResolver(http: ThemeHTTPFixture(), stars: ThemeStarsFixture(values)).resolve("random") }
    }
    await #expect(throws: ThemeSelectionFailure.starsUnavailable) { _ = try await ThemeResolver(http: ThemeHTTPFixture(), stars: ThemeStarsFixture([firstTheme: -1])).resolve("most-starred") }
    #expect(try ThemeSelection.catalogue(themeCatalogue) == [firstTheme, secondTheme])
}
