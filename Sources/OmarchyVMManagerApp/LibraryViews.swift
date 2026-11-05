import OmarchyVMManagerCore
import SwiftUI

private func outline(_ points: [(CGFloat, CGFloat)], in rect: CGRect) -> Path {
    let scale = rect.width / 300
    var path = Path()
    path.addLines(points.map { CGPoint(x: rect.minX + $0.0 * scale, y: rect.minY + $0.1 * scale) })
    return path
}

private struct BackFrame: Shape {
    func path(in rect: CGRect) -> Path { outline([(190, 34), (190, 10), (10, 10), (10, 190), (34, 190)], in: rect) }
}

private struct FrontFrame: Shape {
    func path(in rect: CGRect) -> Path { outline([(172, 44), (44, 44), (44, 284), (284, 284), (284, 44), (216, 44)], in: rect) }
}

/// The app icon's two frames as a line drawing, with a slow tracer around the
/// front frame. The tracer stops under Reduce Motion.
struct FrameMark: View {
    let size: CGFloat
    var frame = Theme.idleFrame
    var tracer: Color?
    var body: some View {
        let line = StrokeStyle(lineWidth: size * 7 / 300)
        ZStack {
            BackFrame().stroke(Theme.quietFrame, style: line)
            FrontFrame().stroke(frame, style: line)
            if let tracer { FrameTracer(color: tracer, line: line) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct FrameTracer: View {
    let color: Color
    let line: StrokeStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let length = 0.14
    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let start = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7) / 7
                ZStack {
                    FrontFrame().trim(from: start, to: min(start + length, 1)).stroke(color, style: line)
                    if start + length > 1 { FrontFrame().trim(from: 0, to: start + length - 1).stroke(color, style: line) }
                }
            }
        }
    }
}

struct LibraryHeader: View {
    let activeCount: Int
    let allocatedGiB: Int
    let guestCount: Int

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Your Omarchy virtual machines").font(.system(size: 26, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if AppChannel.current == .development {
                    Text("DEV").font(Theme.mono(11, weight: .medium)).foregroundStyle(Theme.onGreen)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.lavender, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            OmarchyAttribution()
        }
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Theme.mono(24, weight: .medium)).foregroundStyle(tint)
            Text(label).font(Theme.note).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func inlineStat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(Theme.mono(20, weight: .medium))
            Text(label).font(Theme.note).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    var body: some View {
        GroupedPanel {
            if guestCount == 0 {
                HStack(spacing: 32) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    inlineStat("\(activeCount)", "active")
                    inlineStat("\(allocatedGiB) GiB", "allocated")
                }.padding(.horizontal, 24).padding(.vertical, 16)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    title
                    HStack(spacing: 32) {
                        stat("\(activeCount)", "active", tint: activeCount > 0 ? Theme.green : .primary)
                        stat("\(allocatedGiB) GiB", "allocated")
                        stat("\(guestCount)", "guests")
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topTrailing) {
                    // Drawn only when the title has room beside it.
                    GeometryReader { space in
                        if space.size.width >= 720 {
                            FrameMark(size: 240, frame: activeCount > 0 ? Theme.green : Theme.idleFrame, tracer: activeCount > 0 ? Theme.tracer : nil)
                                .offset(x: space.size.width - 288, y: 16)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.paneRadius))
            }
        }
    }
}

/// Shown in place of the guest list until the first guest exists.
struct FirstGuestPanel: View {
    let canCreate: Bool
    let canImport: Bool
    let newVM: () -> Void
    let importFactory: () -> Void
    let openDefaults: () -> Void
    let openRuntime: () -> Void
    let openPermissions: () -> Void

    var body: some View {
        GroupedPanel {
            HStack(spacing: 36) {
                ZStack {
                    FrameMark(size: 188, tracer: Theme.lavender)
                    Image(systemName: "plus").font(.system(size: 44, weight: .regular)).foregroundStyle(Theme.green).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("virtual machines").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green)
                    Rectangle().fill(Theme.strongBorder).frame(height: 1).padding(.top, 8).padding(.bottom, 10)
                    Text("No guests yet").font(.system(size: 24, weight: .semibold))
                    Text("Create an independent guest with its own disk, settings and clipboard.")
                        .foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 16)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(action: newVM) { Label("New VM", systemImage: "plus") }
                            .buttonStyle(.primaryAction).disabled(!canCreate)
                        Button(action: importFactory) { Label("Import Factory", systemImage: "square.and.arrow.down") }
                            .controlSize(.large).disabled(!canImport)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 28).padding(.vertical, 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("before you start").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                StartRow(key: "guest defaults", text: "Save account details once for new virtual machines.", action: openDefaults)
                StartRow(key: "runtime", text: "Review the Try Omarchy kit the manager uses.", action: openRuntime)
                StartRow(key: "permissions", text: "Enable permissions yourself in System Settings.", action: openPermissions)
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

private struct StartRow: View {
    let key: String
    let text: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 132, alignment: .leading)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
