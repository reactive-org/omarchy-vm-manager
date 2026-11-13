import OmarchyVMManagerCore
import SwiftUI

/// One choice in the desktop layout picker, mapped onto the draft's layout mode.
enum DesktopLayoutCard: Hashable {
    case omarchyDefault, setupFolder, example(ProvisioningLayoutExampleID), customFile

    /// Reads the card a draft shows. With a bundled source, keeping the source's
    /// layout adds nothing, which is Omarchy's default; with a local folder it
    /// keeps whatever the folder names, and Omarchy default removes managed layouts.
    init(_ draft: ProvisioningAppearanceDraft, localSource: Bool) {
        switch draft.layoutMode {
        case "example": self = draft.layoutExample.map { .example($0) } ?? .omarchyDefault
        case "file": self = .customFile
        case "remove": self = .omarchyDefault
        default: self = localSource ? .setupFolder : .omarchyDefault
        }
    }
    func apply(to draft: inout ProvisioningAppearanceDraft, localSource: Bool) {
        switch self {
        case .omarchyDefault: draft.layoutMode = localSource ? "remove" : "source"
        case .setupFolder: draft.layoutMode = "source"
        case .example(let id): draft.layoutExample = id; draft.layoutMode = "example"
        case .customFile: draft.layoutMode = "file"
        }
    }
    var key: String {
        switch self {
        case .omarchyDefault: "omarchy-default"
        case .setupFolder: "setup-folder"
        case .example(let id): id.rawValue
        case .customFile: "custom-file"
        }
    }
}

/// Layout cards grouped by how many workspaces they arrange, each group one
/// horizontally scrolling row of fixed-width cards. A group appears only when it
/// has cards.
struct DesktopLayoutPicker: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @Binding var draft: ProvisioningAppearanceDraft
    let localSource: Bool
    let chooseFile: () -> Void
    @State private var examples: [ProvisioningLayoutExample] = []
    @State private var unavailable = false
    @State private var hovered: DesktopLayoutCard?

    private struct Entry: Identifiable {
        let card: DesktopLayoutCard
        let title: String
        let summary: String
        let needs: String
        var windows: [ProvisioningLayoutWindow] = []
        var workspaces = 1
        var id: String { card.key }
    }

    private var selected: DesktopLayoutCard { DesktopLayoutCard(draft, localSource: localSource) }
    private var exampleEntries: [Entry] {
        examples.map { Entry(card: .example($0.id), title: $0.title, summary: $0.summary,
                             needs: Self.needs($0), windows: $0.windows, workspaces: $0.workspaces) }
    }
    /// What setup does for the apps a layout arranges, from the dev-vm catalogue.
    /// The plan decides what is actually added; the review shows that.
    static func needs(_ example: ProvisioningLayoutExample) -> String {
        let installs = example.needs.filter { $0.feature != nil }.map(\.application)
        let missing = example.needs.filter { $0.feature == nil }.map(\.application)
        var parts: [String] = []
        if !installs.isEmpty { parts.append("Setup installs " + installs.joined(separator: " and ") + " if your profiles don’t") }
        if !missing.isEmpty { parts.append(missing.joined(separator: " and ") + (missing.count == 1 ? " isn’t" : " aren’t") + " installed by setup yet") }
        return parts.isEmpty ? "Nothing extra" : parts.joined(separator: " · ")
    }
    private var startEntries: [Entry] {
        var entries = [Entry(card: .omarchyDefault, title: "Omarchy default",
                             summary: localSource ? "Omarchy’s standard tiling. Removes a layout the manager applied earlier; your folder’s layout isn’t used."
                                                  : "Omarchy’s standard tiling. Apps open where you launch them; no layout file is added.",
                             needs: "Nothing extra")]
        if localSource {
            entries.append(Entry(card: .setupFolder, title: "From your setup folder", summary: "Uses the layout your vm.yml names, if any.", needs: "Your setup folder"))
        }
        let file = draft.layoutFile?.lastPathComponent
        entries.append(Entry(card: .customFile, title: "Custom file",
                             summary: file.map { $0 + " · copied into the reviewed inputs. Lua runs in the guest desktop, so choose a file you trust." }
                                ?? "Use your own Omarchy layout file. Lua runs in the guest desktop, so choose a file you trust.",
                             needs: "Your apps"))
        return entries
    }
    private var shown: Entry? {
        let all = exampleEntries + startEntries
        return all.first { $0.card == hovered } ?? all.first { $0.card == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let single = exampleEntries.filter { $0.workspaces == 1 }, several = exampleEntries.filter { $0.workspaces > 1 }
            if !single.isEmpty { group("one workspace", single) }
            if !several.isEmpty { group("several workspaces", several) }
            if unavailable {
                Text("The bundled layout examples are unavailable. Check the setup resources.").font(Theme.note).foregroundStyle(Theme.amber)
            }
            group("or start from", startEntries)
            detail
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear { bindAcceptance(acceptance, localSource: localSource) }
                .onChange(of: localSource) { _, value in bindAcceptance(acceptance, localSource: value) }
            }
            #endif
        }
        .task {
            do { examples = try BundledProvisioning.layoutExamples(); unavailable = false }
            catch { examples = []; unavailable = true }
        }
    }

    #if DEBUG
    private func bindAcceptance(_ acceptance: SetupUIAcceptanceDriver, localSource: Bool) {
        acceptance.bind("layout-cards", action: { command in
            if case .layoutExample(let value) = command {
                (value.map { DesktopLayoutCard.example($0) } ?? .omarchyDefault).apply(to: &draft, localSource: localSource)
            }
        }, snapshot: { ["count": String(examples.count), "cards": (exampleEntries + startEntries).map(\.id).joined(separator: ","),
                        "selection": draft.layoutMode == "example" ? draft.layoutExample?.rawValue ?? "" : ""] })
    }
    #endif

    private static let cardWidth: CGFloat = 150

    private func group(_ label: String, _ entries: [Entry]) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    let overflows = CGFloat(entries.count) * (Self.cardWidth + 8) - 8 > geometry.size.width
                    HStack(spacing: 8) {
                        Text(label).font(Theme.mono(11)).foregroundStyle(.secondary)
                        Text("\(entries.count)").font(Theme.mono(11)).foregroundStyle(Theme.label)
                        Rectangle().fill(Theme.border).frame(height: 1)
                        if overflows {
                            arrow("chevron.left", "Scroll \(label) to the start") { withAnimation { proxy.scrollTo(entries.first?.id, anchor: .leading) } }
                            arrow("chevron.right", "Scroll \(label) to the end") { withAnimation { proxy.scrollTo(entries.last?.id, anchor: .trailing) } }
                        }
                    }.frame(height: 20)
                }.frame(height: 20)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(entries) { entry in card(entry).id(entry.id) }
                    }.padding(.vertical, 2).scrollTargetLayout()
                }
                // The row's arrows and trackpad scrolling move it; an overlay scroller would cover the cards.
                .scrollIndicators(.never)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func arrow(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.8))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.strongBorder))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func card(_ entry: Entry) -> some View {
        let isSelected = selected == entry.card
        return Button {
            if entry.card == .customFile && draft.layoutFile == nil { chooseFile() }
            else { entry.card.apply(to: &draft, localSource: localSource) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(entry)
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12)).foregroundStyle(isSelected ? Theme.green : Theme.label)
                    Text(entry.title).font(Theme.sans(13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                }
            }
            .padding(8).frame(width: Self.cardWidth, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.green.opacity(0.07) : Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.green : hovered == entry.card ? Theme.strongBorder : Theme.border,
                                                                      style: StrokeStyle(lineWidth: 1, dash: entry.card == .customFile && !isSelected ? [4, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hovered = entry.card } else if hovered == entry.card { hovered = nil } }
        .accessibilityIdentifier("setup.layout." + entry.id)
        .accessibilityLabel(entry.title + ". " + entry.summary + " " + entry.needs)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func thumbnail(_ entry: Entry) -> some View {
        switch entry.card {
        case .example: LayoutExampleWireframe(windows: entry.windows, workspaces: entry.workspaces)
        case .omarchyDefault:
            screen { FrameMark(size: 34) }
        case .setupFolder:
            screen { Text("vm.yml").font(Theme.mono(11)).foregroundStyle(.secondary) }
        case .customFile:
            screen(dashed: true) {
                Text(draft.layoutFile?.lastPathComponent ?? "Choose .lua…").font(Theme.mono(11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 6)
            }
        }
    }
    private func screen<Content: View>(dashed: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay { content() }
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            .accessibilityHidden(true)
    }

    private var detail: some View {
        let previewing = shown != nil && shown?.card != selected
        return VStack(alignment: .leading, spacing: 2) {
            if let shown {
                HStack(spacing: 8) {
                    Text(shown.title).font(Theme.sans(13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(previewing ? "preview" : "selected").font(Theme.mono(11)).foregroundStyle(previewing ? Theme.lavender : Theme.green)
                }
                Text(shown.summary).font(Theme.note).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                Text(shown.needs).font(Theme.note).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.pane))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(previewing ? Theme.strongBorder : Theme.green.opacity(0.35)))
        .accessibilityHidden(true)
    }
}

/// Draws workspace 1; a layout with more workspaces says how many in the corner.
private struct LayoutExampleWireframe: View {
    let windows: [ProvisioningLayoutWindow]
    var workspaces = 1
    var body: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(windows.filter { $0.workspaceNumber == 1 }.enumerated()), id: \.offset) { _, window in
                            tile(window)
                                .frame(width: geometry.size.width * window.width, height: geometry.size.height * window.height)
                                .offset(x: geometry.size.width * window.x, y: geometry.size.height * window.y)
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if workspaces > 1 {
                    Text("1 of \(workspaces)").font(Theme.mono(8, weight: .medium)).foregroundStyle(Theme.text.opacity(0.85))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Theme.ground.opacity(0.92)))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.strongBorder))
                        .padding(3)
                }
            }
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func tile(_ window: ProvisioningLayoutWindow) -> some View {
        let floating = window.floating == true
        return Text(window.label).font(Theme.mono(8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 2).fill(floating ? Theme.strongBorder.opacity(0.5) : Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(floating ? Theme.lavender.opacity(0.6) : Theme.strongBorder))
            .shadow(color: .black.opacity(floating ? 0.4 : 0), radius: 3, y: 2)
            .padding(1)
    }
}
