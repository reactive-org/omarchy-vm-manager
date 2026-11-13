import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Factory library refresh ordering")
struct FactoryLibraryCacheTests {
    private let image = FactoryIdentity(kind: .custom, name: "Imported fixture", manifestSHA256: String(repeating: "a", count: 64), diskSHA256: String(repeating: "b", count: 64))

    @Test("manual owner setup follows the listing, imports and removal")
    func manualOwnerSetup() {
        var cache = FactoryLibraryCache()
        let request = cache.beginRefresh()
        _ = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: [], manualOwnerSetup: [image.selector]), for: request)
        #expect(cache.manualOwnerSetup == [image.selector])
        cache.imported(image)
        #expect(cache.manualOwnerSetup.isEmpty)
        cache.markManualOwnerSetup(image)
        #expect(cache.manualOwnerSetup == [image.selector])
        cache.removed(image)
        cache.markManualOwnerSetup(image)
        #expect(cache.manualOwnerSetup.isEmpty)
        cache.imported(image, manualOwnerSetup: true)
        #expect(cache.manualOwnerSetup == [image.selector])
    }

    @Test("unavailable imports retain a selection notice beside compatible choices until resolved")
    func unavailableNotice() {
        var cache = FactoryLibraryCache()
        #expect(cache.selectionNotice == nil)
        let issue = FactoryCatalogIssue(selector: String(repeating: "c", count: 64), message: "Different runtime")
        let listing = FactoryCatalogListing(factories: [.official, image], issues: [issue])
        for _ in 0..<2 {
            let request = cache.beginRefresh()
            let applied = cache.apply(listing, for: request)
            #expect(applied)
            #expect(cache.selectionNotice != nil)
            #expect(cache.factories == [.official, image])
            #expect(!cache.factories.contains { $0.selector == issue.selector })
        }
        let stale = cache.beginRefresh()
        cache.imported(image)
        #expect(cache.selectionNotice != nil)
        let current = cache.beginRefresh()
        let applied = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: []), for: current)
        #expect(applied)
        #expect(cache.selectionNotice == nil)
        let appliedStale = cache.apply(listing, for: stale)
        #expect(!appliedStale)
        #expect(cache.selectionNotice == nil)
    }

    @Test("an import keeps the catalog's card order so cards do not move under the pointer")
    func importKeepsCatalogOrder() {
        func custom(_ digit: String) -> FactoryIdentity {
            FactoryIdentity(kind: .custom, name: "Fixture " + digit, manifestSHA256: String(repeating: digit, count: 64), diskSHA256: String(repeating: "f", count: 64))
        }
        var cache = FactoryLibraryCache()
        let request = cache.beginRefresh()
        _ = cache.apply(FactoryCatalogListing(factories: [.official, custom("1"), custom("3")], issues: []), for: request)
        cache.imported(custom("2"))
        #expect(cache.factories.map(\.selector) == ["official", custom("1").selector, custom("2").selector, custom("3").selector])
        cache.imported(custom("1"))
        #expect(cache.factories.map(\.selector) == ["official", custom("1").selector, custom("2").selector, custom("3").selector])
        cache.imported(custom("4"))
        #expect(cache.factories.last?.selector == custom("4").selector)
    }

    @Test("factory details tell same-named factories apart by channel, version and build time")
    func details() throws {
        let stable = try #require(FactoryDetails.decode(Data(#"{"omarchy":"4.5.0-3","channel":"stable","built":"2026-11-08T00:34:50Z","kernel":"7.2"}"#.utf8)))
        #expect(stable.omarchyVersion == "4.5.0" && stable.channelLabel == "Stable" && stable.built != nil)
        let edge = try #require(FactoryDetails.decode(Data(#"{"omarchy":"4.0.0.r7481.ge4fffc6-1.1","channel":"edge"}"#.utf8)))
        #expect(edge.omarchyVersion == "4.0.0.r7481" && edge.channelLabel == "Edge" && edge.built == nil)
        let bare = try #require(FactoryDetails.decode(Data("{}".utf8)))
        #expect(bare.omarchyVersion == nil && bare.channelLabel == nil)
        // An edge package's fixed 4.0.0 base must not read as an old release.
        #expect(stable.omarchyLabel == "Omarchy 4.5.0")
        #expect(edge.omarchyLabel == "Omarchy development build r7481")
        #expect(bare.omarchyLabel == nil)
        #expect(FactoryDetails.omarchyLabel("4.0.0.r7617-1") == "Omarchy development build r7617")
        #expect(FactoryDetails.omarchyLabel("4.5.1") == "Omarchy 4.5.1")
        #expect(FactoryDetails.omarchyLabel("-1") == nil)
        var cache = FactoryLibraryCache()
        let request = cache.beginRefresh()
        _ = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: [], details: [image.selector: stable]), for: request)
        #expect(cache.details[image.selector] == stable)
    }

    @Test("a factory moved to Trash leaves the library at once and a stale refresh can't restore it")
    func removalIsImmediate() {
        var cache = FactoryLibraryCache()
        let request = cache.beginRefresh()
        _ = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: [], details: [image.selector: FactoryDetails(omarchy: "4.5.0-3", channel: "stable", built: nil)]), for: request)
        let stale = cache.beginRefresh()
        cache.removed(image)
        #expect(cache.factories == [.official] && cache.details.isEmpty)
        let appliedStale = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: []), for: stale)
        #expect(!appliedStale && cache.factories == [.official])
    }

    @Test("a refresh started before import cannot remove the new picker choice or publish an old error")
    func importWins() {
        var cache = FactoryLibraryCache()
        let old = cache.beginRefresh()
        cache.imported(image)
        let stale = FactoryCatalogListing(factories: [.official], issues: [FactoryCatalogIssue(selector: image.selector, message: "Old failure")])
        let appliedOld = cache.apply(stale, for: old)
        #expect(!appliedOld)
        #expect(!cache.isCurrent(old))
        #expect(cache.factories == [.official, image])
        #expect(cache.issues.isEmpty)
        let current = cache.beginRefresh()
        let appliedCurrent = cache.apply(FactoryCatalogListing(factories: [.official, image], issues: []), for: current)
        #expect(appliedCurrent)
    }
    @Test("only the latest overlapping refresh can update factories and warnings")
    func newerRefreshWins() {
        var cache = FactoryLibraryCache()
        let first = cache.beginRefresh(), second = cache.beginRefresh()
        let good = FactoryCatalogListing(factories: [.official, image], issues: [])
        let appliedSecond = cache.apply(good, for: second)
        let appliedFirst = cache.apply(FactoryCatalogListing(factories: [.official], issues: []), for: first)
        #expect(appliedSecond && !appliedFirst)
        #expect(cache.factories == good.factories)
        let third = cache.beginRefresh()
        let issue = FactoryCatalogIssue(selector: image.selector, message: "Verification failed")
        let appliedThird = cache.apply(FactoryCatalogListing(factories: [.official], issues: [issue]), for: third)
        #expect(appliedThird)
        cache.imported(image)
        #expect(cache.factories == [.official, image] && cache.issues.isEmpty)
        #expect(!cache.isCurrent(third))
    }
}
