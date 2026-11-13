import Foundation

/// Explicit private binary archive, never part of plan/event JSON. Restoring
/// returns inert bytes only, not a SourceSnapshot/SetupPlan or apply authority.
public struct FrozenInputsArchive: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumMetadataBytes = 8 * 1024 * 1024
    public static let maximumArchiveBytes = maximumMetadataBytes + SourceSnapshot.maximumBytes + 12
    private static let magic = Data("DVMSNAP1".utf8)
    private let files: [String: FrozenFile]
    private let directories: [String: FrozenDirectory]
    public let identity: String
    public var filePaths: [String] { files.keys.sorted() }
    public var directoryPaths: [String] { directories.keys.sorted() }
    public func data(for path: String) -> Data? { files[path]?.data }
    public func originalMode(for path: String) -> Int? { files[path]?.mode ?? directories[path]?.mode }
    public var description: String { "FrozenInputsArchive(redacted)" }
    public var debugDescription: String { description }

    public init(privateArchive data: Data, expectedIdentity: String) throws {
        guard data.count >= 12, data.count <= Self.maximumArchiveBytes, data.prefix(8) == Self.magic,
              matches(expectedIdentity, "[a-f0-9]{64}") else { throw ManifestError(.sourceChanged) }
        let length = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= Self.maximumMetadataBytes, length <= data.count - 12 else { throw ManifestError(.sourceLimit) }
        let metadata = Data(data[12..<12+length])
        guard String(data: metadata, encoding: .utf8) != nil else { throw ManifestError(.encoding) }
        var parser = JSONGrammar(bytes: Array(metadata), maximumNodes: 150_000)
        guard case .object(let doc) = try parser.parse(), Set(doc.keys) == ["format", "identity", "files", "directories", "roots"],
              doc["format"] == .integer(1), doc["identity"] == .string(expectedIdentity),
              case .array(let entries) = doc["files"], entries.count <= SourceSnapshot.maximumFiles,
              case .object(let dirs) = doc["directories"], dirs.count <= 4096,
              case .array(let roots) = doc["roots"], roots.count <= 8192 else { throw ManifestError(.schema) }
        var files: [String: FrozenFile] = [:], directories: [String: FrozenDirectory] = [:]
        var offset = 12 + length, total = 0, ordered: [String] = []
        for entry in entries {
            guard case .object(let fields) = entry, Set(fields.keys) == ["path", "sha256", "mode", "size"],
                  case .string(let path) = fields["path"], case .string(let sha) = fields["sha256"],
                  case .integer(let mode) = fields["mode"], (0...511).contains(mode),
                  case .integer(let size) = fields["size"], size >= 0, size <= SourceSnapshot.maximumBytes,
                  files[path] == nil else { throw ManifestError(.schema) }
            try Self.path(path)
            total += Int(size)
            guard total <= SourceSnapshot.maximumBytes, Int(size) <= data.count - offset else { throw ManifestError(.sourceLimit) }
            let bytes = Data(data[offset..<offset+Int(size)]); offset += Int(size)
            guard digest(bytes) == sha else { throw ManifestError(.sourceChanged) }
            files[path] = FrozenFile(data: bytes, mode: Int(mode)); ordered.append(path)
        }
        guard ordered == ordered.sorted(), offset == data.count else { throw ManifestError(.schema) }
        var children = 0
        for (path, value) in dirs {
            try Self.path(path)
            guard files[path] == nil, case .object(let fields) = value, Set(fields.keys) == ["mode", "names"],
                  case .integer(let mode) = fields["mode"], (0...511).contains(mode), case .array(let names) = fields["names"], names.count <= 8192 else { throw ManifestError(.schema) }
            let strings = try names.map { name -> String in
                guard case .string(let text) = name, !text.contains("/") else { throw ManifestError(.schema) }
                try Self.path(text); return text
            }
            children += strings.count
            guard children <= 8192, strings == strings.sorted(), Set(strings).count == strings.count else { throw ManifestError(.sourceLimit) }
            directories[path] = FrozenDirectory(names: strings, mode: Int(mode))
        }
        let rootPaths = try roots.map { value -> String in
            guard case .string(let path) = value, files[path] != nil || directories[path] != nil else { throw ManifestError(.schema) }
            try Self.path(path); return path
        }
        guard rootPaths == rootPaths.sorted(), Set(rootPaths).count == rootPaths.count else { throw ManifestError(.schema) }
        for (path, dir) in directories {
            guard dir.names.allSatisfy({ files[path + "/" + $0] != nil || directories[path + "/" + $0] != nil }) else { throw ManifestError(.schema) }
        }
        let receipts = files.keys.sorted().map { InputReceipt(path: $0, sha256: digest(files[$0]!.data), mode: files[$0]!.mode) }
        let values = directories.mapValues { ManifestValue.object(["mode": .integer(Int64($0.mode)), "names": .array($0.names.map(ManifestValue.string))]) }
        guard digest(try canonicalData(SnapshotIdentity(files: receipts, directories: values))) == expectedIdentity else { throw ManifestError(.sourceChanged) }
        self.files = files; self.directories = directories; identity = expectedIdentity
    }
    private static func path(_ path: String) throws {
        try relativePath(path)
        guard path.utf8.count <= 16_384, path.split(separator: "/").count <= 64 else { throw ManifestError(.sourceLimit) }
    }
}

extension SourceSnapshot {
    /// Contains selected user configuration, which may be sensitive. Keep it in
    /// private durable storage; never emit it through a report or terminal.
    public func privateArchive() throws -> Data {
        let ordered = files.keys.sorted()
        let entries = ordered.map { path -> ManifestValue in
            let file = files[path]!
            return .object(["path": .string(path), "sha256": .string(digest(file.data)), "mode": .integer(Int64(file.mode)), "size": .integer(Int64(file.data.count))])
        }
        let dirs = directories.mapValues { ManifestValue.object(["mode": .integer(Int64($0.mode)), "names": .array($0.names.map(ManifestValue.string))]) }
        let metadata = try canonicalData(ManifestValue.object(["format": .integer(1), "identity": .string(identity),
            "files": .array(entries), "directories": .object(dirs), "roots": .array(roots.map(ManifestValue.string))]))
        guard metadata.count <= FrozenInputsArchive.maximumMetadataBytes else { throw ManifestError(.sourceLimit) }
        var output = Data("DVMSNAP1".utf8)
        let length = UInt32(metadata.count)
        output.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        output.append(metadata)
        for path in ordered { output.append(files[path]!.data) }
        // Use the same strict reader on exported bytes, including tree bounds.
        _ = try FrozenInputsArchive(privateArchive: output, expectedIdentity: identity)
        return output
    }
}
