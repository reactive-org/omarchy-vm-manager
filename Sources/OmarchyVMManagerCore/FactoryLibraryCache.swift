import Foundation

public struct FactoryLibraryCache: Sendable {
    public struct Refresh: Sendable, Equatable {
        fileprivate let revision: UUID
        fileprivate let id: UUID
    }
    public private(set) var factories: [FactoryIdentity] = [.official]
    public private(set) var issues: [FactoryCatalogIssue] = []
    public private(set) var details: [String: FactoryDetails] = [:]
    public var selectionNotice: String? {
        issues.isEmpty ? nil : "Some imported factory images are incompatible with this app or failed verification. Only verified compatible images are listed."
    }
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
        details = listing.details
        return true
    }
    public mutating func imported(_ identity: FactoryIdentity) {
        revision = UUID()
        refresh = nil
        factories.removeAll { $0.selector == identity.selector }
        // Keep the catalog's own order (official first, then custom factories
        // by digest) so cards never swap places under the pointer when a
        // later refresh replaces this list.
        let index = factories.firstIndex { $0.kind == .custom && $0.selector > identity.selector } ?? factories.endIndex
        factories.insert(identity, at: index)
        issues.removeAll { $0.selector == identity.selector }
    }
}
