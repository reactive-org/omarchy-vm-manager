import OmarchyVMManagerCore
import SwiftUI

struct ProvisioningToolsView: View {
    @State private var report: ProvisioningToolReport?
    @State private var checking = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Provisioning tools").font(Theme.sans(26, weight: .semibold))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check again") { Task { await refresh() } }.disabled(checking)
            }
            Text("Check the host tools needed for developer setup. Offline previews work in both channels. Dev setup requires a verified Dev guest, a reviewed plan and the permissions shown in Setup; Stable execution remains disabled.")
                .foregroundStyle(.secondary)
            if failed { Label("Tool checks could not finish. Try again.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let report {
                ForEach(report.tools) { tool in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(tool.tool.title).font(Theme.sans(14, weight: .semibold))
                            if let version = tool.version { Text(version).monospaced().foregroundStyle(.secondary) }
                            Spacer()
                            Text(tool.status.label).foregroundStyle(tool.status == .available ? Color.green : Color.orange)
                        }
                        Text(tool.reason).font(Theme.sans(13))
                        if let executable = tool.executable {
                            Text(executable.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let installation = tool.installation {
                            Text("Homebrew installation: " + installation.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if [.missing, .incompatible].contains(tool.status), let command = tool.installCommand {
                            Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text("Run manually in Terminal, then check again. A newer version may still need compatibility review.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Feature availability").font(Theme.sans(20, weight: .semibold))
                ForEach(report.features) { feature in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(feature.capability.title).bold()
                            Spacer()
                            Text(feature.toolsReady ? "Tools ready · integration pending" : "Unavailable").foregroundStyle(.secondary)
                        }
                        Text(feature.reason).font(Theme.sans(13)).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                Text(report.policy).font(.caption).foregroundStyle(.secondary)
            }
            Text("Checks do not install tools, read GitHub credentials, contact a guest or launch a VM.")
                .font(Theme.sans(13)).foregroundStyle(.secondary)
        }.task { if report == nil { await refresh() } }
    }

    @MainActor private func refresh() async {
        guard !checking else { return }
        checking = true; failed = false
        defer { checking = false }
        do { report = try await HomebrewProvisioningDependencies().inspect() }
        catch is CancellationError { }
        catch { failed = true }
    }
}
