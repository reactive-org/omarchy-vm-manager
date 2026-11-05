import AppKit
import OmarchyVMManagerCore
import SwiftUI

private enum Destination: Hashable { case library, guest(UUID), permissions, runtime, defaults, provisioningTools }
private enum GuestPage: String, CaseIterable { case home = "Home", resources = "Virtual Machine", network = "Network", startup = "Startup", ssh = "SSH", spaces = "Spaces", setup = "Setup" }

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var destination: Destination? = .library
    @State private var editor: EditorSelection?
    @State private var importingFactory = false
    @State private var page: GuestPage = .home
    @State private var detailPresentation = UUID()
    init(model: AppModel) { self.model = model }
    #if DEBUG
    init(model: AppModel, acceptanceGuestID: UUID, acceptancePage: String = GuestPage.setup.rawValue) {
        self.model = model; _destination = State(initialValue: .guest(acceptanceGuestID)); _page = State(initialValue: GuestPage(rawValue: acceptancePage) ?? .setup)
    }
    init(model: AppModel, acceptanceManagerPage: String) {
        self.model = model; _destination = State(initialValue: acceptanceManagerPage == "runtime" ? .runtime : .permissions)
    }
    #endif
    private var active: [VMSnapshot] { model.snapshots.filter { $0.sessionID != nil } }

    var body: some View {
        Group {
            if model.isLoading {
                ManagerLoadingView()
            } else {
                managerContent
            }
        }
        .frame(minWidth: 920, minHeight: 650)
    }

    private var navigationContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $destination) {
                    HStack(spacing: 9) {
                        ManagerArtwork(size: 34)
                        Text(AppChannel.current.displayName).font(.system(size: 17, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 5).tag(Destination.library)
                    Section {
                        if model.snapshots.isEmpty, model.registryError == nil {
                            Text("No guests yet").font(.system(size: 13)).foregroundStyle(.secondary).selectionDisabled()
                        }
                        ForEach(model.snapshots) { snapshot in
                            HStack(spacing: 9) {
                                GuestArtwork(size: 26, state: snapshot.state)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.profile.name).lineLimit(1)
                                    HStack(spacing: 6) {
                                        GuestStatusMarker(active: snapshot.sessionID != nil)
                                        Text(snapshot.profile.isRetainedPOC ? "Retained POC · \(snapshot.state.label)" : snapshot.state.label).font(.caption).foregroundStyle(snapshot.sessionID == nil ? Color.secondary : Theme.green).lineLimit(1)
                                    }
                                }
                            }.padding(.vertical, 5).tag(Destination.guest(snapshot.id))
                        }
                    } header: { sidebarHeader("guests") }
                    Section {
                        Label("Guest Defaults", systemImage: "person.crop.circle.badge.checkmark").tag(Destination.defaults)
                        Label("Permissions", systemImage: "hand.raised.fill").tag(Destination.permissions)
                        Label("Runtime", systemImage: "checkmark.shield").tag(Destination.runtime)
                        Label("Provisioning tools", systemImage: "wrench.and.screwdriver").tag(Destination.provisioningTools)
                    } header: { sidebarHeader("manager") }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppChannel.current.displayName + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–") + ")")
                        .bold()
                    Text("A project of [reactive.org enterprises](https://www.reactive.org/)").foregroundStyle(.secondary)
                }.font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.background(Theme.pane).navigationSplitViewColumnWidth(min: 230, ideal: 255, max: 330)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    if let error = model.registryError {
                        SpecPane("registry unavailable") {
                            SpecRow("registry", note: error + " The original data has been preserved. Quit the other manager or repair the registry before reopening.")
                        }
                    }
                    switch destination {
                    case .guest(let id):
                        if let snapshot = model.snapshots.first(where: { $0.id == id }) { guest(snapshot) }
                        else { library }
                    case .defaults: OwnerDefaultsView(model: model)
                    case .permissions: permissions
                    case .runtime: runtime
                    case .provisioningTools: ProvisioningToolsView()
                    default: library
                    }
                }.padding(Theme.gap).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
            }.id(detailPresentation).background(Theme.ground).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle())
        }
        .navigationTitle(AppChannel.current.displayName)
        .toolbar {
            ToolbarItem {
                Button { importingFactory = true } label: { Label("Import Factory", systemImage: "square.and.arrow.down") }
                    .disabled(model.registryError != nil || model.shuttingDown || model.checking || model.diagnostics == nil || model.factoryImportInProgress)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editor = EditorSelection(profile: nil) } label: { Label("New VM", systemImage: "plus") }
                    .disabled(model.registryError != nil || model.shuttingDown)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onChange(of: destination) { page = .home }
        .onChange(of: model.snapshots.compactMap(\.sessionID)) { previous, current in
            guard let session = current.last(where: { !previous.contains($0) }),
                  let snapshot = model.snapshots.first(where: { $0.sessionID == session }) else { return }
            focusGuest(snapshot.id)
        }
        .sheet(isPresented: $importingFactory) { FactoryImportView(model: model) }
        .sheet(item: $editor) { selection in
            VMEditor(model: model, profile: selection.profile, reuseSource: selection.reuseSource) { id in
                focusGuest(id)
                if selection.profile == nil, model.snapshots.first(where: { $0.id == id })?.profile.developerSetup != nil { page = .setup }
                editor = nil
            }
        }
        .sheet(isPresented: $model.shuttingDown) { ProgressView("Shutting down VMs…").padding(40).interactiveDismissDisabled() }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title).font(Theme.mono(11)).foregroundStyle(Theme.label).textCase(nil)
    }

    private var backupConfirmationContent: some View {
        navigationContent
        .alert("Back up the guest home?", isPresented: Binding(get: { model.homeBackupReview != nil }, set: { if !$0 { model.homeBackupReview = nil } })) {
            Button("Back Up Home") {
                if let snapshot = model.homeBackupReview {
                    model.homeBackupReview = nil
                    Task { await model.beginHomeBackup(snapshot.id) }
                }
            }
            Button("Cancel", role: .cancel) { model.homeBackupReview = nil }
        } message: {
            Text("Save the guest owner’s home, including hidden files and credentials, as an unencrypted home.tgz in a new backup folder inside \(model.homeBackupReview?.profile.sharedFolder?.hostPath ?? "the host share"). Close guest apps first: this is a live file backup, not a VM snapshot. Other mounted filesystems are excluded and symbolic links are stored as links. Unreadable or changing files make the backup fail. Existing backups are preserved.")
        }
    }

    private var storageConfirmationContent: some View {
        backupConfirmationContent
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
    }

    private var managerContent: some View {
        storageConfirmationContent
        .alert(model.experimentalPowerReview?.title ?? "Experimental power action", isPresented: Binding(get: { model.experimentalPowerReview != nil }, set: { if !$0 { model.experimentalPowerReview = nil } })) {
            Button(model.experimentalPowerReview?.button ?? "Continue", role: .destructive) {
                if let review = model.experimentalPowerReview { model.experimentalPowerReview = nil; Task { await model.experimentalPower(review) } }
            }
            Button("Cancel", role: .cancel) { model.experimentalPowerReview = nil }
        } message: { Text(model.experimentalPowerReview?.message ?? "") }
        .alert("Action could not finish", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            LibraryHeader(activeCount: active.count, allocatedGiB: active.reduce(0) { $0 + $1.profile.memoryMiB } / 1024, guestCount: model.snapshots.count)
            if model.snapshots.isEmpty, model.registryError == nil {
                FirstGuestPanel(
                    canCreate: !model.shuttingDown,
                    canImport: !model.shuttingDown && !model.checking && model.diagnostics != nil && !model.factoryImportInProgress,
                    newVM: { editor = EditorSelection(profile: nil) }, importFactory: { importingFactory = true },
                    openDefaults: { destination = .defaults }, openRuntime: { destination = .runtime }, openPermissions: { destination = .permissions })
            }
            if !model.snapshots.isEmpty {
                GroupedPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Virtual Machines").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
                        ForEach(model.snapshots) { snapshot in
                            GuestLibraryRow(snapshot: snapshot, open: { focusGuest(snapshot.id) }) { controls(snapshot) }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private func guest(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            GuestHeaderPane(snapshot: snapshot) { controls(snapshot) }
            GuestTabs(page: $page)
            if snapshot.profile.isRetainedPOC {
                Label("This POC disk keeps its original configuration. Delete VM moves it to Trash after confirmation.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            switch page {
            case .home: guestHome(snapshot)
            case .resources: resources(snapshot)
            case .network: network(snapshot)
            case .startup: startup(snapshot)
            case .ssh: ssh(snapshot)
            case .spaces: spaces(snapshot)
            case .setup: DeveloperSetupView(model: model, snapshot: snapshot)
            }
            Group {
                if let notice = snapshot.notice { Label(notice, systemImage: "info.circle").font(.callout).lineLimit(2).help(notice) }
                else { Color.clear }
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 38, alignment: .top)
            if let failure = snapshot.lastFailure {
                GroupedPanel { VStack(alignment: .leading, spacing: 10) {
                    Label("\(failure.code)", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(failure.message)
                    if !failure.diagnostics.isEmpty { DisclosureGroup("Helper diagnostics") { Text(failure.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                }.padding(20) }
            }
            let events = model.records.filter { $0.vmID == snapshot.id }
            GroupedPanel {
                DisclosureGroup("Session activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events.suffix(30).reversed())) { Text("\($0.date.formatted(date: .omitted, time: .standard))  \($0.text)").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }.disabled(events.isEmpty).padding(.horizontal, 20).padding(.vertical, 12)
            }
            HStack(spacing: 12) {
                if !snapshot.profile.isRetainedPOC {
                    Button("Rename or Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                    if snapshot.profile.homeDisk != nil {
                        Button("Replace System…") { editor = EditorSelection(profile: nil, reuseSource: snapshot.profile) }.disabled(!editable(snapshot))
                    }
                }
                OmarchyAttribution().frame(maxWidth: .infinity)
                Button("Delete VM…", role: .destructive) { Task { await model.reviewDeletion(snapshot) } }.disabled(!deletable(snapshot))
            }.padding(.horizontal, 4).padding(.vertical, 4)
        }
    }

    private func guestHome(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            GroupedPanel {
                HStack(spacing: 20) {
                    GuestArtwork(size: 116, state: snapshot.state)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            SpecHeading("resources")
                            Spacer(minLength: 0)
                            Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                        }.padding(.bottom, 8)
                        SpecRow("cores", value: "\(snapshot.profile.cpus)")
                        SpecRow("memory", value: "\(snapshot.profile.memoryMiB / 1024) GiB")
                        SpecRow("disk", value: snapshot.profile.diskSummary)
                        SpecRow("used", value: ByteCountFormatter.string(fromByteCount: model.storageBytes[snapshot.id] ?? 0, countStyle: .file))
                        SpecRow("clipboard", value: snapshot.profile.clipboardEnabled ? "Enabled" : "Off", note: snapshot.profile.clipboardEnabled ? "Syncs with the Mac while this guest is focused." : "Clipboard sharing is off for this guest.")
                        SpecRow("touch id", value: GuestTouchIDRecord(snapshot).hostBridge.capitalized, note: "Pair through Setup → Security → Touch ID for sudo inside the guest. Guest pairing status is unknown to the manager.")
                    }
                }.padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 14)
            }
            if let job = model.setupSummary(for: snapshot.id) {
                Button { page = .setup } label: { Label(job.title, systemImage: job.cleanupRequired ? "exclamationmark.shield" : "terminal") }.buttonStyle(.plain).padding(.horizontal, 4)
            }
            GuestHibernationPanel(snapshot: snapshot, review: { action in model.experimentalPowerReview = .init(id: snapshot.id, action: action) }, recheck: { Task { await model.recheckExperimentalRecovery(snapshot.id) } })
            GuestHomeBackupPanel(snapshot: snapshot,
                                 review: { model.homeBackupReview = snapshot },
                                 cancel: { Task { await model.cancelHomeBackup(snapshot.id) } })
        }
    }

    private func paneNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 2)
    }

    private func status(_ text: String) -> some View {
        Text(text).font(Theme.mono(13)).foregroundStyle(.secondary)
    }

    private func resources(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            SpecPane("resources", action: {
                Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
            }) {
                SpecRow("cores", value: "\(snapshot.profile.cpus)")
                SpecRow("memory", value: "\(snapshot.profile.memoryMiB / 1024) GiB")
                SpecRow("disk", value: snapshot.profile.diskSummary, note: "Factory: \(snapshot.profile.factory?.displayName ?? "Original recorded disk"). Existing disks are preserved.") {
                    status(ByteCountFormatter.string(fromByteCount: model.storageBytes[snapshot.id] ?? 0, countStyle: .file))
                }
            }
            paneNote(snapshot.profile.isRetainedPOC ? "This profile’s original configuration is preserved with its retained disk." : "Shut down this guest to change its name, resources, guest Touch ID or clipboard. Changes apply on its next start.")
        }
    }

    private func network(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            SpecPane("network") {
                SpecRow("network", value: "Shared (NAT)", note: "Uses your Mac’s connection") { status("NAT") }
                SpecRow("forwarding", value: snapshot.profile.ssh.map { "SSH · 127.0.0.1:\($0.hostPort) → guest TCP 22" }, note: snapshot.profile.ssh == nil ? "This guest starts without host port forwards." : nil) { status(snapshot.profile.ssh == nil ? "Off" : "SSH") }
                SpecRow("host folder", note: snapshot.profile.sharedFolder.map { $0.enabled ? "\($0.hostPath) → \($0.guestPath) · Read & write" : "Sharing off · Remembered folder: \($0.hostPath)" } ?? "No host folder is exposed.") {
                    status(snapshot.sharedFolderReadiness.label)
                    Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
            }
            paneNote("Managed SSH uses a guest-specific Mac loopback port. Host-folder changes apply on the next start. Disable sharing in Configure to remove the export on that start. Guest Touch ID is configured separately. USB and camera remain off.")
        }
    }

    private func startup(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            SpecPane("startup") {
                SpecRow("immersive mode", note: "Open full screen with the Mac menu bar and Dock hidden.") {
                    status(snapshot.profile.immersiveMode.map { $0 ? "On" : "Off" } ?? "Original setting")
                    Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
                SpecRow("launch", note: "Guests start only when you choose Launch. Reopening the manager restores the list.") { status("Manual") }
            }
            paneNote("Windowed mode is recommended when assigning guests to existing Mission Control desktops.")
        }
    }

    private func ssh(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            SpecPane("ssh from this mac") {
                SpecRow("endpoint", value: snapshot.profile.ssh.map { "127.0.0.1:\($0.hostPort) → guest port 22" }, note: snapshot.profile.ssh == nil ? "SSH is off for this profile." : nil) {
                    status(snapshot.sshReadiness.label)
                }
                if let options = snapshot.profile.ssh {
                    SpecRow("login key", note: "An independent managed key is kept on this Mac. Only its public key is enrolled in the guest.")
                    if let fingerprint = options.publicKeyFingerprint {
                        SpecRow("your key", value: fingerprint)
                    }
                }
                if snapshot.profile.ownerSetup != nil {
                    SpecRow("owner setup", note: snapshot.ownerSetupReadiness.label)
                }
            }
            if case .ready(let user, let command) = snapshot.sshReadiness {
                paneNote("Authenticated as \(user). The guest’s host identity is pinned.")
                Button("Copy SSH Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }.buttonStyle(.primaryAction).padding(.horizontal, 4)
            } else if snapshot.profile.ssh != nil {
                paneNote("Complete the guest’s normal owner-account setup. The manager then verifies key-based SSH independently of its desktop and clipboard. Guest host keys are provisioned once and checked on every connection.")
                if snapshot.sessionID != nil {
                    Button("Retry SSH Check") { Task { await model.retrySSH(snapshot.id) } }.disabled(snapshot.state != .running).padding(.horizontal, 4)
                }
            } else {
                paneNote("SSH is enabled by default when creating a new VM. Existing profiles are unchanged; retained POC disks stay protected.")
            }
        }
    }

    private func spaces(_ snapshot: VMSnapshot) -> some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: 0) {
                SpecHeading("mission control spaces")
                Text("Use the guest’s own Dock icon to choose its desktop.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4).padding(.bottom, 10)
                let steps = ["Launch this guest in windowed mode.", "Move its window to the desktop you want in Mission Control.", "Control-click “\(snapshot.profile.name)” in the Dock.", "Choose Options → Assign To → This Desktop."]
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)").font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 24, alignment: .leading).accessibilityHidden(true)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Each storage root has a stable guest app identity, independent of its display name. macOS manages the assignment. To release it, choose Assign To → None.").font(.system(size: 13)).foregroundStyle(.secondary)
                    if snapshot.profile.isRetainedPOC { Text("Retained POC guests keep their original display settings. New guests start in windowed mode.").font(.callout).foregroundStyle(.secondary) }
                    Link("Apple’s guide to Mission Control Spaces", destination: URL(string: "https://support.apple.com/guide/mac-help/mh14112/mac")!)
                    Text("Assignment persistence across guest restarts needs verification on this Mac with the updated runtime.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ScreenHeader("Permissions")
            SpecPane("permissions") {
                SpecRow("accessibility", note: "Needed for native Super shortcuts such as Command+Space inside guests.") {
                    if model.accessibilityTrusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                    else { Button("Enable Super shortcuts…") { Task { await model.requestSuperShortcuts() } }.disabled(!active.isEmpty) }
                }
                SpecRow("camera, auth", note: "These optional bridges are disabled in the current manager.") { status("Off") }
            }
            paneNote("Enable permissions yourself in System Settings. A new ad-hoc build can need a refreshed Accessibility grant. Shut down guests before refreshing it.")
        }
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ScreenHeader("Runtime")
            SpecPane("try omarchy kit", action: {
                Button("Check Again") { Task { await model.refresh() } }.disabled(model.checking)
            }) {
                SpecRow("runtime", value: model.diagnostics == nil ? (model.diagnosticError ?? "Checking…") : "Pinned private runtime · Focus-aware clipboard")
                if let d = model.diagnostics {
                    SpecRow("protocol", value: "\(d.runProtocolVersion)")
                    SpecRow("preflight", value: d.preflightFailure ?? "Passed")
                    DisclosureGroup("Build provenance") { Text(d.patchCommit).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }
                        .padding(.vertical, 8).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            SpecPane("known issue") {
                SpecRow("graphics", note: "A guest may occasionally open with a black or incomplete desktop. Investigation is ongoing.")
            }
        }
    }

    private func controls(_ snapshot: VMSnapshot) -> some View {
        GuestControls(snapshot: snapshot, launchEnabled: !model.checking && model.diagnostics != nil && model.registryError == nil && !model.shuttingDown,
                      start: { focusGuest(snapshot.id); Task { await model.start(snapshot.id) } }, stop: { Task { await model.stop(snapshot.id) } },
                      forceStop: { model.forceStopID = snapshot.id },
                      pause: { Task { await model.pause(snapshot.id) } }, resume: { Task { await model.resume(snapshot.id) } },
                      suspendToDisk: { model.experimentalPowerReview = .init(id: snapshot.id, action: .suspend) },
                      restoreSuspension: { model.experimentalPowerReview = .init(id: snapshot.id, action: .restore) })
    }
    private func focusGuest(_ id: UUID) {
        destination = .guest(id)
        page = .home
        detailPresentation = UUID()
    }
    private func deletable(_ snapshot: VMSnapshot) -> Bool { snapshot.sessionID == nil && snapshot.suspension == nil && !snapshot.suspensionMetadataUnsafe && snapshot.state.canStart && !model.shuttingDown }
    private func editable(_ snapshot: VMSnapshot) -> Bool { deletable(snapshot) && !snapshot.profile.isRetainedPOC }
}

struct GroupedPanel<Content: View>: View {
    var dashed = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.pane, in: RoundedRectangle(cornerRadius: Theme.paneRadius))
            .overlay {
                if dashed { RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.lavender.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                else { RoundedRectangle(cornerRadius: Theme.paneRadius).strokeBorder(Theme.border) }
            }
    }
}
private struct GuestTabs: View {
    @Binding var page: GuestPage
    var body: some View {
        GroupedPanel {
            HStack(spacing: 4) {
                ForEach(GuestPage.allCases, id: \.self) { item in
                    let selected = item == page
                    Button { page = item } label: {
                        Text(item.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular)).foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(selected ? Theme.green.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                            .overlay { if selected { RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.green) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(5)
        }
    }
}
private struct EditorSelection: Identifiable { let id = UUID(); let profile: VMProfile?; var reuseSource: VMProfile? = nil }
struct VMEditor: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let profile: VMProfile?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var memory: Int
    @State private var cpus: Int
    @State private var disk: Int
    @State private var guestTouchID: Bool
    @State private var separateHome: Bool
    @State private var homeDisk: Int
    @State private var reuseHomeFrom: UUID?
    @State private var clipboard: Bool
    @State private var immersive: Bool
    @State private var share: Bool
    @State private var sharePath: String
    @State private var saving = false
    @State private var sshEnabled: Bool
    @State private var selectedPublicKey: String?
    @State private var keyError: String?
    @State private var factory = "official"
    @State private var importingFactory = false
    @State private var useOwnerDefaults: Bool
    @State private var setupSource: ProvisioningSetupSource?
    @State private var creationAttempt: CreationAttempt?
    private struct CreationAttempt {
        let id: UUID
        let configuration: GuestConfigurationPatch
        let source: ProvisioningSetupSource?
    }
    @State private var setupBlocker: NewVMSetupBlocker?
    @State private var openPane: Pane?
    init(model: AppModel, profile: VMProfile?, reuseSource: VMProfile? = nil, saved: @escaping (UUID) -> Void) {
        self.model = model; self.profile = profile; self.saved = saved
        _name = State(initialValue: profile?.name ?? reuseSource.map { $0.name + " Replacement" } ?? "")
        _memory = State(initialValue: (profile?.memoryMiB ?? 4096) / 1024)
        _cpus = State(initialValue: profile?.cpus ?? 4)
        _disk = State(initialValue: profile?.diskGiB ?? model.diskDefaults.systemDiskGiB)
        _separateHome = State(initialValue: profile.map { $0.homeDisk != nil } ?? (reuseSource != nil || model.diskDefaults.separateHome))
        _homeDisk = State(initialValue: profile?.homeDisk?.sizeGiB ?? reuseSource?.homeDisk?.sizeGiB ?? model.diskDefaults.homeDiskGiB)
        _reuseHomeFrom = State(initialValue: reuseSource?.id)
        _guestTouchID = State(initialValue: profile?.guestTouchIDEnabled ?? false)
        _clipboard = State(initialValue: profile?.clipboardEnabled ?? true)
        _immersive = State(initialValue: profile?.immersiveMode ?? false)
        _share = State(initialValue: profile?.sharedFolder?.enabled ?? false)
        _sharePath = State(initialValue: profile?.sharedFolder?.hostPath ?? SharedFolderMapping.defaultPath)
        _useOwnerDefaults = State(initialValue: reuseSource.map { $0.ownerSetup != nil } ?? (profile == nil && model.ownerDefaults?.isConfigured == true))
        _selectedPublicKey = State(initialValue: profile == nil && model.ownerDefaults?.isConfigured == true ? model.ownerDefaults?.sshPublicKey : nil)
        _sshEnabled = State(initialValue: profile.map { $0.ssh != nil } ?? true)
    }
    private var saveBlocker: String? {
        if saving { return profile == nil ? (setupSource == nil ? "Creating VM…" : "Preparing setup and creating VM…") : "Saving changes…" }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this VM." }
        return profile == nil ? setupBlocker?.message : nil
    }
    private var canSave: Bool { saveBlocker == nil }
    private var maximumMemory: Int { max(4, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) * 3 / 4) }
    private enum Pane: String { case software, resources, access }
    private func paneBinding(_ pane: Pane) -> Binding<Bool> {
        Binding(get: { openPane == pane }, set: { openPane = $0 ? pane : nil })
    }
    private var softwareSummary: String {
        guard let setupSource else { return setupBlocker?.message ?? "No developer setup" }
        let titles = (setupSource.profiles ?? []).map { $0 == "project-managed" ? "Project managed" : $0.capitalized }
        var parts = setupSource.directory == nil ? [] : ["Local folder"]
        if !titles.isEmpty { parts.append(titles.joined(separator: " + ")) }
        if setupSource.trimOptionalApps == true { parts.append("trimmed") }
        return parts.joined(separator: " · ")
    }
    private var resourcesSummary: String {
        var parts = ["\(cpus) cores", "\(memory) GiB", "\(disk) GiB system"]
        if separateHome { parts.append(reuseHomeFrom == nil ? "\(homeDisk) GiB home" : "reused home") }
        return parts.joined(separator: " · ")
    }
    private var accessSummary: String {
        var parts: [String] = []
        if clipboard { parts.append("clipboard") }
        if immersive { parts.append("immersive") }
        if guestTouchID { parts.append("touch id") }
        if share && sshEnabled { parts.append("host folder") }
        if sshEnabled { parts.append("ssh") }
        if profile == nil { parts.append(useOwnerDefaults ? "automatic account" : "manual account") }
        return parts.joined(separator: " · ")
    }
    private var ownerNote: String {
        if useOwnerDefaults, let config = reuseHomeFrom.flatMap({ id in model.snapshots.first(where: { $0.id == id })?.profile.ownerSetup?.configuration }) ?? model.ownerDefaults?.configuration {
            return "Automatic setup as \(config.username) · \(config.keyboardID). A unique hostname is assigned."
        }
        return model.ownerDefaults?.isConfigured == true ? "Account setup: Manual. Omarchy will ask for account details on first boot." : "Account setup: Manual. Save account details and a password in Guest Defaults to apply them automatically to new VMs."
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(profile == nil ? "New Virtual Machine" : "Configure Virtual Machine").font(.system(size: 20, weight: .semibold)).padding(.bottom, 10)
            SpecRow("name") {
                TextField("Name", text: $name, prompt: Text("Enter a name")).labelsHidden().specField().frame(width: 400)
            }
            if profile == nil {
                SpecRow("factory") {
                    Picker("Factory image", selection: $factory) {
                        ForEach(model.factories, id: \.selector) { image in Text(image.displayName).tag(image.selector) }
                    }.labelsHidden().frame(maxWidth: 250)
                    Button("Import Factory…") { importingFactory = true }
                        .disabled(saving || model.factoryImportInProgress || model.checking || model.diagnostics == nil)
                }
                if let notice = model.factorySelectionNotice { SpecNote(notice).padding(.bottom, 8) }
            } else {
                SpecRow("factory", value: profile?.factory?.displayName ?? "Legacy original disk")
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6).disabled(saving)
    }
    private var resourceRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecStepperRow("memory", value: $memory, in: 4...maximumMemory, unit: " GiB")
            SpecStepperRow("cores", value: $cpus, in: 4...max(4, ProcessInfo.processInfo.processorCount))
            SpecStepperRow("system disk", value: $disk, in: max(64, profile?.diskGiB ?? 64)...8192, step: 16, unit: " GiB")
            SpecToggleRow("separate home", isOn: $separateHome).disabled(profile != nil)
                .onChange(of: separateHome) { _, value in if !value { reuseHomeFrom = nil } }
            if separateHome {
                SpecStepperRow("home disk", value: $homeDisk, in: max(16, profile?.homeDisk?.sizeGiB ?? 16)...8192, step: 16, unit: " GiB").disabled(reuseHomeFrom != nil)
                if profile == nil {
                    SpecRow("home data") {
                        Picker("Home data", selection: $reuseHomeFrom) {
                            Text("New empty home disk").tag(UUID?.none)
                            ForEach(model.snapshots.filter { $0.sessionID == nil && $0.profile.homeDisk != nil }) { source in
                                Text("Reuse from \(source.profile.name)").tag(Optional(source.id))
                            }
                        }.labelsHidden().frame(maxWidth: 260).onChange(of: reuseHomeFrom) { _, value in
                            if let source = model.snapshots.first(where: { $0.id == value }) {
                                homeDisk = source.profile.homeDisk!.sizeGiB; useOwnerDefaults = source.profile.ownerSetup != nil
                            } else {
                                useOwnerDefaults = model.ownerDefaults?.isConfigured == true
                            }
                        }
                    }
                    if reuseHomeFrom != nil {
                        SpecNote("Creates a replacement VM. On first launch, APFS cloning copies the stopped source’s home without changing it. The source must remain stopped until that copy finishes. Its original owner setup is retained.").padding(.bottom, 8)
                    }
                }
            }
        }
    }
    private var accessRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecToggleRow("clipboard", isOn: $clipboard)
            SpecToggleRow("immersive mode", isOn: $immersive)
            SpecToggleRow("touch id", note: "Enables the host bridge at next start. Pair sudo explicitly inside the guest; pairing status is checked there. Uses the Linux password if Touch ID is unavailable.", isOn: $guestTouchID)
            SpecToggleRow("host folder", note: sshEnabled ? nil : "Managed SSH is required to verify a shared mount.", isOn: $share).disabled(!sshEnabled)
            if share {
                SpecRow("path") { TextField("Host folder", text: $sharePath).labelsHidden().specField().frame(width: 260) }
                SpecNote("Exposes \(sharePath) at /mnt/mac · Read & write. The guest can modify or delete files in this folder. Use a dedicated folder without credentials. Changes apply next start.").textSelection(.enabled).padding(.bottom, 8)
            }
            if profile == nil {
                if model.ownerDefaults?.isConfigured == true || reuseHomeFrom != nil {
                    SpecToggleRow("manual account", note: ownerNote, isOn: Binding(get: { !useOwnerDefaults }, set: { useOwnerDefaults = !$0 })).disabled(reuseHomeFrom != nil)
                } else {
                    SpecRow("account", note: ownerNote)
                }
            } else if let setup = profile?.ownerSetup {
                SpecRow("owner defaults", note: "Owner defaults snapshot: \(setup.configuration.username) · \(setup.hostname). First-boot answers cannot be changed here.")
            }
            SpecToggleRow("ssh", note: profile == nil ? "SSH uses a separate localhost port and automatic per-guest keys after account setup." : "SSH enrollment is chosen at creation. Existing access is preserved.", isOn: $sshEnabled).disabled(profile != nil)
                .onChange(of: sshEnabled) { _, value in if !value { share = false } }
            if sshEnabled, profile == nil {
                SpecRow("public key", note: "Optional") {
                    if selectedPublicKey != nil { Button("Remove Selected Key") { selectedPublicKey = nil } }
                    Button("Choose .pub…") { choosePublicKey() }
                }
                if let key = selectedPublicKey, let fingerprint = try? SSHPublicKey.fingerprint(key) {
                    SpecNote(fingerprint).textSelection(.enabled).padding(.bottom, 8)
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            if profile == nil {
                DisclosurePaneRow(key: "software", summary: softwareSummary, isOpen: paneBinding(.software)) {
                    NewVMSetupSelectionView(model: model, factory: $factory, selection: $setupSource, blocker: $setupBlocker).disabled(saving)
                }
            }
            DisclosurePaneRow(key: "resources", summary: resourcesSummary, isOpen: paneBinding(.resources)) { resourceRows.disabled(saving) }
            DisclosurePaneRow(key: "access", summary: accessSummary, isOpen: paneBinding(.access)) { accessRows.disabled(saving) }
            VStack(alignment: .leading, spacing: 10) {
            if let error = keyError { Text(error).foregroundStyle(.red).font(.callout) }
            if let error = model.configurationError { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(profile == nil ? "The selected factory prepares on first launch. Each guest has independent storage. Networking uses NAT. Host-folder sharing and guest Touch ID are opt-in. USB and camera are off." : "Changes apply the next time this guest starts. Its existing disk is preserved.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let saveBlocker {
                Label(saveBlocker, systemImage: saving ? "hourglass" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("new-vm.validation")
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(profile == nil ? "Create VM" : "Save Changes") {
                    save()
                }.accessibilityIdentifier("new-vm.create").buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            }.padding(.horizontal, 20).padding(.vertical, 12).overlay(alignment: .top) { Rectangle().fill(Theme.strongBorder).frame(height: 1) }
        }.frame(width: 620).background(Theme.pane).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle()).interactiveDismissDisabled(saving)
        .onChange(of: setupBlocker) { _, value in if value != nil { openPane = .software } }
        .onChange(of: useOwnerDefaults) { _, value in
            if value { selectedPublicKey = model.ownerDefaults?.sshPublicKey }
            else if selectedPublicKey == model.ownerDefaults?.sshPublicKey { selectedPublicKey = nil }
        }.onAppear { model.configurationError = nil }.task { await model.loadFactories() }
        .sheet(isPresented: $importingFactory) {
            FactoryImportView(model: model) { identity in factory = identity.selector }
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("editor", action: { command in
                    switch command {
                    case .factory(let value): factory = value
                    case .name(let value): name = value
                    case .ownerDefaults(let value): if reuseHomeFrom == nil { useOwnerDefaults = value && model.ownerDefaults?.isConfigured == true }
                    case .resources(let ram, let cores, let size): memory = ram; cpus = cores; disk = size
                    case .save: save()
                    case .section(let value): openPane = Pane(rawValue: value)
                    default: break
                    }
                }, snapshot: { ["name": name, "memory": String(memory), "cpus": String(cpus), "disk": String(disk), "ready": String(setupBlocker == nil), "ownerDefaults": String(useOwnerDefaults), "hasSetup": String(setupSource != nil), "failure": model.configurationError ?? "", "saving": String(saving), "canSave": String(canSave), "validation": saveBlocker ?? ""] })
            } }
            #endif
        }
    }
    private func save() {
        guard canSave else { return }
        let config = GuestConfigurationPatch(name: name.trimmingCharacters(in: .whitespacesAndNewlines), memoryMiB: memory * 1024, cpus: cpus, diskGiB: disk,
            clipboard: clipboard, immersive: immersive, guestTouchID: guestTouchID, ssh: sshEnabled, ownerDefaults: useOwnerDefaults,
            publicKey: sshEnabled ? selectedPublicKey : nil, factory: factory, inheritDefaultPublicKey: false,
            share: share, sharePath: sharePath, separateHome: separateHome, homeDiskGiB: separateHome ? homeDisk : nil, reuseHomeFrom: reuseHomeFrom)
        // A repeated identical submission reuses its frozen inputs and reservation.
        // Editing any configuration or source field starts a different attempt.
        if creationAttempt?.configuration != config || creationAttempt?.source != setupSource {
            creationAttempt = .init(id: UUID(), configuration: config, source: setupSource)
        }
        let requestID = creationAttempt!.id
        saving = true
        // Capture all form values before preparation can suspend. Even a late
        // programmatic edit cannot change the configuration being confirmed.
        Task { [profile, setupSource, name = config.name!, memory, cpus, disk, clipboard, guestTouchID, immersive, sshEnabled, publicKey = config.publicKey, useOwnerDefaults, factory, share, sharePath, separateHome, homeDisk, reuseHomeFrom] in
            if let id = await model.save(profile, name: name, memoryGiB: memory, cpus: cpus, diskGiB: disk, clipboard: clipboard, guestTouchID: guestTouchID, immersive: immersive, sshEnabled: sshEnabled, publicKey: publicKey, useOwnerDefaults: useOwnerDefaults, factory: factory, share: share, sharePath: sharePath, separateHome: separateHome, homeDiskGiB: homeDisk, reuseHomeFrom: reuseHomeFrom, setupSource: setupSource, setupRequestID: requestID) { saved(id) }
            saving = false
        }
    }

    private func choosePublicKey() {
        do { if let key = try PublicKeyPicker.choose() { selectedPublicKey = key; keyError = nil } }
        catch { keyError = error.localizedDescription }
    }

}

private struct ManagerLoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ManagerArtwork(size: 112)
            VStack(spacing: 8) {
                Text(AppChannel.current.displayName).font(.title.bold())
                Text("Loading your virtual machines…")
                    .foregroundStyle(.secondary)
            }
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel("Loading your virtual machines")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(AppChannel.current.displayName)
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
