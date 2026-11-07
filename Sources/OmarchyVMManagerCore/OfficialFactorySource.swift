import CryptoKit
import Foundation
import TryOmarchyKitClient

/// Where the official Try Omarchy image comes from, read from the kit's pinned
/// download and factory manifests. Shown so people can see the image is the
/// official release while it downloads. Both manifests must match the digests in
/// the runtime lock, and every part must be an HTTPS download from the
/// omacom/try-omarchy GitHub releases; anything else yields no source rather than
/// a guess.
public struct OfficialFactorySource: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
    }
    public let repository: String
    public let releaseTag: String
    public let releaseURL: URL
    public let fileName: String
    public let parts: [Part]
    public let downloadBytes: Int64
    public let imageSHA256: String
    public let omarchyVersion: String
    public let channel: String
    public let platform: String
    public let kernel: String
    public let built: Date?

    static let repositoryPath = "/omacom/try-omarchy/releases/download/"

    public static func load(kit: TryOmarchyKit, lockData: Data) -> OfficialFactorySource? {
        let guest = kit.bundleURL.appendingPathComponent("Contents/Resources/guest", isDirectory: true)
        guard let download = try? Data(contentsOf: guest.appendingPathComponent("download.json")),
              let factory = try? Data(contentsOf: guest.appendingPathComponent("factory.json")) else { return nil }
        return parse(download: download, factory: factory, lockData: lockData)
    }

    public static func parse(download: Data, factory: Data, lockData: Data) -> OfficialFactorySource? {
        struct Lock: Decodable { let files: [String: String] }
        struct Download: Decodable {
            struct Image: Decodable { let bytes: Int64; let sha256: String }
            struct Part: Decodable { let url: String; let bytes: Int64; let sha256: String }
            let format: Int; let kind: String; let image: Image; let parts: [Part]
        }
        struct Factory: Decodable {
            struct Compressed: Decodable { let path: String; let sha256: String }
            let omarchy: String; let kernel: String; let built: String; let channel: String; let platform: String
            let compressed: Compressed
        }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard let lock = try? JSONDecoder().decode(Lock.self, from: lockData),
              lock.files["Contents/Resources/guest/download.json"] == sha(download),
              lock.files["Contents/Resources/guest/factory.json"] == sha(factory),
              let manifest = try? JSONDecoder().decode(Download.self, from: download), manifest.format == 1,
              manifest.kind == "try-omarchy-factory-download", (1...16).contains(manifest.parts.count),
              let image = try? JSONDecoder().decode(Factory.self, from: factory),
              image.compressed.sha256 == manifest.image.sha256 else { return nil }
        var tag: String?
        var parts: [Part] = []
        for part in manifest.parts {
            guard let url = URL(string: part.url), url.scheme == "https", url.host == "github.com", url.path.hasPrefix(repositoryPath) else { return nil }
            let rest = url.path.dropFirst(repositoryPath.count).split(separator: "/")
            guard rest.count == 2, tag == nil || tag == String(rest[0]), String(rest[1]).hasPrefix(image.compressed.path + ".") else { return nil }
            tag = String(rest[0])
            parts.append(Part(name: String(rest[1]).replacingOccurrences(of: image.compressed.path, with: ""), bytes: part.bytes))
        }
        guard let tag, let release = URL(string: "https://github.com/omacom/try-omarchy/releases/tag/" + tag) else { return nil }
        let total = parts.reduce(Int64(0)) { $0 + $1.bytes }
        guard total == manifest.image.bytes else { return nil }
        return OfficialFactorySource(repository: "github.com/omacom/try-omarchy", releaseTag: tag, releaseURL: release, fileName: image.compressed.path,
                                     parts: parts, downloadBytes: total, imageSHA256: manifest.image.sha256,
                                     omarchyVersion: image.omarchy.split(separator: ".r").first.map(String.init) ?? image.omarchy,
                                     channel: image.channel, platform: image.platform,
                                     kernel: image.kernel.split(separator: "-").first.map(String.init) ?? image.kernel,
                                     built: ISO8601DateFormatter().date(from: image.built))
    }
}
