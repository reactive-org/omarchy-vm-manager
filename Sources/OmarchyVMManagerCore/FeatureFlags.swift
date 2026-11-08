import Foundation

/// Features compiled per channel, like `AppChannel`. Never a preference or an
/// environment override: stable and Dev builds each carry a fixed set.
public struct FeatureFlags: Equatable, Sendable {
    /// The opt-in suspend-to-disk workflow and its guest capability check.
    /// Recovery of an existing saved session never depends on this flag.
    public var experimentalSuspendToDisk: Bool

    public init(experimentalSuspendToDisk: Bool) {
        self.experimentalSuspendToDisk = experimentalSuspendToDisk
    }

    public init(channel: AppChannel) {
        experimentalSuspendToDisk = channel == .development
    }

    public static var current: Self { .init(channel: .current) }

    /// A saved session or damaged suspension metadata keeps its recovery panel
    /// even when new attempts are hidden, because its disk stays protected.
    public func showsSuspendPanel(for snapshot: VMSnapshot) -> Bool {
        experimentalSuspendToDisk || snapshot.suspension != nil || snapshot.suspensionMetadataUnsafe
    }
}
