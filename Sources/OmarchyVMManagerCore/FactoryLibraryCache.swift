import Foundation

public struct FactoryLibraryCache: Sendable {
    public struct Refresh: Sendable, Equatable {
        fileprivate let revision: UUID
        fileprivate let id: UUID
    }
    public private(set) var factories: [FactoryIdentity] = [.official]
    public private(set) var issues: [FactoryCatalogIssue] = []
    private var revision = UUID()
    private var refresh: Refresh?

    public init() {}
    public mutating func beginRefresh() -> Refresh {
        let request = Refresh(revision: revision, id: UUID())
        refresh = request
        return request
    }
    public func isCurrent(_ request: Refresh) -> Bool { refresh == request && revision == request.revision }
    @discardableResult
    public mutating func apply(_ listing: FactoryCatalogListing, for request: Refresh) -> Bool {
        guard isCurrent(request) else { return false }
        factories = listing.factories
        issues = listing.issues
        return true
    }
    public mutating func imported(_ identity: FactoryIdentity) {
        revision = UUID()
        refresh = nil
        factories.removeAll { $0.selector == identity.selector }
        factories.append(identity)
        issues.removeAll { $0.selector == identity.selector }
    }
}
