import AppKit
import OmarchyVMManagerCore
import SwiftUI

struct OwnerDefaultsView: View {
    @ObservedObject var model: AppModel
    @State private var enabled = false
    @State private var configuration = OwnerConfiguration()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var publicKey: String?
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @State private var disks = DiskDefaults()
    @State private var disksSaved = false
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
        VStack(alignment: .leading, spacing: 20) {
            Text("Guest Defaults").font(.largeTitle.bold())
            Text("Configure owner setup once for new virtual machines. Each new guest keeps its own snapshot; changing defaults leaves existing guests unchanged.").foregroundStyle(.secondary)
            if let failure = model.defaultsError { Text(failure).foregroundStyle(.red) }
            Form {
                Section("New guest disks") {
                    Toggle("Use a separate home disk", isOn: $disks.separateHome)
                    Stepper("System disk: \(disks.systemDiskGiB) GiB", value: $disks.systemDiskGiB, in: 64...8192, step: 16)
                    Stepper("Home disk: \(disks.homeDiskGiB) GiB", value: $disks.homeDiskGiB, in: 16...8192, step: 16).disabled(!disks.separateHome)
                    Text("With a separate home disk, a replacement system can reuse its data. Turning this off puts the home on the system disk. Existing guests are unchanged.").font(.caption).foregroundStyle(.secondary)
                    Button(disksSaved ? "Disk Defaults Saved" : "Save Disk Defaults") {
                        saving = true; error = nil
                        Task { disksSaved = await model.saveDiskDefaults(disks); if !disksSaved { error = model.defaultsError }; saving = false }
                    }
                    .onChange(of: disks) { disksSaved = false }
                }
                Section {
                    Toggle("Set up new guests automatically", isOn: $enabled)
                    Text("You can choose manual setup when creating a guest.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Owner") {
                    TextField("Username", text: $configuration.username)
                    TextField("Full name", text: $configuration.fullName)
                    TextField("Git email (optional)", text: $configuration.email)
                    SecureField(model.ownerDefaults?.credentialReference == nil ? "Password" : "New password (leave blank to keep saved)", text: $password)
                    SecureField("Confirm new password", text: $confirmation)
                    if developmentPasswords {
                        Text("This development build uses your existing login Keychain password. macOS may ask for your login password or permission to access it. Completed guests do not read the password again.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("The manager retrieves the saved password from protected Keychain storage at first launch, using Touch ID or your Mac login password. Creating a VM only saves its profile. Completed guests do not ask again.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("A private temporary seed sets the guest owner and root passwords; SSH uses independent keys.").font(.caption).foregroundStyle(.secondary)
                    if !protectedPasswordsAvailable && !developmentPasswords {
                        Label("Touch ID password storage requires a signed, provisioned build. Your existing saved password is preserved.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.passwordUpgradeResult == .authenticationPending {
                        Text("Keychain needs authentication before protection can be confirmed. You can retry the upgrade after unlocking your Mac. First launch still requires the protected password; this check did not read or replace it.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.ownerDefaults?.credentialReference != nil && protectedPasswordsAvailable {
                        Button(upgradeButtonTitle) {
                            error = nil; saving = true
                            Task {
                                if !(await model.upgradeSavedGuestPassword()) { error = model.defaultsError }
                                saving = false
                            }
                        }.disabled(saving || (model.passwordUpgradeResult != nil && model.passwordUpgradeResult != .authenticationPending) || !protectedPasswordsAvailable || model.registryError != nil)
                        Text("For passwords saved by older versions, this one-time upgrade may request login-Keychain access. It preserves the original entry and pending guest references. Touch ID storage requires a provisioned app build.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("System") {
                    TextField("Hostname prefix", text: $configuration.hostnamePrefix)
                    Text("Guest hostnames append a unique suffix, for example \(configuration.hostnamePrefix)-a1b2c3d4.").font(.caption).foregroundStyle(.secondary)
                    Picker("Time zone", selection: $configuration.timezone) {
                        Text("Same as macOS").tag("Same as macOS")
                        Text("UTC").tag("UTC")
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Keyboard", selection: $configuration.keyboardID) {
                        ForEach(OwnerSetupContract.current.keyboards) { Text($0.id).tag($0.id) }
                    }
                }
                Section("SSH public key") {
                    HStack {
                        Text("Additional login key (optional)")
                        Spacer()
                        Button("Choose .pub…") {
                            do { if let key = try PublicKeyPicker.choose() { publicKey = key; saved = false } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    if let publicKey, let fingerprint = try? SSHPublicKey.fingerprint(publicKey) {
                        Text(fingerprint).font(.caption).textSelection(.enabled)
                        Button("Remove Key") { self.publicKey = nil; saved = false }
                    }
                    Text("Added to new SSH-enabled guests alongside the manager’s own per-guest key. Private keys are never imported.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true).disabled(saving)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if saved, configuration == model.ownerDefaults?.configuration, enabled == model.ownerDefaults?.enabled, publicKey == model.ownerDefaults?.sshPublicKey, password.isEmpty, confirmation.isEmpty { Label("Defaults saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button(saving ? "Saving…" : "Save Defaults") {
                    error = nil; saved = false
                    guard password == confirmation else { error = "The passwords do not match."; return }
                    saving = true
                    Task {
                        if await model.saveDefaults(enabled: enabled, configuration: configuration, password: password.isEmpty ? nil : Data(password.utf8), publicKey: publicKey) {
                            password = ""; confirmation = ""; saved = true
                        } else { error = model.defaultsError }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || model.registryError != nil)
            }
            Text("Automatic setup supports the reviewed prepared factory image. Disk partitioning, encryption and Tailscale settings from the ISO guide are outside this flow. If the image’s setup scripts change, the guest returns to normal setup and the manager reports why.").font(.callout).foregroundStyle(.secondary)
            Link("Omarchy’s unattended-install guide", destination: URL(string: "https://omarchy.org/manual/unattended-installs/")!)
        }
        .task { await model.loadDefaults(); disks = model.diskDefaults; if let value = model.ownerDefaults { enabled = value.enabled; configuration = value.configuration; publicKey = value.sshPublicKey } }
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
