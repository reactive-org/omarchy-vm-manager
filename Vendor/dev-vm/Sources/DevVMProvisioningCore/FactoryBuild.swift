import CryptoKit
import Darwin
import Foundation

public enum FactoryBuildFailure: String, Error, Sendable { case invalidRequest, inputsChanged, dockerMissing, dockerUnavailable, remoteEngine, wrongArchitecture, engineChanged, insufficientSpace, downloadFailed, commandFailed, cancelled, cleanupRequired, invalidArtifact, busy }
public enum FactoryBuildStage: String, Codable, Sendable { case preparing, downloading, packages, image, verifying, importing, succeeded, failed, cancelled, cleanupRequired }
/// The Omarchy channel a factory installs from: the latest release (stable) or
/// development builds (edge). Either way the build refuses an Omarchy release
/// whose setup programs are not in the reviewed set.
public enum FactoryChannel: String, Codable, CaseIterable, Sendable { case stable, edge }
public struct FactoryBuildPlan: Codable, Equatable, Sendable {
    public let name: String
    public let sizeGiB: Int
    public let recipeSHA256: String
    /// Absent in records written before channels existed; those built edge.
    public let channel: FactoryChannel?
    public var resolvedChannel: FactoryChannel { channel ?? .edge }
    public var minimumArtifactBytes: Int64 { Int64(sizeGiB + 4) * 1_073_741_824 }
    public var minimumDockerScratchBytes: Int64 { 3 * 1_073_741_824 }
    public var privilegedContainer: Bool { true }
    public var guestBootTested: Bool { false }
    public init(name: String = "Lean Omarchy", sizeGiB: Int = 20, channel: FactoryChannel? = .stable) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), (20...128).contains(sizeGiB) else { throw FactoryBuildFailure.invalidRequest }
        self.name = name; self.sizeGiB = sizeGiB; recipeSHA256 = FactoryRecipePin.sha256; self.channel = channel
    }
    init(fixtureRecipe: String, channel: FactoryChannel? = .stable) { name = "Fixture"; sizeGiB = 20; recipeSHA256 = fixtureRecipe; self.channel = channel }
}
public struct FactoryBuildCommand: Sendable {
    public let id: UUID
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]
    public let timeoutSeconds: Int
    public let streaming: Bool
    public init(id: UUID = UUID(), executable: URL, arguments: [String], directory: URL, environment: [String: String], timeoutSeconds: Int = 30, streaming: Bool = false) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.directory = directory
        self.environment = environment; self.timeoutSeconds = timeoutSeconds; self.streaming = streaming
    }
}
public struct FactoryBuildCommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public init(status: Int32, output: Data = Data()) { self.status = status; self.output = output }
}
public protocol FactoryBuildProcessRunning: Sendable {
    /// Must return only after the matching child/group exits, or throw cleanupRequired
    /// while retaining ownership. Output callbacks cannot block process draining.
    func run(_ command: FactoryBuildCommand, output: @escaping @Sendable (Data) -> Void) async throws -> FactoryBuildCommandResult
}
public struct FactoryBuildOutputPage: Sendable {
    public let sequence: UInt64; public let bytes: Data; public let reset: Bool
    public init(sequence: UInt64, bytes: Data, reset: Bool) { self.sequence = sequence; self.bytes = bytes; self.reset = reset }
}
public final class FactoryBuildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(UInt64, Data)] = []
    private var sequence: UInt64 = 0
    private var bytes = 0
    public init() {}
    public func append(_ data: Data) {
        lock.withLock {
            for start in stride(from: 0, to: data.count, by: 8192) {
                let part = data.subdata(in: start..<min(start + 8192, data.count))
                sequence += UInt64(part.count); frames.append((sequence, part)); bytes += part.count
                while bytes > 256 * 1024, !frames.isEmpty { bytes -= frames.removeFirst().1.count }
            }
        }
    }
    public func page(after cursor: UInt64) -> FactoryBuildOutputPage {
        lock.withLock {
            // Byte cursors allow exactly bounded pages across arbitrarily
            // fragmented writes. Four pages can drain the retained 256 KiB.
            let earliest = frames.first.map { $0.0 - UInt64($0.1.count) } ?? sequence
            let reset = cursor > sequence || cursor < earliest
            let start = reset ? earliest : cursor
            var data = Data(), next = start
            for (end, frame) in frames where end > start {
                let begin = end - UInt64(frame.count)
                let offset = Int(max(start, begin) - begin)
                let count = min(frame.count - offset, 65_536 - data.count)
                data.append(frame.subdata(in: offset..<(offset + count)))
                next = begin + UInt64(offset + count)
                if data.count == 65_536 { break }
            }
            return .init(sequence: next, bytes: data, reset: reset)
        }
    }
}

public struct FactoryRecipe: Sendable {
    struct File: Decodable, Sendable { let sha256: String; let mode: Int }
    public struct Download: Decodable, Sendable { public let name: String; public let url: URL; public let sha256: String }
    struct Manifest: Decodable { let format: Int; let templateSHA256: String; let files: [String: File]; let downloads: [Download] }
    let manifest: Manifest
    let identity: String
    public let archive: URL
    let provenance: [String: ManifestValue]
    public var downloads: [Download] { manifest.downloads }
    public init() throws { try self.init(bundle: .module) }
    init(bundle: Bundle) throws {
        // Foundation resolves both flat SwiftPM bundles and macOS Contents/
        // Resources bundles. resourceURL already includes a Resources directory
        // under some toolchains, so appending that path manually is incorrect.
        guard let recipe = bundle.url(forResource: "recipe", withExtension: "json", subdirectory: "Resources/FactoryBuild"),
              let archive = bundle.url(forResource: "template", withExtension: "tar.gz", subdirectory: "Resources/FactoryBuild")
        else { throw FactoryBuildFailure.inputsChanged }
        try self.init(archive: archive, data: Data(contentsOf: recipe), expected: FactoryRecipePin.sha256)
    }
    init(archive: URL, data: Data, expected: String) throws {
        self.archive = archive; identity = expected
        guard digest(data) == expected else { throw FactoryBuildFailure.inputsChanged }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == 1, manifest.files.count <= 512, manifest.downloads.count == 1,
              case .object(let doc) = try PlainDataParser.parse(data, format: .json), case .object(let p) = doc["provenance"] else { throw FactoryBuildFailure.inputsChanged }
        provenance = p
        try verify()
    }
    public func verify() throws {
        guard try factoryFileHash(archive) == manifest.templateSHA256 else { throw FactoryBuildFailure.inputsChanged }
    }
    public func verifyStaged(_ stage: URL) throws {
        let builder = try SnapshotBuilder(repository: stage)
        try builder.capture("upstream"); try builder.capture("profile")
        let snapshot = builder.freeze()
        guard Set(snapshot.filePathsForFactory) == Set(manifest.files.keys) else { throw FactoryBuildFailure.inputsChanged }
        for receipt in snapshot.receipts {
            guard let expected = manifest.files[receipt.path], receipt.sha256 == expected.sha256, receipt.mode == expected.mode else { throw FactoryBuildFailure.inputsChanged }
        }
    }
    public func buildEvidence(plan: FactoryBuildPlan, imageID: String) throws -> Data {
        var value = provenance
        value["size_gib"] = .integer(Int64(plan.sizeGiB))
        value["channel"] = .string(plan.resolvedChannel.rawValue)
        value["input_identity"] = .string(digest(try canonicalData(plan)))
        value["builder_image"] = .string(imageID)
        value["validation"] = .string("sealed-image-static-checks")
        value["manager_admitted"] = .bool(false); value["guest_boot_tested"] = .bool(false)
        value["live_arch_repositories"] = .bool(true)
        return try canonicalData(ManifestValue.object(value))
    }
}
private extension SourceSnapshot { var filePathsForFactory: [String] { receipts.map(\.path) } }

func factoryFileHash(_ path: URL) throws -> String {
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw FactoryBuildFailure.inputsChanged }
    defer { close(fd) }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_mode & 0o022 == 0 else { throw FactoryBuildFailure.inputsChanged }
    var hash = SHA256(); let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
    guard fstat(fd, &after) == 0, FileStamp(before) == FileStamp(after) else { throw FactoryBuildFailure.inputsChanged }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
