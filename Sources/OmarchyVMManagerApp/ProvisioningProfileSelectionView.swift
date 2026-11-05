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
                Text("Profiles").font(Theme.sans(14, weight: .semibold))
                Spacer()
                Text(selection.isEmpty ? (localSource ? "Optional additions" : "Select one or more") : "\(selection.count) selected").font(Theme.note).foregroundStyle(.secondary)
            }
            Text(localSource ? "Profiles in vm.yml stay included. Select cards to add bundled profiles." : "Combine profiles to build your workstation. Shared features are included once.")
                .font(Theme.note).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(summaries) { profile in
                    row(profile)
                }
            }
            if unavailable { Text("Profile descriptions are unavailable. Check the bundled setup resources.").font(Theme.note).foregroundStyle(.orange) }
            if !localSource, selection.isEmpty { Text("Select at least one profile to review setup.").font(Theme.note).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { summaries = try BundledProvisioning.profileSummaries(); unavailable = false }
            catch { summaries = []; unavailable = true }
        }
    }
    private func row(_ profile: ProvisioningProfileSummary) -> some View {
        let selected = selection.contains(profile.id)
        let name = title(profile.id)
        return Button {
            if selected { selection.remove(profile.id) } else { selection.insert(profile.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(selected ? Theme.green : .clear)
                    RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? Theme.green : Theme.label, lineWidth: 1.5)
                    if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onGreen) }
                }.frame(width: 15, height: 15).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(name).font(Theme.sans(13, weight: .medium))
                        if profile.includesDeveloper { Text("Includes Developer").font(Theme.note).foregroundStyle(.secondary) }
                    }
                    let details = profile.additionalFeatures.map(featureTitle) + profile.tools.map(toolTitle) + (profile.databaseClients.isEmpty ? [] : [profile.databaseClients.map(toolTitle).joined(separator: " · ") + " clients"])
                    Text(details.joined(separator: " · ")).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? Theme.green.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(selected ? Theme.green : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.profile." + profile.id)
        .accessibilityLabel(name + ". " + profile.includedFeatures.map(featureTitle).joined(separator: ", "))
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
    private func title(_ id: String) -> String {
        switch id {
        case "developer": "Developer"
        case "web": "Web"
        case "python": "Python"
        default: "Project managed"
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
                .font(Theme.sans(13)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
