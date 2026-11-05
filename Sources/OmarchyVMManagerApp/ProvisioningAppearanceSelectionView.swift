import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum ProvisioningThemeChoice: String, CaseIterable {
    case source = "Keep", repository = "GitHub", random = "Random", popular = "Most starred"
}
struct ProvisioningAppearanceDraft: Equatable {
    var themeChoice: ProvisioningThemeChoice = .source
    var theme = ""
    var minimumStars = 10
    var layoutMode = "source"
    var layoutFile: URL?
    var layoutExample: ProvisioningLayoutExampleID?
    init() {}
    init(_ selection: ProvisioningAppearanceSelection?) {
        switch selection?.theme {
        case "random": themeChoice = .random
        case "most-starred": themeChoice = .popular
        case .some(let value): themeChoice = .repository; theme = value
        case .none: break
        }
        minimumStars = selection?.minimumStars ?? 10
        layoutFile = selection?.layoutFile.map { URL(fileURLWithPath: $0) }
        layoutExample = selection?.layoutExample
        layoutMode = selection?.removeLayout == true ? "remove" : layoutExample != nil ? "example" : layoutFile == nil ? "source" : "file"
    }
    var selection: ProvisioningAppearanceSelection? {
        let selector: String?
        switch themeChoice {
        case .source: selector = nil
        case .repository:
            let value = theme.trimmingCharacters(in: .whitespacesAndNewlines)
            selector = value.isEmpty ? nil : value
        case .random: selector = "random"
        case .popular: selector = "most-starred"
        }
        let value = ProvisioningAppearanceSelection(theme: selector, minimumStars: minimumStars,
            layoutFile: layoutMode == "file" ? layoutFile?.path : nil, removeLayout: layoutMode == "remove", layoutExample: layoutMode == "example" ? layoutExample : nil)
        return value.isEmpty ? nil : value
    }
    var failure: String? {
        if themeChoice == .repository, theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a GitHub repository URL." }
        if layoutMode == "example", layoutExample == nil { return "Choose a layout example." }
        if layoutMode == "file", layoutFile == nil { return "Choose a Lua layout file." }
        do { try selection?.validate(); return nil } catch { return ProvisioningAppearance.failureMessage(error) ?? "Check the theme and layout choices." }
    }
    var summary: String {
        let theme = themeChoice == .source ? nil : themeChoice == .repository ? "GitHub theme" : themeChoice.rawValue + " theme"
        let layout = layoutMode == "example" ? "Example layout" : layoutMode == "file" ? "Custom layout" : layoutMode == "remove" ? "Remove layout" : nil
        return [theme, layout].compactMap { $0 }.joined(separator: " · ")
    }
}
struct ProvisioningAppearanceSelectionView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @Binding var draft: ProvisioningAppearanceDraft
    @State private var expanded = false
    @State private var choosingLayout = false
    @State private var availableWidth: CGFloat = 0
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                let layout = availableWidth >= 680 && draft.layoutMode != "example" ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                layout { themePanel; layoutPanel }.fixedSize(horizontal: false, vertical: true)
                if let failure = draft.failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 4)
                }
            }.padding(.top, 12).padding(.bottom, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Theme & layout").font(.body.weight(.medium))
                Spacer(minLength: 12)
                if let failure = draft.failure {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel(failure)
                }
                Text(draft.summary.isEmpty ? "Optional" : draft.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.vertical, 4)
        }
        .accessibilityIdentifier("setup.appearance")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .fileImporter(isPresented: $choosingLayout, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { draft.layoutFile = url; draft.layoutMode = "file" }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("appearance", action: { command in
                    switch command {
                    case .appearanceExpanded(let value): expanded = value
                    case .themeChoice(let value): draft.themeChoice = value
                    case .themeRepository(let value): draft.theme = value; draft.themeChoice = .repository
                    case .layoutExample(let value): draft.layoutExample = value; draft.layoutMode = "example"
                    default: break
                    }
                }, snapshot: { ["expanded": String(expanded), "themeChoice": draft.themeChoice.rawValue, "columns": availableWidth >= 680 && draft.layoutMode != "example" ? "2" : "1", "valid": String(draft.failure == nil), "layoutExample": draft.layoutExample?.rawValue ?? ""] })
            } }
            #endif
        }
    }
    private var themePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader("Desktop theme", subtitle: "Choose the look of your workspace.", symbol: "paintpalette.fill", color: .purple)
            Picker("Theme choice", selection: $draft.themeChoice) {
                ForEach(ProvisioningThemeChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("setup.theme-choice")
            switch draft.themeChoice {
            case .source:
                hint("Keep the configuration’s theme, or the current choice if none is specified.")
            case .repository:
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("Theme repository", text: $draft.theme, prompt: Text("https://github.com/owner/theme"))
                        .labelsHidden().textFieldStyle(.plain).font(Theme.sans(13))
                        .accessibilityIdentifier("setup.theme")
                }.padding(10).background(inputBackground)
                Label("Repository checked when you review", systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Review setup checks repository accessibility with a GET request. This does not verify theme contents or pin a Git commit.")
            case .random:
                HStack(spacing: 8) {
                    Text("Minimum stars").font(Theme.sans(13)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        Text(draft.minimumStars.formatted()).font(.callout.monospacedDigit()).frame(minWidth: 24)
                        Stepper("Minimum GitHub stars", value: $draft.minimumStars, in: 0...1_000_000)
                            .labelsHidden().fixedSize()
                    }
                }
                hint(draft.minimumStars == 0 ? "Pick from the full Omarchy theme catalogue." : "Pick from catalogue themes with at least \(draft.minimumStars) stars.")
                if draft.minimumStars > 0 { githubHint }
            case .popular:
                hint("Choose the most starred theme in the Omarchy catalogue.")
                githubHint
            }
            Spacer(minLength: 0)
        }.modifier(AppearancePanel())
    }
    private var layoutPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader("Desktop layout", subtitle: "Set how apps are arranged.", symbol: "rectangle.3.group.fill", color: .teal)
            Picker("Layout choice", selection: $draft.layoutMode) {
                Text("Keep").tag("source")
                Text("Examples").tag("example")
                Text("Custom file").tag("file")
                Text("Remove").tag("remove")
            }.pickerStyle(.segmented).labelsHidden()
            if draft.layoutMode == "example" {
                ProvisioningLayoutExampleCards(selection: $draft.layoutExample)
                hint("Saved with your preview. Applies at the next desktop login.")
            } else if draft.layoutMode == "file" {
                if let file = draft.layoutFile {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text("Lua layout").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Replace…") { choosingLayout = true }.controlSize(.small)
                        Button { draft.layoutFile = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear selected layout").help("Clear file selection")
                    }.padding(10).background(inputBackground)
                } else {
                    Button { choosingLayout = true } label: {
                        Label("Choose a layout file…", systemImage: "doc.badge.plus")
                            .font(Theme.sans(13)).frame(maxWidth: .infinity).padding(.vertical, 15)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                hint("Saved with your preview. Applies at the next desktop login.")
                    .help("The chosen file is copied into the reviewed inputs. Lua runs in the guest desktop, so choose a file you trust.")
            } else if draft.layoutMode == "remove" {
                hint("Remove the managed layout at the next desktop login. Other desktop settings stay as they are.")
            } else {
                hint("Keep the configuration’s layout, or leave the current layout unchanged.")
            }
            Spacer(minLength: 0)
        }.modifier(AppearancePanel())
    }
    private var githubHint: some View {
        Label("Uses your GitHub CLI sign-in", systemImage: "person.crop.circle.badge.checkmark")
            .font(.caption).foregroundStyle(.secondary)
            .help("Requires an existing authenticated gh CLI. No sign-in or tool installation is started here. Random with zero minimum stars skips the lookup.")
    }
    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.65)))
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func panelHeader(_ title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(color)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}
private struct AppearancePanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55)))
    }
}
struct ProvisioningReviewedAppearanceView: View {
    let proposal: Data
    var body: some View {
        let summary = ProvisioningAppearanceSummary(proposal: proposal)
        VStack(alignment: .leading, spacing: 6) {
            if let theme = summary.theme {
                Label("Theme: " + theme.replacingOccurrences(of: "https://github.com/", with: ""), systemImage: "paintpalette")
                    .font(.caption).textSelection(.enabled).help(theme)
            }
            if summary.layoutIncluded { Label((summary.layoutExample?.title ?? "Custom layout") + " · next desktop login", systemImage: "rectangle.3.group").font(.caption).foregroundStyle(.secondary) }
            if summary.layoutRemoved { Label("Remove managed layout · next desktop login", systemImage: "rectangle.3.group").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
