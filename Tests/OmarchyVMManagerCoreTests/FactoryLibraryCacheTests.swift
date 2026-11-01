import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Factory library refresh ordering")
struct FactoryLibraryCacheTests {
    private let image = FactoryIdentity(kind: .custom, name: "Imported fixture", manifestSHA256: String(repeating: "a", count: 64), diskSHA256: String(repeating: "b", count: 64))

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
