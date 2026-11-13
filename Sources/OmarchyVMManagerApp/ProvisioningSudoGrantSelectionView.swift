import SwiftUI

/// How setup asks Omarchy for passwordless sudo. Omarchy's own full-screen prompt
/// can't be changed, so this says up front what it will show.
struct ProvisioningSudoGrantSelectionView: View {
    @Binding var permanent: Bool
    static let onNote = "Omarchy asks once and calls it permanent. Setup turns it off when it finishes."
    static let offNote = "Omarchy asks for 60 minutes. Setup renews it while it runs and turns it off when it finishes."
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ask for sudo once", isOn: $permanent)
                .accessibilityIdentifier("setup.permanentSudo")
                .help("Setup needs passwordless sudo while it runs. Omarchy asks in the guest terminal.")
            Text(permanent ? Self.onNote : Self.offNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
