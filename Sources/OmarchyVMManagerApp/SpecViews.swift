import SwiftUI

/// Bordered action for everything that is not the surface's one primary action.
struct QuietActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        configuration.label
            .font(Theme.sans(13, weight: .medium))
            .foregroundStyle(destructive ? Color.red : Theme.text)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(configuration.isPressed ? Theme.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(destructive ? Color.red.opacity(0.5) : Theme.strongBorder))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Sidebar row: a green outline marks the selection instead of the system highlight.
struct SidebarRowButtonStyle: ButtonStyle {
    let selected: Bool
    let focused: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        configuration.label
            .font(Theme.body).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.green.opacity(focused ? 0.12 : 0.07) : configuration.isPressed || hovering ? Theme.text.opacity(0.06) : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? (focused ? Theme.green : Theme.green.opacity(0.55)) : .clear))
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == QuietActionButtonStyle {
    static var quietAction: QuietActionButtonStyle { QuietActionButtonStyle() }
}

struct SpecSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(configuration.isOn ? Theme.green.opacity(0.14) : Theme.border)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(configuration.isOn ? Theme.green : Theme.strongBorder)
                    RoundedRectangle(cornerRadius: 2).fill(configuration.isOn ? Theme.green : Theme.label).frame(width: 12, height: 12).padding(.horizontal, 4)
                }.frame(width: 36, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// Compact key–value line for summary panes, without the row dividers of SpecRow.
struct SpecLine: View {
    let key: String
    let value: String
    var note: String?
    var tint: Color?
    init(_ key: String, value: String, note: String? = nil, tint: Color? = nil) { self.key = key; self.value = value; self.note = note; self.tint = tint }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
            Text(value).font(Theme.mono(14)).foregroundStyle(tint ?? Theme.text).textSelection(.enabled)
            // Explanations stay out of the list and appear on hover; the marker makes them discoverable.
            if note != nil { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.label).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .help(note ?? "")
        .accessibilityElement(children: .combine).accessibilityHint(note ?? "")
    }
}

/// A menu picker drawn as a spec field (dark well, mono value, chevrons) instead of the grey pop-up button.
struct SpecMenuPicker<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let label: String
    @ViewBuilder let options: Options
    init(_ title: String, selection: Binding<Value>, label: String, @ViewBuilder options: () -> Options) {
        self.title = title; _selection = selection; self.label = label; self.options = options()
    }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(label).font(Theme.mono(13)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.strongBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(title).accessibilityValue(label)
    }
}

extension View {
    /// Text entry in the spec sheet's monospaced style.
    func specField() -> some View {
        textFieldStyle(.plain).font(Theme.mono(13)).padding(.horizontal, 10).frame(height: 30)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.strongBorder))
    }
}

struct SpecHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green).accessibilityAddTraits(.isHeader)
    }
}

struct SpecNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line of a spec sheet: a lavender key, optional value and note, then controls.
struct SpecRow<Trailing: View>: View {
    let key: String
    var value: String?
    var note: String?
    @ViewBuilder let trailing: Trailing
    init(_ key: String, value: String? = nil, note: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.key = key; self.value = value; self.note = note; self.trailing = trailing()
    }
    var body: some View {
        // Notes sit beside the value when there is room; beside a wide control they drop to their
        // own line rather than being squeezed to a sliver.
        ViewThatFits(in: .horizontal) {
            row(inlineNote: true)
            row(inlineNote: false)
        }
        .padding(.vertical, 6).frame(minHeight: 40)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func row(inlineNote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 12) {
                Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 132, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: 0)
                    if let value { Text(value).font(Theme.mono(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let note, inlineNote { noteText(note) }
                }.frame(minWidth: inlineNote && note != nil && hasControl ? 220 : 0, maxWidth: .infinity, alignment: .leading)
                trailing.layoutPriority(1)
            }
            if let note, !inlineNote { noteText(note).padding(.leading, 144) }
        }
    }
}

extension SpecRow {
    private var hasControl: Bool { Trailing.self != EmptyView.self }
    private func noteText(_ note: String) -> some View {
        Text(note).font(Theme.sans(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension SpecRow where Trailing == EmptyView {
    init(_ key: String, value: String? = nil, note: String? = nil) { self.init(key, value: value, note: note) { EmptyView() } }
}

struct SpecToggleRow: View {
    let key: String
    var note: String?
    @Binding var isOn: Bool
    init(_ key: String, note: String? = nil, isOn: Binding<Bool>) { self.key = key; self.note = note; _isOn = isOn }
    var body: some View {
        SpecRow(key, note: note) { Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(SpecSwitchToggleStyle()).accessibilityLabel(key) }
    }
}

struct SpecStepperRow: View {
    let key: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    init(_ key: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String = "") {
        self.key = key; _value = value; self.range = range; self.step = step; self.unit = unit
    }
    private func nudge(_ title: String, _ label: String, by delta: Int) -> some View {
        Button(title) { value = min(range.upperBound, max(range.lowerBound, value + delta)) }
            .buttonStyle(.plain).font(Theme.mono(14, weight: .medium)).frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.strongBorder))
            .contentShape(Rectangle())
            .disabled(delta < 0 ? value <= range.lowerBound : value >= range.upperBound)
            .accessibilityLabel(label + " " + key)
    }
    var body: some View {
        SpecRow(key) {
            HStack(spacing: 8) {
                nudge("−", "Decrease", by: -step)
                Text("\(value)\(unit)").font(Theme.mono(14)).frame(minWidth: 72).accessibilityLabel(key).accessibilityValue("\(value)\(unit)")
                nudge("+", "Increase", by: step)
            }
        }
    }
}

/// A pane with a green mono heading, optional action and spec rows.
struct SpecPane<Action: View, Content: View>: View {
    let title: String
    @ViewBuilder let action: Action
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder action: () -> Action, @ViewBuilder content: () -> Content) {
        self.title = title; self.action = action(); self.content = content()
    }
    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) { SpecHeading(title); Spacer(minLength: 0); action }
                    .frame(minHeight: 30).padding(.bottom, 8)
                content
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            // Rows only set a minimum height, so a stretched pane would spread them apart.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SpecPane where Action == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(title, action: { EmptyView() }, content: content) }
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing
    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        GroupedPanel {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(Theme.sans(26, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.init(title, subtitle: subtitle) { EmptyView() } }
}

/// A row that opens in place. Its content stays mounted while closed so edits
/// inside it survive, and it is disabled so closed controls take no focus.
struct DisclosurePaneRow<Content: View>: View {
    let key: String
    let summary: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    private let maximumHeight: CGFloat = 380
    var body: some View {
        VStack(spacing: 0) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        .rotationEffect(isOpen ? .degrees(90) : .zero).frame(width: 10).accessibilityHidden(true)
                    Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
                    Text(summary).font(Theme.sans(13)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20).frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityValue(summary).accessibilityHint(isOpen ? "Collapses this section" : "Expands this section")
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            ScrollView {
                content.padding(.leading, 40).padding(.trailing, 20).padding(.top, 2).padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            }
            .frame(height: isOpen ? min(contentHeight, maximumHeight) : 0).clipped()
            .background(Theme.ground.opacity(0.45))
            .disabled(!isOpen).accessibilityHidden(!isOpen)
        }
    }
}
