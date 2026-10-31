import AppKit
import OmarchyVMManagerCore
import SwiftUI

struct FactoryImportView: View {
    @ObservedObject var model: AppModel
    var onImport: (FactoryIdentity) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    @State private var chooser: Task<Void, Never>?
    @State private var working = false
    @State private var cancelling = false
    @State private var choosing = false
    @State private var selectedName: String?
    @State private var imported: FactoryIdentity?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Import Factory", systemImage: "square.and.arrow.down").font(.title2.bold())
            if let imported {
                Label(imported.displayName, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Text("Verified and imported. This factory is available for new virtual machines.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a prepared factory bundle from a source you trust. The app checks the image, provisioning files and compatibility with this runtime.")
                    .foregroundStyle(.secondary)
                Link("Prepare your own factory image: dev-vm example", destination: URL(string: "https://www.reactive.org/dev-vm")!)
                    .font(.callout)
                if let selectedName { Text(selectedName).font(.callout).lineLimit(2) }
                if working {
                    ProgressView(cancelling ? "Cancelling import…" : model.factoryImportProgress.rawValue)
                    Text("Large factory images can take a few minutes to verify and copy.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Choose Bundle…") { chooseBundle() }.disabled(choosing)
                    Text("Select the folder containing factory.json and reviewed-factory.json.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Spacer()
                if imported != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        if working { cancelling = true; operation?.cancel() }
                        else { dismiss() }
                    }.disabled(cancelling || choosing || (working && model.factoryImportProgress == .saving)).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(26).frame(width: 500, alignment: .leading)
        .interactiveDismissDisabled(working || choosing)
        .onDisappear { operation?.cancel(); chooser?.cancel() }
    }

    private func chooseBundle() {
        choosing = true
        error = nil
        chooser = Task { @MainActor in
            defer { choosing = false; chooser = nil }
            let panel = NSOpenPanel()
            panel.title = "Import Factory"
            panel.message = "Choose a prepared factory bundle."
            panel.prompt = "Import Factory"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = true
            panel.resolvesAliases = false
            let result = await withTaskCancellationHandler(operation: { await panel.begin() }, onCancel: {
                Task { @MainActor in panel.cancel(nil) }
            })
            guard !Task.isCancelled, result == .OK, let url = panel.url else { return }
            selectedName = url.lastPathComponent
            working = true
            cancelling = false
            operation = Task { @MainActor in
                defer { working = false; cancelling = false; operation = nil }
                do {
                    let identity = try await model.importFactory(from: url)
                    imported = identity
                    onImport(identity)
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
