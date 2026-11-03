import OmarchyVMManagerCore
import SwiftUI

/// Profile cards display the shared resolver's expected inclusions. Selection
/// freezes a new proposal; it never runs a tool or changes a guest.
struct ProvisioningProfileSelectionView: View {
    @Binding var selection: Set<String>
    let localSource: Bool
    @State private var summaries: [ProvisioningProfileSummary] = []
    @State private var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Text(selection.isEmpty ? (localSource ? "Optional additions" : "Select one or more") : "\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Text(localSource ? "Profiles in vm.yml stay included. Select cards to add bundled profiles." : "Combine profiles to build your workstation. Shared features are included once.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(summaries) { profile in
                    card(profile)
                }
            }
            if unavailable { Text("Profile descriptions are unavailable. Check the bundled setup resources.").font(.caption).foregroundStyle(.orange) }
            if !localSource, selection.isEmpty { Text("Select at least one profile to review setup.").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { summaries = try BundledProvisioning.profileSummaries(); unavailable = false }
            catch { summaries = []; unavailable = true }
        }
    }
    private func card(_ profile: ProvisioningProfileSummary) -> some View {
        let selected = selection.contains(profile.id)
        let style = appearance(profile.id)
        return Button {
            if selected { selection.remove(profile.id) } else { selection.insert(profile.id) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(style.color.opacity(0.16)).frame(width: 38, height: 38)
                        if profile.id == "python" { Text("Py").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(style.color) }
                        else { Image(systemName: style.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(style.color) }
                    }
                    Text(style.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                if profile.includesDeveloper { Text("Includes Developer").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(profile.additionalFeatures.map(featureTitle).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !profile.tools.isEmpty {
                    Text(profile.tools.map(toolTitle).joined(separator: " · ")).font(.caption.weight(.semibold))
                }
                if !profile.databaseClients.isEmpty {
                    Text(profile.databaseClients.map(toolTitle).joined(separator: " · ") + " clients")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.profile." + profile.id)
        .accessibilityLabel(style.title + ". " + profile.includedFeatures.map(featureTitle).joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help("Select to include this profile. Shared features are deduplicated; conflicting settings must be resolved before applying.")
    }
    private func featureTitle(_ name: String) -> String {
        ProvisioningCommonFeature(rawValue: name)?.title ?? (name == "keyring" ? "Desktop keyring" : name.replacingOccurrences(of: "-", with: " ").capitalized)
    }
    private func toolTitle(_ name: String) -> String {
        switch name {
        case "node": "Node.js"
        case "python": "Python"
        case "postgresql": "PostgreSQL"
        case "sqlite": "SQLite"
        default: name
        }
    }
    private func appearance(_ id: String) -> (title: String, symbol: String, color: Color) {
        switch id {
        case "developer": ("Developer", "chevron.left.forwardslash.chevron.right", .blue)
        case "web": ("Web", "globe", .teal)
        case "python": ("Python", "curlybraces", .orange)
        default: ("Project managed", "shippingbox.fill", .indigo)
        }
    }
}

/// Keep the resolved profile names visible even when a saved preview was loaded
/// without choosing a new source. Technical proposal data remains under Details.
struct ProvisioningReviewedProfilesView: View {
    let proposal: Data
    private var names: [String] {
        guard let document = try? JSONSerialization.jsonObject(with: proposal) as? [String: Any],
              let features = document["features"] as? [String: Any], let profiles = features["profiles"] as? [String] else { return [] }
        return profiles.map { raw in
            let name = raw.hasPrefix("builtin.") ? String(raw.dropFirst(8)) : raw
            switch name {
            case "developer": return "Developer"
            case "web": return "Web"
            case "python": return "Python"
            case "project-managed": return "Project managed"
            default: return raw
            }
        }
    }
    var body: some View {
        if !names.isEmpty {
            Label("In this preview: " + names.joined(separator: " · "), systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
