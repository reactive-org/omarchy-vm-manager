import AppKit
import OmarchyVMManagerCore
import SwiftUI

private enum Destination: Hashable { case library, guest(UUID), permissions, runtime, defaults, provisioningTools, factoryImages }
private enum GuestPage: String, CaseIterable { case home = "Home", resources = "Virtual machine", network = "Network", startup = "Startup", ssh = "SSH", spaces = "Spaces", setup = "Setup" }

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var destination: Destination? = .library
    @State private var editor: EditorSelection?
    @State private var importingFactory = false
    @State private var page: GuestPage = .home
    @State private var setupSheet: SetupSheet?
    @State private var detailPresentation = UUID()
    @FocusState private var sidebarFocused: Bool
    init(model: AppModel) { self.model = model }
    #if DEBUG
    init(model: AppModel, acceptanceGuestID: UUID, acceptancePage: String = GuestPage.setup.rawValue) {
        self.model = model; _destination = State(initialValue: .guest(acceptanceGuestID)); _page = State(initialValue: GuestPage(rawValue: acceptancePage) ?? .setup)
    }
    init(model: AppModel, acceptanceManagerPage: String) {
        self.model = model; _destination = State(initialValue: acceptanceManagerPage == "runtime" ? .runtime : .permissions)
    }
    #endif
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @Environment(\.featureFlags) private var features
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
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("manager", action: { _ in }, snapshot: {
                    let guest: String = { if case .guest(let id) = destination { return id.uuidString }; return "" }()
                    return ["guest": guest, "page": page.rawValue, "sheet": setupSheet?.rawValue ?? ""]
                })
            } }
            #endif
        }
    }

    private var navigationContent: some View {
        NavigationSplitView {
            // The sidebar scroll view lays out below the toolbar but draws with the toolbar inset a second time,
            // which shifts rows 52 pt below their click targets. Ignore the top safe area and pad by it instead.
            GeometryReader { geometry in ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            sidebarHeader("guests")
                            if model.snapshots.isEmpty, model.registryError == nil {
                                Text("No guests yet").font(Theme.sans(13)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                            }
                            let attention = model.setupAttention
                            ForEach(model.snapshots) { snapshot in
                                let needsYou = attention[snapshot.id] != nil
                                sidebarRow(.guest(snapshot.id)) {
                                    HStack(spacing: 9) {
                                        GuestArtwork(size: 28, state: snapshot.state)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(snapshot.profile.name).lineLimit(1)
                                            HStack(spacing: 6) {
                                                GuestStatusMarker(active: snapshot.sessionID != nil)
                                                Text(snapshot.profile.isRetainedPOC ? "Retained POC · \(snapshot.state.label)" : snapshot.state.label).font(Theme.note).foregroundStyle(snapshot.sessionID == nil ? Color.secondary : Theme.green).lineLimit(1)
                                            }
                                        }
                                    }.padding(.trailing, needsYou ? NeedsYouBadge.width : 0)
                                }
                                // Outside the row's button so it is its own click target.
                                .overlay(alignment: .trailing) {
                                    if needsYou {
                                        NeedsYouBadge(guestID: snapshot.id, guestName: snapshot.profile.name) { model.openAttention(snapshot.id) }.padding(.trailing, 6)
                                    }
                                }
                            }
                            sidebarHeader("manager")
                            sidebarLink("Guest defaults", systemImage: "person.crop.circle.badge.checkmark", .defaults)
                            sidebarLink("Factory images", systemImage: "square.3.layers.3d", .factoryImages)
                            sidebarLink("Permissions", systemImage: "hand.raised", .permissions)
                            sidebarLink("Runtime", systemImage: "checkmark.shield", .runtime)
                            sidebarLink("Provisioning tools", systemImage: "wrench.and.screwdriver", .provisioningTools)
                        }.padding(.horizontal, 10).padding(.top, geometry.safeAreaInsets.top + 8).padding(.bottom, 8)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(AppChannel.current.displayName + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–") + ")")
                                .font(Theme.mono(11))
                            Text("A project of [reactive.org enterprises](https://www.reactive.org/)").foregroundStyle(.secondary)
                        }.font(Theme.note).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Theme.pane)
                    }
                    .onChange(of: destination) { if let destination { proxy.scrollTo(destination) } }
                    .ignoresSafeArea(.container, edges: .top)
            } }
            .focusable().focused($sidebarFocused).focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel("Sidebar")
            .background(Theme.pane).navigationSplitViewColumnWidth(min: 230, ideal: 255, max: 330)
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
                    case .factoryImages: FactoryImagesView(model: model) { factory in
                        model.builtFactoryAvailable(factory)
                        editor = EditorSelection(profile: nil, initialFactory: factory.selector)
                    }
                    default: library
                    }
                }.padding(Theme.gap).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
            }.id(detailPresentation).environment(\.guestsRunning, model.snapshots.contains { $0.sessionID != nil }).font(Theme.body).background(Theme.ground).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle())
        }
        .navigationTitle(AppChannel.current.displayName)
        .toolbar {
            // The app icon sits before the window title and returns to the overview.
            ToolbarItem(placement: .navigation) {
                Button { destination = .library } label: { ManagerArtwork(size: 22) }
                    .buttonStyle(.plain).help("Show all virtual machines").accessibilityLabel("All virtual machines")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { importingFactory = true } label: { Label("Import factory", systemImage: "square.and.arrow.down") }
                    .disabled(model.registryError != nil || model.shuttingDown || model.checking || model.diagnostics == nil || model.factoryImportInProgress)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editor = EditorSelection(profile: nil) } label: { Label("New VM", systemImage: "plus") }
                    .disabled(model.registryError != nil || model.shuttingDown)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onChange(of: destination) { page = .home }
        // Only explicit clicks route here (badge, notification); activation alone never does.
        .onChange(of: model.attentionRoute) { _, route in
            guard let route else { return }
            model.attentionRoute = nil
            openRoute(route)
        }
        .onChange(of: visibleGuest, initial: true) { _, value in model.visibleGuest = value }
        .onChange(of: model.snapshots.compactMap(\.sessionID)) { previous, current in
            guard let session = current.last(where: { !previous.contains($0) }),
                  let snapshot = model.snapshots.first(where: { $0.sessionID == session }) else { return }
            focusGuest(snapshot.id)
        }
        .sheet(isPresented: $importingFactory) { FactoryImportView(model: model) }
        .sheet(item: $editor) { selection in
            VMEditor(model: model, profile: selection.profile, reuseSource: selection.reuseSource, initialFactory: selection.initialFactory, launchAvailable: launchAvailable) { id, launch in
                focusGuest(id)
                editor = nil
                // Create and Launch is the user's explicit request to start this new guest.
                // With a setup selected it is also the one-time first-run approval.
                if launch { model.armAutoSetup(id); Task { await model.start(id) } }
            }
        }
        .sheet(isPresented: $model.shuttingDown) { ProgressView("Shutting down VMs…").padding(40).interactiveDismissDisabled() }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title).font(Theme.mono(11)).foregroundStyle(Theme.label).textCase(nil)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }

    /// Sidebar destinations in visual order, for arrow-key navigation.
    private var sidebarOrder: [Destination] {
        model.snapshots.map { .guest($0.id) } + [.defaults, .factoryImages, .permissions, .runtime, .provisioningTools]
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let order = sidebarOrder
        let current = destination.flatMap(order.firstIndex(of:)) ?? 0
        destination = order[min(max(current + offset, 0), order.count - 1)]
        return .handled
    }

    private func sidebarRow<Content: View>(_ target: Destination, @ViewBuilder content: () -> Content) -> some View {
        Button { destination = target; sidebarFocused = true } label: { content() }
            .buttonStyle(SidebarRowButtonStyle(selected: destination == target, focused: sidebarFocused))
            .accessibilityAddTraits(destination == target ? .isSelected : [])
            .id(target)
    }

    private func sidebarLink(_ title: String, systemImage: String, _ target: Destination) -> some View {
        sidebarRow(target) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .light)).foregroundStyle(destination == target ? Theme.green : Color.secondary).frame(width: 20)
                Text(title)
            }.frame(minHeight: 26)
        }
    }

    private var backupConfirmationContent: some View {
        navigationContent
        .alert("Back up the guest home?", isPresented: Binding(get: { model.homeBackupReview != nil }, set: { if !$0 { model.homeBackupReview = nil } })) {
            Button("Back up home") {
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
            Button("Force stop", role: .destructive) { if let id = model.forceStopID { model.forceStopID = nil; Task { await model.forceStop(id) } } }
            Button("Cancel", role: .cancel) { model.forceStopID = nil }
        } message: { Text("Unsaved guest work can be lost. Prefer Shut Down when the guest responds.") }
        .alert("Move this VM to Trash?", isPresented: Binding(get: { model.deletionReview != nil }, set: { if !$0 { model.deletionReview = nil } })) {
            Button(model.deletionReview?.identity == nil ? "Remove profile" : "Move to Trash", role: .destructive) {
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
                        Text("Virtual machines").font(Theme.sans(15, weight: .semibold)).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
                        ForEach(model.snapshots) { snapshot in
                            GuestLibraryRow(snapshot: snapshot, open: { focusGuest(snapshot.id) }) { controls(snapshot) }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private func guest(_ snapshot: VMSnapshot) -> some View {
        guestPage(snapshot)
            .sheet(item: $setupSheet) { sheet in
                let current = model.snapshots.first(where: { $0.id == snapshot.id }) ?? snapshot
                if sheet == .change {
                    ChangeSetupView(model: model, snapshot: current, close: { setupSheet = nil }, openOutput: { setupSheet = .output })
                } else {
                SetupSheetFrame(title: sheet == .output ? "Setup output" : current.profile.developerSetup == nil && !model.setupWorkflows.contains(where: { $0.vmID == current.id }) ? "Set up " + current.profile.name : "Change setup",
                                subtitle: current.profile.name + (sheet == .output ? " · closing this leaves setup running" : " · setup runs in the guest and restarts it once to finish"),
                                status: sheet == .output ? SetupCardState.make(current, workflows: model.setupWorkflows, jobs: model.setupJobs, autoSetup: model.autoSetup[current.id], checkOnly: model.checkOnlyRuns) : nil,
                                close: { setupSheet = nil }) {
                    DeveloperSetupView(model: model, snapshot: current, mode: .output)
                }
                }
            }
    }

    private func guestPage(_ snapshot: VMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            GuestHeaderPane(snapshot: snapshot) { controls(snapshot) }
            GuestTabs(page: $page)
            if snapshot.profile.isRetainedPOC {
                Label("This POC disk keeps its original configuration. Delete VM moves it to Trash after confirmation.", systemImage: "info.circle").font(Theme.sans(13)).foregroundStyle(.secondary)
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
                if let notice = snapshot.notice { Label(notice, systemImage: "info.circle").font(Theme.sans(13)).lineLimit(2).help(notice) }
                else { Color.clear }
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 38, alignment: .top)
            if let failure = snapshot.lastFailure {
                GroupedPanel { VStack(alignment: .leading, spacing: 10) {
                    Label("\(failure.code)", systemImage: "exclamationmark.triangle").font(Theme.sans(14, weight: .semibold))
                    Text(failure.message)
                    if !failure.diagnostics.isEmpty { DisclosureGroup("Helper diagnostics") { Text(failure.diagnostics).font(Theme.mono(12)).textSelection(.enabled) } }
                }.padding(20) }
            }
            let events = model.records.filter { $0.vmID == snapshot.id }
            GroupedPanel {
                DisclosureGroup("Session activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events.suffix(30).reversed())) { Text("\($0.date.formatted(date: .omitted, time: .standard))  \($0.text)").font(Theme.mono(12)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }.disabled(events.isEmpty).padding(.horizontal, 20).padding(.vertical, 12)
            }
            HStack(spacing: 12) {
                if !snapshot.profile.isRetainedPOC {
                    Button("Rename or configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                }
                OmarchyAttribution().frame(maxWidth: .infinity)
                Button("Delete VM…", role: .destructive) { Task { await model.reviewDeletion(snapshot) } }.disabled(!deletable(snapshot))
            }.padding(.horizontal, 4).padding(.vertical, 4)
        }
    }

    private func guestHome(_ snapshot: VMSnapshot) -> some View {
        let firstRun = FirstRunProgress.make(snapshot, workflows: model.setupWorkflows, jobs: model.setupJobs, autoSetup: model.autoSetup[snapshot.id], checkOnly: model.checkOnlyRuns)
        // After the first run, a run under way is followed here, like New VM's first run.
        let run: SetupRunPhase? = firstRun != nil ? nil : SetupRunPhase.active(model.setupWorkflows.filter { $0.vmID == snapshot.id }, auto: model.autoSetup[snapshot.id], checkOnly: model.checkOnlyRuns)
            .flatMap { if case .cleanup = $0 { nil } else { $0 } }
        return VStack(alignment: .leading, spacing: Theme.gap) {
            if let source = model.officialFactorySource, let (phase, percent) = GuestFactoryDownloadCard.phase(snapshot) {
                GuestFactoryDownloadCard(source: source, phase: phase, percent: percent)
            }
            if let firstRun {
                FirstRunTracker(progress: firstRun) { setupSheet = .change }
                if let terminal = firstRun.terminal {
                    FirstRunTerminal(model: model, workflowID: terminal.workflowID, attachmentKey: terminal.key, live: terminal.live) { setupSheet = .output }
                }
            } else if let run {
                SetupRunPanel(model: model, snapshot: snapshot, phase: run) { setupSheet = $0 }
            } else if model.setupCompletedThisRun.contains(snapshot.id) {
                FirstRunComplete(viewLog: { setupSheet = .output }, dismiss: { model.setupCompletedThisRun.remove(snapshot.id) })
            }
            GroupedPanel {
                HStack(spacing: 20) {
                    GuestArtwork(size: 116, state: snapshot.state)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            SpecHeading("resources")
                            Spacer(minLength: 0)
                            Button("Configure…") { editor = EditorSelection(profile: snapshot.profile) }.disabled(!editable(snapshot))
                        }.padding(.bottom, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            SpecLine("cores", value: "\(snapshot.profile.cpus)")
                            SpecLine("memory", value: "\(snapshot.profile.memoryMiB / 1024) GiB")
                            SpecLine("disk", value: snapshot.profile.homeDisk == nil ? snapshot.profile.diskSummary : (snapshot.profile.diskGiB.map { "\($0) GiB" } ?? "Factory capacity") + " system", note: snapshot.profile.homeDisk == nil ? nil : "The home disk is under home.")
                            SpecLine("used", value: ByteCountFormatter.string(fromByteCount: model.storageBytes[snapshot.id] ?? 0, countStyle: .file))
                            SpecLine("clipboard", value: snapshot.profile.clipboardEnabled ? "Enabled" : "Off", note: snapshot.profile.clipboardEnabled ? "Syncs with the Mac while this guest is focused." : "Clipboard sharing is off for this guest.", tint: snapshot.profile.clipboardEnabled ? Theme.green : nil)
                            SpecLine("touch id", value: GuestTouchIDRecord(snapshot).hostBridge.capitalized, note: "Pair through Setup → Security → Touch ID for sudo inside the guest. Guest pairing status is unknown to the manager.")
                        }.padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(Theme.strongBorder).frame(height: 1) }
                    }
                }.padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 14)
            }
            if firstRun == nil, run == nil {
                GuestSetupCardHost(model: model, snapshot: snapshot) { setupSheet = $0 }
            }
            if features.showsSuspendPanel(for: snapshot) {
                GuestHibernationPanel(snapshot: snapshot, review: { action in model.experimentalPowerReview = .init(id: snapshot.id, action: action) }, recheck: { Task { await model.recheckExperimentalRecovery(snapshot.id) } })
            }
            GuestHomePanel(snapshot: snapshot, canReplaceSystem: editable(snapshot) && !snapshot.profile.isRetainedPOC,
                           review: { model.homeBackupReview = snapshot },
                           cancel: { Task { await model.cancelHomeBackup(snapshot.id) } },
                           replaceSystem: { editor = EditorSelection(profile: nil, reuseSource: snapshot.profile) })
        }
    }

    private func paneNote(_ text: String) -> some View {
        Text(text).font(Theme.sans(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 2)
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
                Button("Copy SSH command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }.buttonStyle(.primaryAction).padding(.horizontal, 4)
            } else if snapshot.profile.ssh != nil {
                paneNote("Complete the guest’s normal owner-account setup. The manager then verifies key-based SSH independently of its desktop and clipboard. Guest host keys are provisioned once and checked on every connection.")
                if snapshot.sessionID != nil {
                    Button("Retry SSH check") { Task { await model.retrySSH(snapshot.id) } }.disabled(snapshot.state != .running).padding(.horizontal, 4)
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
                Text("Use the guest’s own Dock icon to choose its desktop.").font(Theme.sans(13)).foregroundStyle(.secondary).padding(.top, 4).padding(.bottom, 10)
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
                    Text("Each storage root has a stable guest app identity, independent of its display name. macOS manages the assignment. To release it, choose Assign To → None.").font(Theme.sans(13)).foregroundStyle(.secondary)
                    if snapshot.profile.isRetainedPOC { Text("Retained POC guests keep their original display settings. New guests start in windowed mode.").font(Theme.sans(13)).foregroundStyle(.secondary) }
                    Link("Apple’s guide to Mission Control Spaces", destination: URL(string: "https://support.apple.com/guide/mac-help/mh14112/mac")!)
                    Text("Assignment persistence across guest restarts needs verification on this Mac with the updated runtime.").font(Theme.note).foregroundStyle(.secondary)
                }.padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ScreenHeader("Permissions", subtitle: "Optional macOS permissions the manager can use. Each stays off until you enable it.", symbol: "hand.raised")
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
            ScreenHeader("Runtime", subtitle: "The pinned runtime and Try Omarchy kit this manager runs guests with.", symbol: "checkmark.shield")
            SpecPane("try omarchy kit", action: {
                Button("Check again") { Task { await model.refresh() } }.disabled(model.checking)
            }) {
                SpecRow("runtime", value: model.diagnostics == nil ? (model.diagnosticError ?? "Checking…") : "Pinned private runtime · Focus-aware clipboard")
                if let d = model.diagnostics {
                    SpecRow("protocol", value: "\(d.runProtocolVersion)")
                    SpecRow("preflight", value: d.preflightFailure ?? "Passed")
                    DisclosureGroup("Build provenance") { Text(d.patchCommit).font(Theme.mono(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }
                        .padding(.vertical, 8).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            SpecPane("known issue") {
                SpecRow("graphics", note: "A guest may occasionally open with a black or incomplete desktop. Investigation is ongoing.")
            }
        }
    }

    private func controls(_ snapshot: VMSnapshot) -> some View {
        GuestControls(snapshot: snapshot, launchEnabled: launchAvailable,
                      start: { focusGuest(snapshot.id); Task { await model.start(snapshot.id) } }, stop: { Task { await model.stop(snapshot.id) } },
                      forceStop: { model.forceStopID = snapshot.id },
                      pause: { Task { await model.pause(snapshot.id) } }, resume: { Task { await model.resume(snapshot.id) } },
                      suspendToDisk: { model.experimentalPowerReview = .init(id: snapshot.id, action: .suspend) },
                      restoreSuspension: { model.experimentalPowerReview = .init(id: snapshot.id, action: .restore) })
    }
    private var launchAvailable: Bool { !model.checking && model.diagnostics != nil && model.registryError == nil && !model.shuttingDown }
    /// The guest whose setup state is on screen: its Home page or a setup sheet.
    private var visibleGuest: UUID? {
        guard case .guest(let id) = destination, page == .home || page == .setup || setupSheet != nil else { return nil }
        return id
    }

    private func openRoute(_ route: AppModel.AttentionRoute) {
        guard model.snapshots.contains(where: { $0.id == route.vmID }) else { return }
        if destination == .guest(route.vmID) {
            page = .home; setupSheet = route.sheet
        } else {
            // Dismiss any open sheet before its guest page is replaced, then open the
            // other guest (whose page owns the sheet) on the next turn.
            setupSheet = nil
            let sheet = route.sheet, vmID = route.vmID
            Task { @MainActor in
                focusGuest(vmID)
                await Task.yield()
                page = .home; setupSheet = sheet
            }
        }
    }

    /// Changing guests resets the page through onChange(of: destination); a launch
    /// from the guest already shown keeps its page, so Setup is never yanked away.
    private func focusGuest(_ id: UUID) {
        destination = .guest(id)
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
                // Setup lives on Home (card and sheets); the page remains only for the acceptance harness.
                ForEach(GuestPage.allCases.filter { $0 != .setup }, id: \.self) { item in
                    let selected = item == page
                    Button { page = item } label: {
                        Text(item.rawValue).font(Theme.sans(13, weight: selected ? .medium : .regular)).foregroundStyle(selected ? Theme.text : Color.secondary)
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
private struct EditorSelection: Identifiable { let id = UUID(); let profile: VMProfile?; var reuseSource: VMProfile? = nil; var initialFactory: String? = nil }
struct VMEditor: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let profile: VMProfile?
    private var saved: (UUID, _ launch: Bool) -> Void
    /// Whether the manager can start a guest now; Create and Launch is disabled otherwise.
    private var launchAvailable = false
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
    @State private var buildingFactory = false
    @State private var useOwnerDefaults: Bool
    @State private var setupSource: ProvisioningSetupSource?
    @State private var creationAttempt: CreationAttempt?
    private struct CreationAttempt {
        let id: UUID
        let configuration: GuestConfigurationPatch
        let source: ProvisioningSetupSource?
    }
    @State private var setupBlocker: NewVMSetupBlocker?
    @State private var setupDraft = NewVMSetupDraft()
    @State private var layoutTitles: [ProvisioningLayoutExampleID: String] = [:]
    @State private var openPane: Pane?
    init(model: AppModel, profile: VMProfile?, reuseSource: VMProfile? = nil, initialFactory: String? = nil, launchAvailable: Bool, saved: @escaping (UUID, _ launch: Bool) -> Void) {
        self.init(model: model, profile: profile, reuseSource: reuseSource, initialFactory: initialFactory, saved: { _ in })
        self.saved = saved; self.launchAvailable = launchAvailable
    }
    init(model: AppModel, profile: VMProfile?, reuseSource: VMProfile? = nil, initialFactory: String? = nil, saved: @escaping (UUID) -> Void) {
        self.model = model; self.profile = profile; self.saved = { id, _ in saved(id) }
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
        _factory = State(initialValue: initialFactory ?? "official")
        var draft = NewVMSetupDraft(); draft.permanentSudoGrant = model.setupDefaults.permanentSudoGrant
        _setupDraft = State(initialValue: draft)
    }
    private var saveBlocker: String? {
        if saving { return profile == nil ? (setupSource == nil ? "Creating VM…" : "Preparing setup and creating VM…") : "Saving changes…" }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this VM." }
        return profile == nil ? setupBlocker?.message : nil
    }
    private var canSave: Bool { saveBlocker == nil }
    private var maximumMemory: Int { max(4, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) * 3 / 4) }
    private enum Pane: String { case layout, customise, resources, access }
    private func paneBinding(_ pane: Pane) -> Binding<Bool> {
        Binding(get: { openPane == pane }, set: { openPane = $0 ? pane : nil })
    }
    private var layoutSummary: String {
        let appearance = setupDraft.appearance
        switch appearance.layoutMode {
        case "example": return appearance.layoutExample.flatMap { layoutTitles[$0] } ?? "Layout example"
        case "file": return appearance.layoutFile?.lastPathComponent ?? "Custom file"
        case "remove": return "Omarchy default"
        default: return setupDraft.source == "local" ? "From your setup folder" : "Omarchy default"
        }
    }
    private var customiseSummary: String {
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
            Text(profile == nil ? "New virtual machine" : "Configure virtual machine").font(Theme.sans(20, weight: .semibold)).padding(.bottom, 10)
            SpecRow("name") {
                TextField("Name", text: $name, prompt: Text("Enter a name")).labelsHidden().specField().frame(width: 400)
            }
            if profile == nil {
                SpecRow("factory") {
                    Picker("Factory image", selection: $factory) {
                        ForEach(model.factories, id: \.selector) { image in Text(model.factoryLabel(image)).tag(image.selector) }
                    }.labelsHidden().frame(maxWidth: 420)
                    // Short labels keep the row on one line beside long factory names; the full action is in help and VoiceOver.
                    Button("Import…") { importingFactory = true }
                        .fixedSize().help("Import a factory image").accessibilityLabel("Import factory")
                        .disabled(saving || model.factoryImportInProgress || model.checking || model.diagnostics == nil)
                    Button("Build…") { buildingFactory = true }
                        .fixedSize().help("Build a lean factory image").accessibilityLabel("Build lean factory")
                        .disabled(saving || !model.factoryBuilder.service.enabled || model.registryError != nil)
                        .accessibilityIdentifier("newvm.buildFactory")
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
                    if selectedPublicKey != nil { Button("Remove selected key") { selectedPublicKey = nil } }
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
                DisclosurePaneRow(key: "layout", summary: layoutSummary, isOpen: paneBinding(.layout)) {
                    NewVMLayoutSelectionView(model: model, draft: $setupDraft).disabled(saving)
                }
                DisclosurePaneRow(key: "customise", summary: customiseSummary, isOpen: paneBinding(.customise)) {
                    NewVMSetupSelectionView(model: model, factory: $factory, draft: $setupDraft, selection: $setupSource, blocker: $setupBlocker).disabled(saving)
                }
            }
            DisclosurePaneRow(key: "resources", summary: resourcesSummary, isOpen: paneBinding(.resources)) { resourceRows.disabled(saving) }
            DisclosurePaneRow(key: "access", summary: accessSummary, isOpen: paneBinding(.access)) { accessRows.disabled(saving) }
            VStack(alignment: .leading, spacing: 10) {
            if let error = keyError { Text(error).foregroundStyle(.red).font(Theme.sans(13)) }
            if let error = model.configurationError { Text(error).foregroundStyle(.red).font(Theme.sans(13)).fixedSize(horizontal: false, vertical: true) }
            Text(profile == nil ? "The selected factory prepares on first launch. Each guest has independent storage. Networking uses NAT. Host-folder sharing and guest Touch ID are opt-in. USB and camera are off." : "Changes apply the next time this guest starts. Its existing disk is preserved.").font(Theme.sans(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let saveBlocker {
                Label(saveBlocker, systemImage: saving ? "hourglass" : "info.circle")
                    .font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("new-vm.validation")
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if profile == nil {
                    // Plain Create stays available; launching is a separate, explicit choice.
                    if launchAvailable {
                        Button("Create") { save() }.accessibilityIdentifier("new-vm.create").disabled(!canSave)
                        Button(setupSource != nil && sshEnabled ? "Create, launch & set up" : "Create and launch") { save(launch: true) }
                            .accessibilityIdentifier("new-vm.create-launch").buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canSave)
                    } else {
                        Button("Create and launch") {}.disabled(true).help("Launching is unavailable right now. Create the VM, then launch it from its page.")
                            .accessibilityIdentifier("new-vm.create-launch")
                        Button("Create VM") { save() }.accessibilityIdentifier("new-vm.create").buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canSave)
                    }
                } else {
                    Button("Save changes") { save() }.accessibilityIdentifier("new-vm.create").buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canSave)
                }
            }
            }.padding(.horizontal, 20).padding(.vertical, 12).overlay(alignment: .top) { Rectangle().fill(Theme.strongBorder).frame(height: 1) }
        }.frame(width: 620).font(Theme.body).background(Theme.pane).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle()).interactiveDismissDisabled(saving)
        .onChange(of: setupBlocker) { _, value in if let value { openPane = value.isLayout ? .layout : .customise } }
        .task(id: profile == nil) {
            guard profile == nil, let examples = try? BundledProvisioning.layoutExamples() else { return }
            layoutTitles = Dictionary(uniqueKeysWithValues: examples.map { ($0.id, $0.title) })
        }
        .onChange(of: useOwnerDefaults) { _, value in
            if value { selectedPublicKey = model.ownerDefaults?.sshPublicKey }
            else if selectedPublicKey == model.ownerDefaults?.sshPublicKey { selectedPublicKey = nil }
        }.onAppear { model.configurationError = nil }.task { await model.loadFactories() }
        .sheet(isPresented: $importingFactory) {
            FactoryImportView(model: model) { identity in factory = identity.selector }
        }
        .sheet(isPresented: $buildingFactory) {
            VStack(alignment: .trailing) {
                Button("Done") { buildingFactory = false }.padding([.top, .trailing], 16)
                ScrollView { FactoryImagesView(model: model) { identity in
                    model.builtFactoryAvailable(identity); factory = identity.selector; buildingFactory = false
                }.padding(24) }
            }.frame(width: 900, height: 730)
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
                }, snapshot: { ["name": name, "memory": String(memory), "cpus": String(cpus), "disk": String(disk), "factory": factory, "ready": String(setupBlocker == nil), "ownerDefaults": String(useOwnerDefaults), "hasSetup": String(setupSource != nil), "failure": model.configurationError ?? "", "saving": String(saving), "canSave": String(canSave), "validation": saveBlocker ?? "", "panes": profile == nil ? "layout,customise,resources,access" : "resources,access", "openPane": openPane?.rawValue ?? ""] })
            } }
            #endif
        }
    }
    private func save(launch: Bool = false) {
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
            if let id = await model.save(profile, name: name, memoryGiB: memory, cpus: cpus, diskGiB: disk, clipboard: clipboard, guestTouchID: guestTouchID, immersive: immersive, sshEnabled: sshEnabled, publicKey: publicKey, useOwnerDefaults: useOwnerDefaults, factory: factory, share: share, sharePath: sharePath, separateHome: separateHome, homeDiskGiB: homeDisk, reuseHomeFrom: reuseHomeFrom, setupSource: setupSource, setupRequestID: requestID) { saved(id, launch && profile == nil) }
            saving = false
        }
    }

    private func choosePublicKey() {
        do { if let key = try PublicKeyPicker.choose() { selectedPublicKey = key; keyError = nil } }
        catch { keyError = error.localizedDescription }
    }

}

struct ManagerLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 20) {
            // The library's frame mark with its tracer stands in for a spinner; Reduce Motion falls back to the system one.
            FrameMark(size: 120, tracer: reduceMotion ? nil : Theme.green, loading: true)
            VStack(spacing: 6) {
                Text(AppChannel.current.displayName).font(Theme.sans(22, weight: .semibold))
                Text("loading guests…").font(Theme.mono(13)).foregroundStyle(Theme.label)
            }
            if reduceMotion { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your virtual machines")
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
        .navigationTitle(AppChannel.current.displayName)
    }
}

private struct ManagerArtwork: View {
    let size: CGFloat
    var body: some View {
        if let image = AppArtwork.image("OmarchyVMManager") {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack.3d.up").resizable().scaledToFit().frame(width: size, height: size).foregroundStyle(.green).accessibilityHidden(true)
        }
    }
}
