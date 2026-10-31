import CryptoKit
import Darwin
import Foundation
import TryOmarchyKitClient

public enum KitBuildPolicy: Sendable { case debugPOC, release }

public struct RuntimeProvenance: Codable, Equatable, Sendable {
    public let format: Int
    public let upstreamBase: String
    public let patchCommit: String
    public let patchSHA256: String
    public let referenceKitSHA256: String
    public let kitSHA256: String
    public let kitVersion: String
    public let runProtocolVersion: Int
    public let buildDate: String
    public let focusAwareClipboard: Bool
    public var managedSSHVersion: Int? = nil
    public let composition: String
    public let files: [String: String]
}

public struct KitDiagnostics: Equatable, Sendable {
    public let kitPath: String
    public let version: String
    public let runProtocolVersion: Int
    public let supported: Bool
    public let patchCommit: String
    public let archiveSHA256: String
    public let focusAwareClipboard: Bool
    public let preflightFailure: String?
}

public enum UpstreamBaseline {
    public static let commit = "13d63df8da2947f833c04025ff5ade187d39ba81"
    public static let stockSHA256 = "3ad65381b34ced2ebe3f5f19b95d58ec1a2c51a77a6edf7599666a939b6991a6"
}

public enum ClipboardCapabilityPolicy {
    public static func validate(focusAware: Bool, clipboardEnabled: Bool, activeClipboardSessions: Int) throws {
        guard !clipboardEnabled || focusAware else {
            throw VMFailure(code: "unproven-clipboard-runtime",
                            message: activeClipboardSessions > 0
                                ? "Concurrent clipboard sessions require the pinned focus-aware kit."
                                : "Clipboard requires the pinned focus-aware kit.")
        }
    }
}

public enum KitVerifier {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func inspect(kit: TryOmarchyKit, lockData: Data, expectedLockSHA256: String,
                               policy: KitBuildPolicy,
                               preflight: () -> VMRunError? = { VMRunClient.preflight() }) throws -> KitDiagnostics {
        guard sha256(lockData) == expectedLockSHA256 else { throw invalid("The runtime lock does not match the compiled pin.") }
        let lock = try JSONDecoder().decode(RuntimeProvenance.self, from: lockData)
        try validate(lock, policy: policy)
        _ = try kit.helperURL()
        let manifest = try kit.manifest()
        guard manifest.isSupported, manifest.runProtocolVersion == lock.runProtocolVersion,
              manifest.version.description == lock.kitVersion,
              ISO8601DateFormatter().string(from: manifest.buildDate) == lock.buildDate else {
            throw invalid("The embedded kit manifest differs from the pinned runtime.")
        }
        let actualFiles = try inventory(at: kit.bundleURL)
        guard actualFiles == lock.files else { throw invalid("The embedded kit files differ from the verified runtime archive.") }
        return KitDiagnostics(kitPath: kit.bundleURL.path, version: manifest.version.description,
                              runProtocolVersion: manifest.runProtocolVersion, supported: manifest.isSupported,
                              patchCommit: lock.patchCommit, archiveSHA256: lock.kitSHA256,
                              focusAwareClipboard: lock.focusAwareClipboard,
                              preflightFailure: preflight()?.message)
    }

    public static func validate(_ lock: RuntimeProvenance, policy: KitBuildPolicy) throws {
        func hex(_ text: String, count: Int) -> Bool {
            text.count == count && text.allSatisfy { $0.isASCII && (("0"..."9").contains($0) || ("a"..."f").contains($0)) }
        }
        guard lock.format == 1, lock.upstreamBase == UpstreamBaseline.commit,
              lock.referenceKitSHA256 == UpstreamBaseline.stockSHA256,
              hex(lock.patchCommit, count: 40), lock.patchCommit != lock.upstreamBase,
              hex(lock.patchSHA256, count: 64), hex(lock.kitSHA256, count: 64),
              lock.kitSHA256 != UpstreamBaseline.stockSHA256,
              lock.runProtocolVersion == VMRunProtocol.version, lock.focusAwareClipboard,
              !lock.files.isEmpty, lock.files.keys.contains(TryOmarchyKit.helperPath),
              lock.files.keys.contains(TryOmarchyKit.manifestPath),
              lock.files.values.allSatisfy({ hex($0, count: 64) }) else {
            throw invalid("The runtime provenance or focus-aware clipboard capability is unproven.")
        }
        if let version = lock.managedSSHVersion {
            guard version == 1, lock.files.keys.contains("Contents/Resources/guest-packages/try-omarchy-0.1.0-39-aarch64.pkg.tar.zst") else {
                throw invalid("Managed SSH provisioning capability is unknown or its guest package is missing.")
            }
        }
        switch policy {
        case .debugPOC:
            guard lock.kitVersion == "development" else { throw invalid("This POC requires its exact development kit.") }
        case .release:
            throw invalid("Release builds require an official reviewed focus-aware release. The private development kit is refused.")
        }
    }

    public static func inventory(at root: URL) throws -> [String: String] {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw invalid("The kit bundle must be a real directory.")
        }
        var files: [String: String] = [:]
        var pending: [(url: URL, relative: String)] = [(root, "")]
        while let directory = pending.popLast() {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.url.path) {
                let path = directory.url.appendingPathComponent(name)
                let relative = directory.relative.isEmpty ? name : directory.relative + "/" + name
                guard lstat(path.path, &info) == 0 else { throw invalid("A kit entry cannot be inspected.") }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    files[relative] = sha256(try Data(contentsOf: path, options: .mappedIfSafe))
                case S_IFDIR:
                    pending.append((path, relative))
                default:
                    throw invalid("Symlinks and special files are not permitted in the pinned kit.")
                }
            }
        }
        return files
    }

    private static func invalid(_ message: String) -> VMFailure {
        VMFailure(code: "kit-provenance-invalid", message: message)
    }
}
