import AppKit
import OmarchyVMManagerCore
import SwiftUI

struct OwnerDefaultsView: View {
    @ObservedObject var model: AppModel
    @State private var configuration = OwnerConfiguration()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var publicKey: String?
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @State private var disks = DiskDefaults()
    @State private var disksSaved = false
    @State private var wide = true
    private let protectedPasswordsAvailable = KeychainOwnerSecretStore.supportsProtectedStorage
    private let developmentPasswords = KeychainOwnerSecretStore.usesDevelopmentKeychain
    private var upgradeButtonTitle: String {
        switch model.passwordUpgradeResult {
        case .authenticationPending: "Retry Touch ID upgrade…"
        case .upgraded, .alreadyProtected: "Touch ID storage configured"
        case nil: "Upgrade Saved Password to Touch ID…"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ScreenHeader("Guest Defaults", subtitle: "Save your account details once and they apply automatically to new virtual machines. You can choose manual account setup for an individual VM. Existing guests keep their saved settings.")
            if let failure = model.defaultsError { Text(failure).foregroundStyle(.red) }
            AnyLayout(wide ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.gap)) : AnyLayout(VStackLayout(spacing: Theme.gap))) {
                SpecPane("owner") {
                    SpecRow("username") { TextField("Username", text: $configuration.username).labelsHidden().specField().frame(maxWidth: 260) }
                    SpecRow("full name") { TextField("Full name", text: $configuration.fullName).labelsHidden().specField().frame(maxWidth: 260) }
                    SpecRow("git email") { TextField("Git email (optional)", text: $configuration.email).labelsHidden().specField().frame(maxWidth: 260) }
                    SpecRow("password", note: model.ownerDefaults?.credentialReference == nil ? nil : "Leave blank to keep the saved password.") { SecureField("Password", text: $password).labelsHidden().specField().frame(maxWidth: 260) }
                    SpecRow("confirm") { SecureField("Confirm new password", text: $confirmation).labelsHidden().specField().frame(maxWidth: 260) }
                    VStack(alignment: .leading, spacing: 8) {
                    if developmentPasswords {
                        Text("This development build uses your existing login Keychain password. macOS may ask for your login password or permission to access it. Completed guests do not read the password again.").font(Theme.note).foregroundStyle(.secondary)
                    } else {
                        Text("The manager retrieves the saved password from protected Keychain storage at first launch, using Touch ID or your Mac login password. Creating a VM only saves its profile. Completed guests do not ask again.").font(Theme.note).foregroundStyle(.secondary)
                    }
                    Text("A private temporary seed sets the guest owner and root passwords; SSH uses independent keys.").font(Theme.note).foregroundStyle(.secondary)
                    if !protectedPasswordsAvailable && !developmentPasswords {
                        Label("Touch ID password storage requires a signed, provisioned build. Your existing saved password is preserved.", systemImage: "info.circle").font(Theme.note).foregroundStyle(.secondary)
                    }
                    if model.passwordUpgradeResult == .authenticationPending {
                        Text("Keychain needs authentication before protection can be confirmed. You can retry the upgrade after unlocking your Mac. First launch still requires the protected password; this check did not read or replace it.").font(Theme.note).foregroundStyle(.secondary)
                    }
                    if model.ownerDefaults?.credentialReference != nil && protectedPasswordsAvailable {
                        Button(upgradeButtonTitle) {
                            error = nil; saving = true
                            Task {
                                if !(await model.upgradeSavedGuestPassword()) { error = model.defaultsError }
                                saving = false
                            }
                        }.disabled(saving || (model.passwordUpgradeResult != nil && model.passwordUpgradeResult != .authenticationPending) || !protectedPasswordsAvailable || model.registryError != nil)
                        Text("For passwords saved by older versions, this one-time upgrade may request login-Keychain access. It preserves the original entry and pending guest references. Touch ID storage requires a provisioned app build.").font(Theme.note).foregroundStyle(.secondary)
                    }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                VStack(spacing: Theme.gap) {
                    SpecPane("system") {
                    SpecRow("hostname") { TextField("Hostname prefix", text: $configuration.hostnamePrefix).labelsHidden().specField().frame(maxWidth: 260) }
                    SpecNote("Guest hostnames append a unique suffix, for example \(configuration.hostnamePrefix)-a1b2c3d4.").padding(.bottom, 6)
                    SpecRow("time zone") {
                        Picker("Time zone", selection: $configuration.timezone) {
                            Text("Same as macOS").tag("Same as macOS")
                            Text("UTC").tag("UTC")
                            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 240)
                    }
                    SpecRow("keyboard") {
                        Picker("Keyboard", selection: $configuration.keyboardID) {
                            ForEach(OwnerSetupContract.current.keyboards) { Text($0.id).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 240)
                    }
                    }
                    SpecPane("ssh public key") {
                    SpecRow("login key", note: "Optional") {
                        Button("Choose .pub…") {
                            do { if let key = try PublicKeyPicker.choose() { publicKey = key; saved = false } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    if let publicKey, let fingerprint = try? SSHPublicKey.fingerprint(publicKey) {
                        SpecNote(fingerprint).textSelection(.enabled)
                        Button("Remove Key") { self.publicKey = nil; saved = false }
                    }
                    SpecNote("Added to new SSH-enabled guests alongside the manager’s own per-guest key. Private keys are never imported.").padding(.vertical, 6)
                    }
                    SpecPane("new guest disks") {
                    SpecToggleRow("separate home", isOn: $disks.separateHome)
                    SpecStepperRow("system disk", value: $disks.systemDiskGiB, in: 64...8192, step: 16, unit: " GiB")
                    SpecStepperRow("home disk", value: $disks.homeDiskGiB, in: 16...8192, step: 16, unit: " GiB").disabled(!disks.separateHome)
                    SpecNote("With a separate home disk, a replacement system can reuse its data. Turning this off puts the home on the system disk. Existing guests are unchanged.").padding(.vertical, 6)
                    Button(disksSaved ? "Disk Defaults Saved" : "Save Disk Defaults") {
                        saving = true; error = nil
                        Task { disksSaved = await model.saveDiskDefaults(disks); if !disksSaved { error = model.defaultsError }; saving = false }
                    }
                    .onChange(of: disks) { disksSaved = false }.padding(.bottom, 6)
                    }
                }
            }.disabled(saving)
            .onGeometryChange(for: Bool.self, of: { $0.size.width >= 760 }, action: { wide = $0 })
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if saved, configuration == model.ownerDefaults?.configuration, publicKey == model.ownerDefaults?.sshPublicKey, password.isEmpty, confirmation.isEmpty { Label("Defaults saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button(saving ? "Saving…" : "Save Defaults") {
                    error = nil; saved = false
                    guard password == confirmation else { error = "The passwords do not match."; return }
                    saving = true
                    Task {
                        if await model.saveDefaults(configuration: configuration, password: password.isEmpty ? nil : Data(password.utf8), publicKey: publicKey) {
                            password = ""; confirmation = ""; saved = true
                        } else { error = model.defaultsError }
                        saving = false
                    }
                }.buttonStyle(.primaryAction).disabled(saving || model.registryError != nil)
            }
            Text("Automatic setup supports the reviewed prepared factory image. Disk partitioning, encryption and Tailscale settings from the ISO guide are outside this flow. If the image’s setup scripts change, the guest returns to normal setup and the manager reports why.").font(.callout).foregroundStyle(.secondary)
            Link("Omarchy’s unattended-install guide", destination: URL(string: "https://omarchy.org/manual/unattended-installs/")!)
        }
        .task { await model.loadDefaults(); disks = model.diskDefaults; if let value = model.ownerDefaults { configuration = value.configuration; publicKey = value.sshPublicKey } }
        .onDisappear { password = ""; confirmation = "" }
    }
}

@MainActor enum PublicKeyPicker {
    static func choose() throws -> String? {
        let panel = NSOpenPanel(); panel.title = "Choose an SSH public key (.pub)"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.pathExtension.lowercased() == "pub" else { throw VMFailure(code: "public-key-required", message: "Choose a .pub file; private keys are never imported.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
        return try SSHPublicKey.canonical(String(decoding: data, as: UTF8.self))
    }
}
