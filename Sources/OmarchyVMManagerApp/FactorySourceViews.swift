import OmarchyVMManagerCore
import SwiftUI
import TryOmarchyKitClient

/// Where the official image comes from: release, parts, checksums and contents,
/// all read from the kit's pinned manifests.
struct FactorySourceDetails: View {
    let source: OfficialFactorySource
    var compact = false
    private static let size = ByteCountFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("from") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { link; Text(" · release " + source.releaseTag).font(Theme.mono(compact ? 13 : 14)) }
                    VStack(alignment: .leading, spacing: 2) { link; Text("release " + source.releaseTag).font(Theme.mono(compact ? 13 : 14)) }
                }
                if !compact { note("Omacom’s official Try Omarchy release on GitHub. This image is downloaded only from there.") }
            }
            row(compact ? "size" : "file") {
                if compact {
                    Text(Self.size.string(fromByteCount: source.downloadBytes) + " download · \(source.parts.count) parts").font(Theme.mono(13))
                } else {
                    (Text(source.fileName).font(Theme.mono(14)) + Text(" · \(source.parts.count) parts · " + Self.size.string(fromByteCount: source.downloadBytes)).font(Theme.sans(13)).foregroundColor(.secondary))
                    HStack(spacing: 14) {
                        ForEach(source.parts, id: \.name) { part in
                            Text(part.name + "  " + Self.size.string(fromByteCount: part.bytes)).font(Theme.mono(12)).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 2)
                }
            }
            row("checked") {
                Text(compact ? "SHA-256 for every part and the image, pinned in this app" : "Against SHA-256 checksums pinned in this app")
                    .font(compact ? Theme.sans(13) : Theme.mono(14))
                if !compact {
                    note("Each part and the joined image must match before use. A mismatch stops and discards the download; nothing unverified is used.")
                    Text("image sha256 " + source.imageSHA256).font(Theme.mono(11)).foregroundStyle(Theme.label).textSelection(.enabled).padding(.top, 2)
                }
            }
            row("contains") {
                let built = source.built.map { " · built " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                Text("Omarchy \(source.omarchyVersion) · \(source.channel)" + (compact ? built : " · \(source.platform) · kernel \(source.kernel)" + built))
                    .font(compact ? Theme.sans(13) : Theme.mono(14))
            }
        }
    }

    private var link: some View {
        Link(source.repository, destination: source.releaseURL)
            // Truncate rather than fix the width: a fixed-size link is wider
            // than a narrow grid cell and pushes the whole card off the edge.
            .buttonStyle(.plain).font(Theme.mono(compact ? 13 : 14)).foregroundStyle(Theme.lavender).lineLimit(1).truncationMode(.middle)
            .help(source.releaseURL.absoluteString)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func row<Content: View>(_ key: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Theme.mono(compact ? 13 : 14)).foregroundStyle(Theme.lavender).frame(width: compact ? 70 : 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, compact ? 6 : 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct OfficialSourceBadge: View {
    var compact = false
    var body: some View {
        Label(compact ? "Official release" : "Official release · checksums pinned", systemImage: "checkmark.shield")
            .lineLimit(1).fixedSize()
            .font(Theme.mono(11, weight: .medium)).foregroundStyle(Theme.green)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.green.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.green.opacity(0.4)))
    }
}

/// The guest's Home tab while its official factory image downloads or is verified.
struct GuestFactoryDownloadCard: View {
    let source: OfficialFactorySource
    let phase: VMRunPhase
    let percent: Int?

    static func phase(_ snapshot: VMSnapshot) -> (VMRunPhase, Int?)? {
        guard snapshot.profile.factory == .official || snapshot.profile.factory == nil,
              case .downloading(let phase, let percent) = snapshot.state,
              [.waitingForDownload, .downloading, .reconnecting, .paused, .verifyingDownload].contains(phase) else { return nil }
        return (phase, percent)
    }

    private var title: String {
        switch phase {
        case .waitingForDownload: "Waiting to download the official Try Omarchy image"
        case .reconnecting: "Reconnecting to download the official Try Omarchy image"
        case .paused: "Paused until a connection that isn’t cellular or Low Data Mode"
        case .verifyingDownload: "Verifying the official Try Omarchy image"
        default: "Downloading the official Try Omarchy image"
        }
    }
    private var amount: String {
        let size = ByteCountFormatter()
        guard let percent else { return size.string(fromByteCount: source.downloadBytes) }
        if phase == .verifyingDownload { return size.string(fromByteCount: source.downloadBytes) + " · checking" }
        return size.string(fromByteCount: source.downloadBytes * Int64(percent) / 100) + " of " + size.string(fromByteCount: source.downloadBytes) + " · \(percent)%"
    }

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("factory image").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.lavender).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    OfficialSourceBadge()
                }.padding(.bottom, 10)
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Theme.sans(15, weight: .medium))
                    Spacer(minLength: 12)
                    Text(amount).font(Theme.mono(13)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(percent ?? 0), total: 100).tint(Theme.green).padding(.vertical, 8)
                    .accessibilityLabel("Download progress")
                FactorySourceDetails(source: source)
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        }
        .overlay { RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.lavender.opacity(0.6)) }
        .accessibilityIdentifier("guest.factory-download")
    }
}

#if DEBUG
import CryptoKit
extension OfficialFactorySource {
    /// Synthetic manifests shaped like the kit's, for offscreen acceptance only.
    static func acceptanceFixture() -> OfficialFactorySource? {
        func data(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data() }
        func sha(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let image = String(repeating: "e", count: 64)
        let base = "https://github.com/omacom/try-omarchy/releases/download/v1.3.0/omarchy-aarch64-edge.img.zst"
        let download = data(["format": 1, "kind": "try-omarchy-factory-download", "image": ["bytes": 3_172_067_004, "sha256": image],
                             "parts": [["url": base + ".001", "bytes": 1_073_741_824, "sha256": image], ["url": base + ".002", "bytes": 1_073_741_824, "sha256": image],
                                       ["url": base + ".003", "bytes": 1_024_583_356, "sha256": image]]])
        let factory = data(["omarchy": "4.0.0.r7235.g967bbdd-1", "kernel": "7.2.8-23", "built": "2026-10-23T17:35:41Z", "channel": "edge",
                            "platform": "aarch64", "compressed": ["path": "omarchy-aarch64-edge.img.zst", "sha256": image]])
        let lock = data(["files": ["Contents/Resources/guest/download.json": sha(download), "Contents/Resources/guest/factory.json": sha(factory)]])
        return parse(download: download, factory: factory, lockData: lock)
    }
}
#endif
