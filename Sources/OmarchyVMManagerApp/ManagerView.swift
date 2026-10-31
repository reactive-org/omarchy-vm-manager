import AppKit
import OmarchyVMManagerCore
import SwiftUI

private enum Destination: Hashable { case library, guest(UUID), permissions, runtime }
private enum GuestPage: String, CaseIterable { case home = "Home", resources = "Virtual Machine", network = "Network", startup = "Startup", ssh = "SSH", spaces = "Spaces" }

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var destination: Destination? = .library
    @State private var editor: EditorSelection?
    @State private var page: GuestPage = .home
    private var active: [VMSnapshot] { model.snapshots.filter { $0.sessionID != nil } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $destination) {
                    Label("Virtual Machines", systemImage: "square.stack.3d.up").tag(Destination.library)
                    Section("Guests") {
                        ForEach(model.snapshots) { snapshot in
                            HStack(spacing: 9) {
                                Image(systemName: "desktopcomputer").foregroundStyle(snapshot.sessionID == nil ? Color.secondary : Color.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.profile.name).lineLimit(1)
                                    Text(snapshot.profile.isRetainedPOC ? "Retained POC · \(snapshot.state.label)" : snapshot.state.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5).tag(Destination.guest(snapshot.id))
                        }
                    }
                    Section("Manager") {
                        Label("Permissions", systemImage: "hand.raised.fill").tag(Destination.permissions)
                        Label("Runtime", systemImage: "checkmark.shield").tag(Destination.runtime)
                    }
                }.listStyle(.sidebar)
                HStack(spacing: 10) {
                    ManagerArtwork(size: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Omarchy VM Manager").font(.caption.bold())
                        Text("Private build · 0.3.0").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 255, max: 330)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let error = model.registryError {
                        GroupedPanel {
                            SettingsRow("Registry unavailable", subtitle: error + " The original data has been preserved. Quit the other manager or repair the registry before reopening.", icon: "exclamationmark.triangle.fill", color: .orange) { EmptyView() }
                        }
                    }
                    switch destination {
                    case .guest(let id):
                        if let snapshot = model.snapshots.first(where: { $0.id == id }) { guest(snapshot) }
                        else { library }
                    case .permissions: permissions
                    case .runtime: runtime
                    default: library
                    }
                }.padding(28).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Omarchy VM Manager")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = EditorSelection(profile: nil) } label: { Label("New VM", systemImage: "plus") }
                    .disabled(model.registryError != nil || model.shuttingDown)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(minWidth: 920, minHeight: 650)
        .onChange(of: destination) { page = .home }
        .sheet(item: $editor) { selection in
            VMEditor(model: model, profile: selection.profile) { id in destination = .guest(id); page = .home; editor = nil }
        }
        .sheet(isPresented: $model.shuttingDown) { ProgressView("Shutting down VMs…").padding(40).interactiveDismissDisabled() }
        .alert("Power off this VM?", isPresented: Binding(get: { model.forceStopID != nil }, set: { if !$0 { model.forceStopID = nil } })) {
            Button("Force Stop", role: .destructive) { if let id = model.forceStopID { model.forceStopID = nil; Task { await model.forceStop(id) } } }
            Button("Cancel", role: .cancel) { model.forceStopID = nil }
        } message: { Text("Unsaved guest work can be lost. Prefer Shut Down when the guest responds.") }
        .alert("Move this VM to Trash?", isPresented: Binding(get: { model.deletionReview != nil }, set: { if !$0 { model.deletionReview = nil } })) {
            Button(model.deletionReview?.identity == nil ? "Remove Profile" : "Move to Trash", role: .destructive) {
                if let review = model.deletionReview { model.deletionReview = nil; Task { await model.delete(review) } }
            }
            Button("Cancel", role: .cancel) { model.deletionReview = nil }
        } message: {
            if let review = model.deletionReview {
                Text(review.identity == nil ? "Remove “\(review.name)”? No storage folder is present at its registered location. Any files already in Trash remain there." : "The entire storage folder for “\(review.name)” will move to the Mac Trash. You can recover its files from there.")
            }
        }
        .alert("Action could not finish", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupedPanel {
                HStack(spacing: 24) {
                    ManagerArtwork(size: 144)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Omarchy VM Manager").font(.system(size: 32, weight: .bold))
                        Text("Your Omarchy virtual machines").font(.title3).foregroundStyle(.secondary)
                        Text("\(active.count) running or starting · \(active.reduce(0) { $0 + $1.profile.memoryMiB } / 1024) GiB allocated").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(24)
            }
            Text("Virtual Machines").font(.title2.bold())
            if model.snapshots.isEmpty, model.registryError == nil {
                ContentUnavailableView {
                    Label("Your Omarchy machines", systemImage: "desktopcomputer")
                } description: { Text("Create an independent guest with its own disk, settings and clipboard.") }
                actions: { Button("New VM") { editor = EditorSelection(profile: nil) }.buttonStyle(.borderedProminent) }
            }
            ForEach(model.snapshots) { snapshot in
                GroupedPanel {
                    HStack(alignment: .top, spacing: 18) {
                        TileIcon(symbol: "desktopcomputer", color: .green, size: 46)
                        VStack(alignment: .leading, spacing: 7) {
                            Button(snapshot.profile.name) { destination = .guest(snapshot.id) }.buttonStyle(.plain).font(.title2.bold())
                            Text("\(snapshot.state.label) · \(snapshot.profile.cpus) cores · \(snapshot.profile.memoryMiB / 1024) GiB memory").foregroundStyle(.secondary)
                            if snapshot.profile.isRetainedPOC { Label("Retained POC disk", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
                            if let failure = snapshot.lastFailure { Text(failure.message).foregroundStyle(.red).font(.callout) }
                            progress(snapshot)
                        }
                        Spacer()
                        controls(snapshot)
                    }.padding(20)
                }
            }
        }
    }

    private func guest(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.profile.name).font(.largeTitle.bold())
                    Text(snapshot.state.label).foregroundStyle(snapshot.sessionID == nil ? Color.secondary : Color.green)
                }
                Spacer(); controls(snapshot)
            }
            Picker("Guest settings", selection: $page) { ForEach(GuestPage.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if snapshot.profile.isRetainedPOC {
                Label("This POC disk is retained. Configuration changes and deletion are disabled.", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            }
            switch page {
            case .home: guestHome(snapshot)
            case .resources: resources(snapshot)
            case .network: network(snapshot)
            case .startup: startup(snapshot)
            case .ssh: ssh(snapshot)
            case .spaces: spaces(snapshot)
            }
            if let notice = snapshot.notice { Label(notice, systemImage: "info.circle").font(.callout) }
            if let failure = snapshot.lastFailure {
                GroupedPanel { VStack(alignment: .leading, spacing: 10) {
                    Label("\(failure.code)", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(failure.message)
                    if !failure.diagnostics.isEmpty { DisclosureGroup("Helper diagnostics") { Text(failure.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                }.padding(20) }
            }
            let events = model.records.filter { $0.vmID == snapshot.id }
            if !events.isEmpty {
                DisclosureGroup("Session activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events.suffix(30).reversed())) { Text("\($0.date.formatted(date: .omitted, time: .standard))  \($0.text)").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
            }
            if !snapshot.profile.isRetainedPOC {
                HStack {
                    Button("Rename or Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                    Spacer()
                    Button("Delete VM…", role: .destructive) { Task { await model.reviewDeletion(snapshot) } }.disabled(!editable(snapshot))
                }
            }
        }
    }

    private func guestHome(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupedPanel {
                HStack(spacing: 24) {
                    ManagerArtwork(size: 96)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Omarchy").font(.system(size: 34, weight: .bold))
                        Text(snapshot.state == .stopped ? "Ready to launch" : snapshot.state.label).font(.title3).foregroundStyle(.secondary)
                        Text("Independent disk · Shared (NAT) network").foregroundStyle(.secondary)
                        progress(snapshot)
                    }
                    Spacer()
                }.padding(26)
            }
            Text("Quick Settings").font(.title2.bold())
            GroupedPanel {
                SettingsRow("Resources", subtitle: "\(snapshot.profile.cpus) processor cores · \(snapshot.profile.memoryMiB / 1024) GiB memory", icon: "cpu", color: .purple) {
                    Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
                Divider().padding(.horizontal, 20)
                SettingsRow("Clipboard", subtitle: snapshot.profile.clipboardEnabled ? "Syncs with the Mac while this guest is focused." : "Clipboard sharing is off for this guest.", icon: "doc.on.clipboard", color: .cyan) {
                    Text(snapshot.profile.clipboardEnabled ? "Enabled" : "Off").foregroundStyle(.secondary)
                }
                Divider().padding(.horizontal, 20)
                SettingsRow("Storage used", subtitle: ByteCountFormatter.string(fromByteCount: model.storageBytes[snapshot.id] ?? 0, countStyle: .file), icon: "internaldrive", color: .orange) { EmptyView() }
            }
        }
    }

    private func resources(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupedPanel {
                SettingsRow("Resources", subtitle: "\(snapshot.profile.cpus) processor cores · \(snapshot.profile.memoryMiB / 1024) GiB memory", icon: "cpu", color: .purple) {
                    Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
                Divider().padding(.horizontal, 20)
                SettingsRow("Disk", subtitle: "Created from the official factory image on first start. Existing disks are preserved.", icon: "internaldrive", color: .orange) {
                    Text(ByteCountFormatter.string(fromByteCount: model.storageBytes[snapshot.id] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                }
            }
            Text(snapshot.profile.isRetainedPOC ? "This profile’s original configuration is preserved with its retained disk." : "Shut down this guest to change its name, resources or clipboard. Changes apply on its next start.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func network(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupedPanel {
                SettingsRow("Network", subtitle: "Shared (NAT) · Uses your Mac’s connection", icon: "network", color: .blue) { Text("NAT").foregroundStyle(.secondary) }
                Divider().padding(.horizontal, 20)
                SettingsRow("Port Forwarding", subtitle: snapshot.profile.ssh.map { "SSH · 127.0.0.1:\($0.hostPort) → guest TCP 22" } ?? "This guest starts without host port forwards.", icon: "arrow.left.arrow.right", color: .indigo) { Text(snapshot.profile.ssh == nil ? "Off" : "SSH").foregroundStyle(.secondary) }
                Divider().padding(.horizontal, 20)
                SettingsRow("Host Sharing", subtitle: "Shared folders, USB, camera and authentication are disabled.", icon: "folder.fill", color: .cyan) { Text("Off").foregroundStyle(.secondary) }
            }
            Text("Managed SSH uses a guest-specific Mac loopback port. General port forwarding and host sharing remain unavailable.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func startup(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupedPanel {
                SettingsRow("Immersive Mode", subtitle: "Open full screen with the Mac menu bar and Dock hidden.", icon: "arrow.up.left.and.arrow.down.right", color: .gray) {
                    Text(snapshot.profile.immersiveMode.map { $0 ? "On" : "Off" } ?? "Original setting").foregroundStyle(.secondary)
                    Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
                Divider().padding(.horizontal, 20)
                SettingsRow("Launch at Startup", subtitle: "Guests start only when you choose Launch. Reopening the manager restores the list.", icon: "power", color: .gray) { Text("Manual").foregroundStyle(.secondary) }
            }
            Text("Windowed mode is recommended when assigning guests to existing Mission Control desktops.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func ssh(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupedPanel {
                SettingsRow("SSH from this Mac", subtitle: snapshot.profile.ssh.map { "127.0.0.1:\($0.hostPort) → guest port 22" } ?? "SSH is off for this profile.", icon: "terminal", color: .indigo) {
                    Text(snapshot.sshReadiness.label).foregroundStyle(.secondary)
                }
                if let options = snapshot.profile.ssh {
                    Divider().padding(.horizontal, 20)
                    SettingsRow("Login key", subtitle: "An independent managed key is kept on this Mac. Only its public key is enrolled in the guest.", icon: "key.fill", color: .orange) { EmptyView() }
                    if let fingerprint = options.publicKeyFingerprint {
                        Divider().padding(.horizontal, 20)
                        SettingsRow("Your public key", subtitle: fingerprint, icon: "person.badge.key.fill", color: .green) { EmptyView() }
                    }
                }
            }
            if case .ready(let user, let command) = snapshot.sshReadiness {
                Text("Authenticated as \(user). The guest’s host identity is pinned.").foregroundStyle(.secondary)
                Button("Copy SSH Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }.buttonStyle(.borderedProminent)
            } else if snapshot.profile.ssh != nil {
                Text("Complete the guest’s normal owner-account setup. The manager then verifies key-based SSH independently of its desktop and clipboard. Guest host keys are provisioned once and checked on every connection.").foregroundStyle(.secondary)
                if snapshot.sessionID != nil {
                    Button("Retry SSH Check") { Task { await model.retrySSH(snapshot.id) } }.disabled(snapshot.state == .stopping)
                }
            } else {
                Text("SSH is enabled by default when creating a new VM. Existing profiles are unchanged; retained POC disks stay protected.").foregroundStyle(.secondary)
            }
        }
    }

    private func spaces(_ snapshot: VMSnapshot) -> some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 18) {
                SettingsRow("Mission Control Spaces", subtitle: "Use the guest’s own Dock icon to choose its desktop.", icon: "rectangle.3.group", color: .indigo) { EmptyView() }.padding(-20)
                Text("1. Launch this guest in windowed mode.\n2. Move its window to the desktop you want in Mission Control.\n3. Control-click “\(snapshot.profile.name)” in the Dock.\n4. Choose Options → Assign To → This Desktop.").lineSpacing(7)
                Text("Each storage root has a stable guest app identity, independent of its display name. macOS manages the assignment. To release it, choose Assign To → None.").foregroundStyle(.secondary)
                if snapshot.profile.isRetainedPOC { Text("Retained POC guests keep their original display settings. New guests start in windowed mode.").font(.callout).foregroundStyle(.secondary) }
                Link("Apple’s guide to Mission Control Spaces", destination: URL(string: "https://support.apple.com/guide/mac-help/mh14112/mac")!)
                Text("Assignment persistence across guest restarts needs verification on this Mac with the updated runtime.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Permissions").font(.largeTitle.bold())
            GroupedPanel {
                SettingsRow("Accessibility", subtitle: "Needed for native Super shortcuts such as Command+Space inside guests.", icon: "accessibility", color: .blue) {
                    if model.accessibilityTrusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Enable Super shortcuts…") { Task { await model.requestSuperShortcuts() } }.disabled(!active.isEmpty) }
                }
                Divider().padding(.horizontal, 20)
                SettingsRow("Camera and Authentication", subtitle: "These optional bridges are disabled in the current manager.", icon: "lock.shield", color: .green) { Text("Off").foregroundStyle(.secondary) }
            }
            Text("Enable permissions yourself in System Settings. A new ad-hoc build can need a refreshed Accessibility grant. Shut down guests before refreshing it.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Runtime").font(.largeTitle.bold())
            GroupedPanel {
                SettingsRow("Try Omarchy Kit", subtitle: model.diagnostics == nil ? (model.diagnosticError ?? "Checking…") : "Pinned private runtime · Focus-aware clipboard", icon: "checkmark.shield.fill", color: .green) {
                    Button("Check Again") { Task { await model.refresh() } }.disabled(model.checking)
                }
            }
            if let d = model.diagnostics {
                Text("Protocol \(d.runProtocolVersion) · Host preflight: \(d.preflightFailure ?? "Passed")").foregroundStyle(.secondary)
                DisclosureGroup("Build provenance") { Text(d.patchCommit).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
            }
            GroupedPanel {
                SettingsRow("Known graphics startup issue", subtitle: "A guest may occasionally open with a black or incomplete desktop. Investigation is ongoing.", icon: "exclamationmark.triangle", color: .orange) { EmptyView() }
            }
        }
    }

    @ViewBuilder private func controls(_ snapshot: VMSnapshot) -> some View {
        if snapshot.state.canStart {
            Button { Task { await model.start(snapshot.id) } } label: { Label("Launch", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(model.checking || model.diagnostics == nil || model.registryError != nil || model.shuttingDown)
        } else if snapshot.sessionID != nil {
            HStack {
                Button("Shut Down") { Task { await model.stop(snapshot.id) } }.disabled(snapshot.state == .stopping)
                Menu { Button("Force Stop…", role: .destructive) { model.forceStopID = snapshot.id } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
        } else { ProgressView().controlSize(.small) }
    }
    @ViewBuilder private func progress(_ snapshot: VMSnapshot) -> some View {
        switch snapshot.state {
        case .downloading(let phase, let percent), .starting(let phase, let percent):
            if let percent { ProgressView(value: Double(percent), total: 100).frame(maxWidth: 320); Text("\(phase.rawValue) · \(percent)%").font(.caption) }
            else { ProgressView(phase.rawValue).controlSize(.small) }
        case .validating: ProgressView("Validating…").controlSize(.small)
        default: EmptyView()
        }
    }
    private func editable(_ snapshot: VMSnapshot) -> Bool { snapshot.sessionID == nil && snapshot.state.canStart && !snapshot.profile.isRetainedPOC && !model.shuttingDown }
}

private struct TileIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.53, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size).background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
    }
}
private struct GroupedPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { VStack(spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)) }
}
private struct SettingsRow<Action: View>: View {
    let title: String; let subtitle: String; let icon: String; let color: Color
    @ViewBuilder let action: Action
    init(_ title: String, subtitle: String, icon: String, color: Color, @ViewBuilder action: () -> Action) { self.title = title; self.subtitle = subtitle; self.icon = icon; self.color = color; self.action = action() }
    var body: some View {
        HStack(spacing: 14) {
            TileIcon(symbol: icon, color: color)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 12); action
        }.padding(20)
    }
}
private struct EditorSelection: Identifiable { let id = UUID(); let profile: VMProfile? }
private struct VMEditor: View {
    @ObservedObject var model: AppModel
    let profile: VMProfile?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var memory: Int
    @State private var cpus: Int
    @State private var clipboard: Bool
    @State private var immersive: Bool
    @State private var saving = false
    @State private var sshEnabled: Bool
    @State private var selectedPublicKey: String?
    @State private var keyError: String?
    init(model: AppModel, profile: VMProfile?, saved: @escaping (UUID) -> Void) {
        self.model = model; self.profile = profile; self.saved = saved
        _name = State(initialValue: profile?.name ?? "")
        _memory = State(initialValue: (profile?.memoryMiB ?? 4096) / 1024)
        _cpus = State(initialValue: profile?.cpus ?? 4)
        _clipboard = State(initialValue: profile?.clipboardEnabled ?? true)
        _immersive = State(initialValue: profile?.immersiveMode ?? false)
        _sshEnabled = State(initialValue: profile.map { $0.ssh != nil } ?? true)
    }
    private var maximumMemory: Int { max(4, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) * 3 / 4) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(profile == nil ? "New Virtual Machine" : "Configure Virtual Machine").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Stepper("Memory: \(memory) GiB", value: $memory, in: 4...maximumMemory)
                Stepper("Processor cores: \(cpus)", value: $cpus, in: 4...max(4, ProcessInfo.processInfo.processorCount))
                Toggle("Clipboard integration", isOn: $clipboard)
                Toggle("Immersive Mode", isOn: $immersive)
                Toggle("Enable SSH from this Mac", isOn: $sshEnabled).disabled(profile != nil)
                if profile == nil { Text("SSH uses a separate localhost port and automatic per-guest keys after account setup.").font(.caption).foregroundStyle(.secondary) }
                if sshEnabled, profile == nil {
                    HStack {
                        Text("Personal public key (optional)")
                        Spacer()
                        Button("Choose .pub…") { choosePublicKey() }
                    }
                    if let key = selectedPublicKey, let fingerprint = try? SSHPublicKey.fingerprint(key) {
                        Text(fingerprint).font(.caption).textSelection(.enabled)
                        Button("Remove Selected Key") { selectedPublicKey = nil }
                    }
                }
                if profile != nil { Text("SSH enrollment is chosen at creation. Existing access is preserved.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            if let error = keyError { Text(error).foregroundStyle(.red).font(.callout) }
            if let error = model.configurationError { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(profile == nil ? "The official factory image downloads on first launch. Each guest has independent storage. Networking uses NAT; shared folders, USB, camera and authentication are off." : "Changes apply the next time this guest starts. Its existing disk is preserved.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(profile == nil ? "Create VM" : "Save Changes") {
                    saving = true
                    Task {
                        if let id = await model.save(profile, name: name.trimmingCharacters(in: .whitespacesAndNewlines), memoryGiB: memory, cpus: cpus, clipboard: clipboard, immersive: immersive, sshEnabled: sshEnabled, publicKey: sshEnabled ? selectedPublicKey : nil) { saved(id) }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }.padding(26).frame(width: 520).interactiveDismissDisabled(saving).onAppear { model.configurationError = nil }
    }
    private func choosePublicKey() {
        let panel = NSOpenPanel(); panel.title = "Choose an SSH public key (.pub)"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard url.pathExtension.lowercased() == "pub" else { throw VMFailure(code: "public-key-required", message: "Choose a .pub file; private keys are never imported.") }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
            selectedPublicKey = try SSHPublicKey.canonical(String(decoding: data, as: UTF8.self)); keyError = nil
        } catch { keyError = error.localizedDescription }
    }

}

private struct ManagerArtwork: View {
    let size: CGFloat
    var body: some View {
        if let path = Bundle.main.url(forResource: "OmarchyVMManager", withExtension: "png"), let image = NSImage(contentsOf: path) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack.3d.up").resizable().scaledToFit().frame(width: size, height: size).foregroundStyle(.green).accessibilityHidden(true)
        }
    }
}
