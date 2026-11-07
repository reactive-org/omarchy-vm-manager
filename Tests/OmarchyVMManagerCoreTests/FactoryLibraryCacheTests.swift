import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Factory library refresh ordering")
struct FactoryLibraryCacheTests {
    private let image = FactoryIdentity(kind: .custom, name: "Imported fixture", manifestSHA256: String(repeating: "a", count: 64), diskSHA256: String(repeating: "b", count: 64))

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
