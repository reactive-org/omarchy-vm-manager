import OmarchyVMManagerCore
import SwiftUI

struct ProvisioningLayoutExampleCards: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @Binding var selection: ProvisioningLayoutExampleID?
    @State private var examples: [ProvisioningLayoutExample] = []
    @State private var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(examples) { example in card(example) }
            }
            if unavailable { Text("The bundled layout examples are unavailable. Check the setup resources.").font(.caption).foregroundStyle(.orange) }
            Text("Illustrative previews · workspace 1. These layouts open the listed apps; make sure they’re installed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("layout-cards", action: { command in
                    if case .layoutExample(let value) = command { selection = value }
                }, snapshot: { ["count": String(examples.count), "selection": selection?.rawValue ?? ""] })
            } }
            #endif
        }
        .task {
            do { examples = try BundledProvisioning.layoutExamples(); unavailable = false }
            catch { examples = []; unavailable = true }
        }
    }
    private func card(_ example: ProvisioningLayoutExample) -> some View {
        let selected = selection == example.id
        return Button { selection = example.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                LayoutExampleWireframe(windows: example.windows, selected: selected)
                HStack(spacing: 5) {
                    Text(example.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }.frame(height: 20)
                Text(example.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(height: 32, alignment: .topLeading)
                Text("Needs " + example.applications.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .topLeading)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.65), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.layout-example." + example.id.rawValue)
        .accessibilityLabel(example.title + ". " + example.summary + " Needs " + example.applications.joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help(example.summary + " The bundled Lua file is saved with your preview. Apps are not installed by choosing a layout.")
    }
}
private struct LayoutExampleWireframe: View {
    let windows: [ProvisioningLayoutWindow]
    let selected: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    windowFrame(window)
                        .frame(width: geometry.size.width * window.width, height: geometry.size.height * window.height)
                        .offset(x: geometry.size.width * window.x, y: geometry.size.height * window.y)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func windowFrame(_ window: ProvisioningLayoutWindow) -> some View {
        let floating = window.floating == true
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: symbol(window.kind)).font(.system(size: 8))
                Text(window.label).font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }.foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            Spacer(minLength: 0)
        }
        .padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor.opacity(floating ? 0.9 : 0.6) : Color.secondary.opacity(floating ? 0.7 : 0.45), lineWidth: floating ? 1.5 : 1))
        .shadow(color: .black.opacity(floating ? 0.2 : 0), radius: 3, y: 1)
    }
    private func symbol(_ kind: ProvisioningLayoutWindow.Kind) -> String {
        switch kind { case .terminal: "terminal"; case .browser: "globe"; case .editor: "chevron.left.forwardslash.chevron.right"; case .claude: "sparkle" }
    }
}
