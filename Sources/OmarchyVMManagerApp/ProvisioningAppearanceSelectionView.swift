import OmarchyVMManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum ProvisioningThemeChoice: String, CaseIterable {
    case source = "Keep", repository = "GitHub", random = "Random", popular = "Most starred"
    var label: String {
        switch self { case .source: "Omarchy default"; case .repository: "GitHub…"; case .random: "Random"; case .popular: "Most starred" }
    }
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
        let layout = layoutMode == "example" ? "Example layout" : layoutMode == "file" ? "Custom layout" : layoutMode == "remove" ? "Omarchy default layout" : nil
        return [theme, layout].compactMap { $0 }.joined(separator: " · ")
    }
}
/// Desktop layout first, theme second. Layouts are cards in horizontally
/// scrolling rows so the dev-vm catalogue can grow; one detail line under the
/// rows describes the hovered card, or the selected one when nothing is hovered.
struct ProvisioningAppearanceSelectionView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @Binding var draft: ProvisioningAppearanceDraft
    /// A local setup folder can name its own layout: offer it as a card, and make
    /// Omarchy default remove any managed layout instead of keeping the folder's.
    var localSource = false
    var note = "Applied at the next desktop login"
    @State private var choosingLayout = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("desktop layout").font(Theme.mono(13, weight: .medium)).foregroundStyle(Theme.green)
                Spacer(minLength: 12)
                Text(note).font(Theme.note).foregroundStyle(.secondary)
            }
            DesktopLayoutPicker(draft: $draft, localSource: localSource, chooseFile: { choosingLayout = true })
            themeRow
            if let failure = draft.failure {
                Label(failure, systemImage: "exclamationmark.circle.fill").font(Theme.note).foregroundStyle(Theme.amber)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("setup.appearance")
        .fileImporter(isPresented: $choosingLayout, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { draft.layoutFile = url; draft.layoutMode = "file" }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear { bindAcceptance(acceptance, localSource: localSource) }
                .onChange(of: localSource) { _, value in bindAcceptance(acceptance, localSource: value) }
            }
            #endif
        }
    }

    #if DEBUG
    private func bindAcceptance(_ acceptance: SetupUIAcceptanceDriver, localSource: Bool) {
        acceptance.bind("appearance", action: { command in
            switch command {
            case .themeChoice(let value): draft.themeChoice = value
            case .themeRepository(let value): draft.theme = value; draft.themeChoice = .repository
            case .layoutExample(let value):
                if let value { draft.layoutExample = value; draft.layoutMode = "example" }
                else { DesktopLayoutCard.omarchyDefault.apply(to: &draft, localSource: localSource) }
            default: break
            }
        }, snapshot: { ["themeChoice": draft.themeChoice.rawValue, "card": DesktopLayoutCard(draft, localSource: localSource).key,
                        "valid": String(draft.failure == nil), "layoutExample": draft.layoutExample?.rawValue ?? ""] })
    }
    #endif

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("theme").font(Theme.mono(14)).foregroundStyle(Theme.lavender)
                    Text(themeNote).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Picker("Theme", selection: $draft.themeChoice) {
                    ForEach(ProvisioningThemeChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("setup.theme-choice")
            }
            switch draft.themeChoice {
            case .repository:
                HStack(spacing: 10) {
                    Text("repository").font(Theme.mono(14)).foregroundStyle(Theme.lavender)
                    TextField("Theme repository", text: $draft.theme, prompt: Text("https://github.com/owner/theme"))
                        .labelsHidden().textFieldStyle(.roundedBorder).font(Theme.mono(13)).frame(maxWidth: 360)
                        .accessibilityIdentifier("setup.theme")
                }
            case .random:
                HStack(spacing: 8) {
                    Text("minimum stars").font(Theme.mono(14)).foregroundStyle(Theme.lavender)
                    Spacer()
                    Text(draft.minimumStars.formatted()).font(Theme.mono(13)).frame(minWidth: 28)
                    Stepper("Minimum GitHub stars", value: $draft.minimumStars, in: 0...1_000_000).labelsHidden().fixedSize()
                }
            case .source, .popular: EmptyView()
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
    private var themeNote: String {
        switch draft.themeChoice {
        case .source: localSource ? "Uses your setup folder’s theme if it sets one; otherwise Omarchy’s default theme." : "Uses Omarchy’s default theme."
        case .repository: "Installs a theme from a GitHub repository. Review checks the repository is reachable; it doesn’t verify contents or pin a commit."
        case .random: draft.minimumStars == 0 ? "Picks from the full Omarchy theme catalogue." : "Picks a catalogue theme with at least \(draft.minimumStars) stars, using your GitHub CLI sign-in."
        case .popular: "Uses the most-starred catalogue theme, using your GitHub CLI sign-in."
        }
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
            if summary.layoutRemoved { Label("Omarchy default layout · next desktop login", systemImage: "rectangle.3.group").font(.caption).foregroundStyle(.secondary) }
            if let adds = summary.layoutAddsSentence { Label(adds, systemImage: "plus.square.on.square").font(.caption).foregroundStyle(.secondary) }
            ForEach(summary.layoutNotInstalledSentences, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
