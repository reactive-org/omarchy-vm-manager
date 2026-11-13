import OmarchyVMManagerCore
import SwiftUI

struct ProvisioningTrimSelectionView: View {
    @Binding var selection: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Trim optional apps", isOn: $selection)
                .accessibilityIdentifier("setup.trim")
                .help("The official Try Omarchy image includes a broad collection of apps. Trim surplus apps from this VM for a more sensible development base. The reusable factory image stays unchanged.")
            Text("Remove surplus bundled apps for a leaner base. Required components and selected software are kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if selection {
                Text("Review the removal candidates under Details. Exact removals depend on installed packages and dependency checks.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
struct ProvisioningReviewedTrimView: View {
    let proposal: Data
    var body: some View {
        if ProvisioningTrim.isRequested(in: proposal) {
            Label("Included in preview: Trim optional apps", systemImage: "scissors")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
