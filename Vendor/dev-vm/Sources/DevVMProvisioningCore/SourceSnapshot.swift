import CryptoKit
import Darwin
import Foundation

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func sourceFormat(_ path: String) throws -> ManifestFormat {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "json": .json
    case "yml", "yaml": .yaml
    default: throw ManifestError(.unsupportedFormat)
    }
}

public struct InputReceipt: Sendable, Equatable, Encodable {
    public let path: String
    public let sha256: String
    public let mode: Int
}
struct FrozenFile: Sendable, Equatable {
    let data: Data
    let mode: Int
}
struct FrozenDirectory: Sendable, Equatable {
    let names: [String]
    let mode: Int
}

/// Immutable in-memory bytes. Only explicitly selected paths are captured; never
/// serializes file contents, a host path or device/inode identifiers by default.
public struct SourceSnapshot: Sendable {
    public static let maximumFiles = 4096
    public static let maximumBytes = 32 * 1024 * 1024
    let files: [String: FrozenFile]
    let directories: [String: FrozenDirectory]
    let roots: [String]
    let rootDevice: dev_t
    let rootInode: ino_t
    public var receipts: [InputReceipt] {
        files.keys.sorted().map { InputReceipt(path: $0, sha256: digest(files[$0]!.data), mode: files[$0]!.mode) }
    }
    public func data(for path: String) -> Data? { files[path]?.data }
    public var identity: String {
        // Directory entries/modes also bind empty directories and later additions.
        let dirs = directories.mapValues { ManifestValue.object(["mode": .integer(Int64($0.mode)),
                                                               "names": .array($0.names.map(ManifestValue.string))]) }
        return digest(try! canonicalData(SnapshotIdentity(files: receipts, directories: dirs)))
    }
    public func verify(in repository: URL) throws {
        do {
            let builder = try SnapshotBuilder(repository: repository)
            guard builder.rootDevice == rootDevice, builder.rootInode == rootInode else { throw ManifestError(.sourceChanged) }
            for root in roots { try builder.capture(root) }
            let current = builder.freeze()
            guard files == current.files, directories == current.directories else { throw ManifestError(.sourceChanged) }
        } catch { throw ManifestError(.sourceChanged) }
    }
}
struct SnapshotIdentity: Encodable {
    let files: [InputReceipt]
    let directories: [String: ManifestValue]
}

/// Descriptor-relative traversal prevents a symlink swap from escaping the
/// selected root. All descriptors are retained until their synchronous use ends.
final class SnapshotBuilder {
    let rootFD: Int32
    let rootDevice: dev_t
    let rootInode: ino_t
    private var files: [String: FrozenFile] = [:]
    private var directories: [String: FrozenDirectory] = [:]
    private var roots = Set<String>()
    private var bytes = 0

    init(repository: URL) throws {
        guard repository.isFileURL, !repository.path.utf8.contains(0) else { throw ManifestError(.file) }
        let fd = open(repository.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ManifestError(.file) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw ManifestError(.file) }
        rootFD = fd; rootDevice = info.st_dev; rootInode = info.st_ino
    }
    deinit { close(rootFD) }

    @discardableResult func capture(_ path: String, limit: Int = SourceSnapshot.maximumBytes) throws -> [String] {
        try relativePath(path)
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count <= 64 else { throw ManifestError(.sourceLimit) }
        var parent = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ManifestError(.file) }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ManifestError(.file) }
            close(parent); parent = next
        }
        roots.insert(path)
        return try walk(parent: parent, name: parts.last!, path: path, depth: parts.count, limit: limit)
    }
    func document(_ path: String) throws -> PlainDocument {
        _ = try capture(path, limit: PlainDataParser.maximumBytes)
        guard let file = files[path] else { throw ManifestError(.file) }
        return try PlainDataParser.document(file.data, format: sourceFormat(path))
    }
    func freeze() -> SourceSnapshot {
        SourceSnapshot(files: files, directories: directories, roots: roots.sorted(), rootDevice: rootDevice, rootInode: rootInode)
    }
    private func walk(parent: Int32, name: String, path: String, depth: Int, limit: Int) throws -> [String] {
        guard depth <= 64 else { throw ManifestError(.sourceLimit) }
        var selected = stat()
        guard fstatat(parent, name, &selected, AT_SYMLINK_NOFOLLOW) == 0,
              [S_IFREG, S_IFDIR].contains(selected.st_mode & S_IFMT) else { throw ManifestError(.file) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ManifestError(.file) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, unchanged(selected, before) else { throw ManifestError(.sourceChanged) }
        let mode = Int(before.st_mode & 0o777)
        if before.st_mode & S_IFMT == S_IFREG {
            guard before.st_size >= 0, before.st_size <= limit,
                  files[path] != nil || files.count < SourceSnapshot.maximumFiles else { throw ManifestError(.sourceLimit) }
            let remaining = SourceSnapshot.maximumBytes - bytes + (files[path]?.data.count ?? 0)
            let data = try read(fd: fd, maximum: min(limit, remaining))
            var after = stat()
            guard fstat(fd, &after) == 0, unchanged(before, after), data.count == after.st_size
            else { throw ManifestError(.sourceChanged) }
            let frozen = FrozenFile(data: data, mode: mode)
            if let previous = files[path] {
                guard previous == frozen else { throw ManifestError(.sourceChanged) }
            } else { files[path] = frozen; bytes += data.count }
            return [path]
        }
        guard before.st_mode & S_IFMT == S_IFDIR else { throw ManifestError(.file) }
        guard directories[path] != nil || directories.count < 4096 else { throw ManifestError(.sourceLimit) }
        let names = try entries(fd)
        let directory = FrozenDirectory(names: names, mode: mode)
        if let previous = directories[path], previous != directory { throw ManifestError(.sourceChanged) }
        directories[path] = directory
        var result: [String] = []
        for child in names {
            try relativePath(child)
            result += try walk(parent: fd, name: child, path: path + "/" + child, depth: depth + 1, limit: limit)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, unchanged(before, after), try entries(fd) == names
        else { throw ManifestError(.sourceChanged) }
        return result
    }
    private func read(fd: Int32, maximum: Int) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, min(buffer.count, max(1, maximum - data.count + 1)))
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw ManifestError(.file) }
            if n == 0 { return data }
            guard data.count + n <= maximum else { throw ManifestError(.sourceLimit) }
            data.append(contentsOf: buffer.prefix(n))
        }
    }
    private func entries(_ fd: Int32) throws -> [String] {
        // Open a fresh directory description; dup() would share readdir's offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw ManifestError(.file) }
        guard let directory = fdopendir(copy) else { close(copy); throw ManifestError(.file) }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ManifestError(.file) }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
            }
            guard let name else { throw ManifestError(.encoding) }
            if name == "." || name == ".." { continue }
            guard result.count < 8192 else { throw ManifestError(.sourceLimit) }
            result.append(name)
        }
        guard Set(result).count == result.count else { throw ManifestError(.file) }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    private func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
