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

/// Loading routes. Both start and end in the front frame's top gap, where the
/// back frame's edge meets it, so laps chain without a jump. The back lap
/// climbs out of the gap, runs the back square, steps across to the front
/// frame's left edge and comes home along its far sides; the front lap runs the
/// whole front square.
private struct BackLap: Shape {
    func path(in rect: CGRect) -> Path {
        outline([(190, 44), (190, 10), (10, 10), (10, 190), (44, 190), (44, 284), (284, 284), (284, 44), (190, 44)], in: rect)
    }
}

private struct FrontLap: Shape {
    func path(in rect: CGRect) -> Path {
        outline([(190, 44), (44, 44), (44, 284), (284, 284), (284, 44), (190, 44)], in: rect)
    }
}

/// The app icon's two frames as a line drawing, with a slow tracer around the
/// front frame. `loading` marks busy states: the tracer alternates laps between
/// the back and front squares, the square it is on lights up, and a fading tail
/// follows it. All motion stops under Reduce Motion.
struct FrameMark: View {
    let size: CGFloat
    var frame = Theme.idleFrame
    var tracer: Color?
    var loading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // Keep the frames legible when the mark shrinks to a guest tile.
        let line = StrokeStyle(lineWidth: max(1.25, size * 7 / 300), lineCap: .round, lineJoin: .round)
        Group {
            if loading, let tracer, !reduceMotion {
                CyclingFrames(frame: frame, tracer: tracer, line: line)
            } else {
                ZStack {
                    BackFrame().stroke(Theme.quietFrame, style: line)
                    FrontFrame().stroke(frame, style: line)
                    if let tracer, !reduceMotion { FrameTracer(color: tracer, line: line) }
                }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A trimmed run of `shape` from `start` (0...1, wrapping) for `length`.
private func run<S: Shape>(_ shape: S, from start: Double, length: Double) -> Path {
    let path = shape.path(in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let head = start.truncatingRemainder(dividingBy: 1)
    var result = path.trimmedPath(from: max(0, head), to: min(1, head + length))
    if head + length > 1 { result.addPath(path.trimmedPath(from: 0, to: head + length - 1)) }
    return result
}

private struct FrameTracer: View {
    let color: Color
    let line: StrokeStyle
    private let length = 0.14
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let start = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7) / 7
            ZStack {
                FrontFrame().trim(from: start, to: min(start + length, 1)).stroke(color, style: line)
                if start + length > 1 { FrontFrame().trim(from: 0, to: start + length - 1).stroke(color, style: line) }
            }
        }
    }
}

/// Loading style: lap 1 runs through the back square, lap 2 the front square.
/// The square being traced brightens while the other recedes, so the two take
/// turns in front.
private struct CyclingFrames: View {
    let frame: Color
    let tracer: Color
    let line: StrokeStyle
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            CyclingFramesFrame(time: context.date.timeIntervalSinceReferenceDate, frame: frame, tracer: tracer, line: line)
        }
    }
}

/// One frame of the loading style at `time`; separate so renders can sample it.
struct CyclingFramesFrame: View {
    let time: Double
    let frame: Color
    let tracer: Color
    let line: StrokeStyle
    static let lap = 1.9
    private static let tail = 0.3
    private static let pieces = 14

    var body: some View {
        let lapIndex = Int(time / Self.lap) % 2
        let progress = time.truncatingRemainder(dividingBy: Self.lap) / Self.lap
        // Eased so the tracer gathers speed out of the gap and settles back into it.
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        let onBack = lapIndex == 0
        // How lit each square is (0...1); they hand over around each pass through the gap.
        let edge = 0.16
        let fade = progress < edge ? progress / edge : progress > 1 - edge ? (1 - progress) / edge : 1
        let backLit = onBack ? fade : 0.0, frontLit = onBack ? 0.0 : fade
        // A short pulse as the tracer leaves the gap at the start of each lap.
        let pulse = max(0, 1 - progress / 0.12)
        Canvas { canvas, size in
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            let scale = CGAffineTransform(scaleX: size.width, y: size.height)
            func stroke(_ path: Path, _ color: Color, _ opacity: Double, widen: CGFloat = 1, cap: CGLineCap? = nil) {
                guard opacity > 0.001 else { return }
                var style = line
                style.lineWidth *= widen
                if let cap { style.lineCap = cap }
                canvas.stroke(path.applying(scale), with: .color(color.opacity(opacity)), style: style)
            }
            let back = BackFrame().path(in: unit), front = FrontFrame().path(in: unit)
            // The resting square recedes; the square being traced takes a green tint.
            stroke(back, Theme.quietFrame, 1)
            stroke(back, frame, 0.35 * (1 - backLit))
            stroke(back, tracer, 0.42 * backLit)
            stroke(front, Theme.quietFrame, 1)
            stroke(front, frame, 1 - frontLit * 0.4 - backLit * 0.55)
            stroke(front, tracer, 0.42 * frontLit)
            let lit = onBack ? back : front
            stroke(lit, tracer, 0.35 * pulse, widen: 2.4)
            // One smooth tail: overlapping butt-capped pieces, older ones thinner and dimmer.
            let piece = Self.tail / Double(Self.pieces)
            for index in 0..<Self.pieces {
                let start = eased - Self.tail + Double(index) * piece
                let strength = pow(Double(index + 1) / Double(Self.pieces), 1.6)
                let path = onBack ? run(BackLap(), from: start + 1, length: piece * 1.6) : run(FrontLap(), from: start + 1, length: piece * 1.6)
                stroke(path, tracer, 0.1 + 0.9 * strength, widen: 0.45 + 0.65 * strength, cap: .butt)
            }
            let head = onBack ? run(BackLap(), from: eased + 1 - piece, length: piece) : run(FrontLap(), from: eased + 1 - piece, length: piece)
            stroke(head, tracer, 0.22, widen: 3)
            stroke(head, Theme.tracer, 1, widen: 1.1)
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
                Text("Your Omarchy virtual machines").font(Theme.sans(26, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
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
                            FrameMark(size: 240, frame: activeCount > 0 ? Theme.green : Theme.idleFrame, tracer: activeCount > 0 ? Theme.tracer : Theme.lavender.opacity(0.7))
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
                    Text("No guests yet").font(Theme.sans(24, weight: .semibold))
                    Text("Create an independent guest with its own disk, settings and clipboard.")
                        .foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 16)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(action: newVM) { Label("New VM", systemImage: "plus") }
                            .buttonStyle(.primaryAction).disabled(!canCreate)
                        Button(action: importFactory) { Label("Import factory", systemImage: "square.and.arrow.down") }
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
                Text(text).font(Theme.sans(13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
