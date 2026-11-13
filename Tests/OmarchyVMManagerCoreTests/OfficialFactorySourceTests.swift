import CryptoKit
import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Official factory source — synthetic manifests only")
struct OfficialFactorySourceTests {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private let image = String(repeating: "e", count: 64)
    private func download(host: String = "github.com", owner: String = "omacom") throws -> Data {
        let base = "https://\(host)/\(owner)/try-omarchy/releases/download/v1.3.0/omarchy-aarch64-edge.img.zst"
        return try json(["format": 1, "kind": "try-omarchy-factory-download", "identity": String(repeating: "f", count: 64),
                         "image": ["bytes": 300, "sha256": image],
                         "parts": [["url": base + ".001", "bytes": 200, "sha256": String(repeating: "1", count: 64)],
                                   ["url": base + ".002", "bytes": 100, "sha256": String(repeating: "2", count: 64)]]])
    }
    private func factory() throws -> Data {
        try json(["format": 1, "omarchy": "4.0.0.r7235.g967bbdd-1", "kernel": "7.2.8-23", "built": "2026-10-23T17:35:41Z",
                  "channel": "edge", "platform": "aarch64", "compressed": ["path": "omarchy-aarch64-edge.img.zst", "sha256": image]])
    }
    private func lock(_ download: Data, _ factory: Data) throws -> Data {
        try json(["files": ["Contents/Resources/guest/download.json": sha(download), "Contents/Resources/guest/factory.json": sha(factory)]])
    }

    @Test func readsThePinnedOfficialRelease() throws {
        let d = try download(), f = try factory()
        let source = try #require(OfficialFactorySource.parse(download: d, factory: f, lockData: try lock(d, f)))
        #expect(source.repository == "github.com/omacom/try-omarchy" && source.releaseTag == "v1.3.0")
        #expect(source.releaseURL.absoluteString == "https://github.com/omacom/try-omarchy/releases/tag/v1.3.0")
        #expect(source.parts.map(\.name) == [".001", ".002"] && source.downloadBytes == 300 && source.imageSHA256 == image)
        #expect(source.omarchyVersion == "4.0.0" && source.kernel == "7.2.8" && source.built != nil)
        #expect(source.omarchyPackage == "4.0.0.r7235.g967bbdd-1" && source.omarchyLabel == "Omarchy development build r7235")
    }

    @Test func refusesManifestsThatDoNotMatchTheLock() throws {
        let d = try download(), f = try factory()
        #expect(OfficialFactorySource.parse(download: d, factory: f, lockData: try lock(try download(owner: "someone"), f)) == nil)
    }

    @Test func refusesPartsFromAnywhereElse() throws {
        for d in [try download(host: "example.com"), try download(owner: "someone")] {
            let f = try factory()
            #expect(OfficialFactorySource.parse(download: d, factory: f, lockData: try lock(d, f)) == nil)
        }
    }
}
