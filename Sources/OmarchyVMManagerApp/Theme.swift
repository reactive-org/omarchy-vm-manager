import AppKit
import SwiftUI

/// Shared look for the manager window: a tiling-window-manager palette with
/// small radii. Light values exist so offscreen appearance checks stay legible;
/// the manager window itself is pinned to dark.
enum Theme {
    static let ground = dynamic(dark: 0x0D0E14, light: 0xF1F2F6)
    static let pane = dynamic(dark: 0x161822, light: 0xFFFFFF)
    static let border = dynamic(dark: 0x292B3A, light: 0xD7D9E3)
    static let strongBorder = dynamic(dark: 0x3D4055, light: 0xB9BCCB)
    static let label = dynamic(dark: 0x9093A6, light: 0x5C5F73)
    static let green = dynamic(dark: 0x9ECE6A, light: 0x4F7A1F)
    static let onGreen = dynamic(dark: 0x12160C, light: 0xFFFFFF)
    static let lavender = dynamic(dark: 0xB5ABFC, light: 0x5B4BC4)
    static let idleFrame = dynamic(dark: 0x4D5068, light: 0xB9BCCB)
    static let quietFrame = dynamic(dark: 0x34364A, light: 0xD7D9E3)
    static let tracer = dynamic(dark: 0xEAF7D9, light: 0x2F4A12)
    static let paneRadius: CGFloat = 6
    static let controlRadius: CGFloat = 4
    static let gap: CGFloat = 8

    /// Supporting text. macOS's caption style is 10 pt, too small against the 14 pt body the design uses.
    static let note = Font.system(size: 12)
    static let body = Font.system(size: 14)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The one filled action on a surface; dark text keeps it legible on the green.
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onGreen)
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.green))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

/// Square state marker: lit while a guest has a session, outlined otherwise.
struct GuestStatusMarker: View {
    let active: Bool
    var body: some View {
        Group {
            if active { Rectangle().fill(Theme.green).shadow(color: Theme.green.opacity(0.75), radius: 4) }
            else { Rectangle().strokeBorder(Theme.label, lineWidth: 1.5) }
        }.frame(width: 7, height: 7).accessibilityHidden(true)
    }
}
