import Foundation

/// Guest defaults for developer setup choices that aren't part of the desktop.
public struct SetupDefaults: Codable, Equatable, Sendable {
    /// Ask Omarchy once for its "permanent" passwordless sudo grant instead of
    /// renewed 60-minute grants. Setup revokes either one when it finishes.
    public var permanentSudoGrant = false
    public init(permanentSudoGrant: Bool = false) { self.permanentSudoGrant = permanentSudoGrant }
}

struct SetupDefaultsStore {
    let applicationSupport: URL
    private let channel: AppChannel
    init(applicationSupport: URL, channel: AppChannel = .current) { self.applicationSupport = applicationSupport; self.channel = channel }
    private var directory: URL { channel.directory(in: applicationSupport) }
    private static let name = "setup-defaults.json"
    private struct Record: Codable { let schemaVersion: Int; let setup: SetupDefaults }
    func load() throws -> SetupDefaults {
        let path = directory.appendingPathComponent(Self.name)
        guard PrivateFiles.exists(path) else { return SetupDefaults() }
        let record = try JSONDecoder().decode(Record.self, from: PrivateFiles.read(path))
        guard record.schemaVersion == 1 else { throw VMFailure(code: "setup-defaults-unsupported", message: "Unsupported setup defaults. The file was preserved.") }
        return record.setup
    }
    func save(_ value: SetupDefaults) throws {
        try PrivateFiles.directory(directory, create: true)
        if PrivateFiles.exists(directory.appendingPathComponent(Self.name)) { _ = try load() }
        try PrivateFiles.write(JSONEncoder().encode(Record(schemaVersion: 1, setup: value)), name: Self.name, in: directory)
    }
}
