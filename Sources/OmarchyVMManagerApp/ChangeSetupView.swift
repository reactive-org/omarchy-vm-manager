import OmarchyVMManagerCore
import SwiftUI

/// Change setup, laid out like New VM: what the last run did, the guest's choices in
/// `layout` and `customise`, the consents the next run needs, and one button that
/// says what happens. One approval covers the whole run: apply, restart and check
/// (user direction, 9 November 2026). A run prepared but not yet approved is shown
/// again whenever the sheet opens, with Approve & run and Discard, so closing the
/// sheet can never strand it.
struct ChangeSetupView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    let snapshot: VMSnapshot
    let close: () -> Void
    let openOutput: () -> Void

    typealias Phase = SetupRunPhase
    private enum Pane { case layout, customise }
    @State private var openPane: Pane?
    @State private var loaded = false
    @State private var latest: ProvisioningLatestSetup?
    /// The plan the guest's last run used, for summaries and the starting draft.
    @State private var lastPlan: ProvisioningPlanPreview?
    @State private var baseline: NewVMSetupDraft?
    /// The draft was set up once; later reloads never overwrite the person's edits.
    @State private var draftLoaded = false
    /// The last run's plan can't be shown (for example after a setup engine update), so
    /// the draft starts from defaults while Run setup again still repeats its exact choices.
    @State private var choicesUnknown = false
    @State private var draft = NewVMSetupDraft()
    @State private var selection: ProvisioningSetupSource?
    @State private var blocker: NewVMSetupBlocker?
    @State private var factory = "custom"
    /// A plan waiting for approval: a pending run, or a new plan that needs consent
    /// beyond temporary admin access before it can run.
    @State private var pendingPlan: ProvisioningPlanPreview?
    @State private var pendingReview: ProvisioningApplyReview?
    /// The pending run whose review was asked for, so overlapping loads ask once.
    @State private var reviewRequested: UUID?
    @State private var grantConsent = false
    @State private var dockerConsent = false
    @State private var taskConsent = false
    @State private var inspectedTasks = Set<String>()
    @State private var taskText: String?
    @State private var showingTask = false
    @State private var working = false
    @State private var failure: String?
    @State private var confirmCancel = false
    @State private var confirmRelease: ProvisioningWorkflowSnapshot?
    @State private var releaseShown = false
    /// The last run can finish with Run the check only.
    @State private var checkOnlyOffered = false

    private var service: (any ProvisioningRetrying)? { model.setupService as? any ProvisioningRetrying }
    private var executionEnabled: Bool { service?.executionEnabled == true }
    private var rows: [ProvisioningWorkflowSnapshot] { model.setupWorkflows.filter { $0.vmID == snapshot.id } }
    private var auto: AutoSetupState? { model.autoSetup[snapshot.id] }
    private var running: Bool { snapshot.sessionID != nil }
    private var approvedID: UUID? { auto?.isActive == true ? auto?.plan?.previewID : nil }

    var phase: Phase {
        guard loaded else { return .loading }
        if let active = SetupRunPhase.active(rows, auto: auto, checkOnly: model.checkOnlyRuns) { return active }
        let preparing: [ProvisioningWorkflowStage] = [.waitingForSSH, .readyForReview]
        if let pending = rows.first(where: { preparing.contains($0.stage) && !model.checkOnlyRuns.contains($0.id) }) { return .pending(pending) }
        if pendingPlan != nil { return .pending(nil) }
        return .edit
    }
    private var lastRun: ProvisioningWorkflowSnapshot? { latest?.workflow }
    private var changed: Bool { baseline.map { $0 != draft } ?? true }
    private var neverSetUp: Bool { latest == nil && snapshot.profile.developerSetup == nil }
    private var primaryTitle: String {
        if !running { return "Start & set up" }
        if neverSetUp || lastRun == nil { return "Run setup" }
        return changed ? "Apply changes" : "Run setup again"
    }
    private var needsDocker: Bool {
        if let pendingPlan { return SetupProposalFacts.needsDocker(pendingPlan.proposal) }
        return !changed && lastPlan.map { SetupProposalFacts.needsDocker($0.proposal) } == true
    }
    private var canRun: Bool {
        guard executionEnabled, snapshot.profile.ssh != nil, !working, grantConsent, !needsDocker || dockerConsent else { return false }
        if changed || lastRun == nil && lastPlan == nil { return selection != nil }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            status
            content
            footer
        }
        .frame(width: 640).font(Theme.body).background(Theme.pane).buttonStyle(.quietAction).toggleStyle(SpecSwitchToggleStyle())
        .task(id: loadKey) { await load() }
        .onChange(of: draft) { _, _ in failure = nil }
        .sheet(isPresented: taskPresentation) {
            VStack(alignment: .leading) {
                Text("Frozen task source").font(Theme.sans(20, weight: .semibold))
                ScrollView([.horizontal, .vertical]) { Text(taskText ?? "Source unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12) }
                Button("Done") { showingTask = false }
            }.padding(20).frame(width: 760, height: 560)
        }
        .confirmationDialog("Cancel setup and perform its cleanup?", isPresented: cancelPresentation) {
            Button("Cancel setup", role: .destructive) { cancelLive() }
        } message: { Text("Cleanup removes temporary admin access. It may still need verification.") }
        .modifier(ReleaseConfirmation(isPresented: releasePresentation) {
            if let held = confirmRelease { confirmRelease = nil; Task { await workflowAction(held, .release) } }
        })
        .background { acceptanceBinding }
    }

    // MARK: Header and status

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(neverSetUp ? "Set up " + snapshot.profile.name : "Change setup").font(Theme.sans(20, weight: .semibold))
                Text(snapshot.profile.name + " · " + (running ? "running" : "stopped") + " · setup runs in the guest and restarts it once to finish")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    typealias Status = SetupRunStatus
    typealias Tint = SetupRunStatus.Tint

    var currentStatus: Status {
        SetupRunStatus.make(phase, lastRun: lastRun, latestPlanExists: latest != nil || snapshot.profile.developerSetup != nil, running: running,
                            job: (phaseRow ?? (phase == .edit ? lastRun : nil)).flatMap { model.setupJobs[$0.id] }, auto: auto, checkOnly: model.checkOnlyRuns)
    }
    private var phaseRow: ProvisioningWorkflowSnapshot? {
        switch phase { case .live(let row), .cleanup(let row): row; case .pending(let row): row; default: nil }
    }
    static func status(_ phase: Phase, lastRun: ProvisioningWorkflowSnapshot?, latestPlanExists: Bool, running: Bool,
                       job: ProvisioningJobSnapshot?, auto: AutoSetupState?) -> Status {
        SetupRunStatus.make(phase, lastRun: lastRun, latestPlanExists: latestPlanExists, running: running, job: job, auto: auto)
    }

    private var status: some View {
        let value = currentStatus
        let tint: Color = switch value.tint { case .good: Theme.green; case .working: Theme.lavender; case .attention: Theme.amber; case .quiet: Theme.label }
        return VStack(alignment: .leading, spacing: 12) {
            SetupStepStrip(states: value.steps)
            VStack(alignment: .leading, spacing: 4) {
                Text(value.label).font(Theme.mono(13, weight: .medium)).foregroundStyle(tint)
                Text(value.title).font(Theme.sans(15, weight: .semibold)).accessibilityIdentifier("setup.run-status")
                if !value.note.isEmpty { Text(value.note).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .edit:
            DisclosurePaneRow(key: "layout", summary: layoutSummary, isOpen: paneBinding(.layout)) {
                NewVMLayoutSelectionView(model: model, draft: $draft).disabled(working)
            }
            DisclosurePaneRow(key: "customise", summary: customiseSummary, isOpen: paneBinding(.customise)) {
                NewVMSetupSelectionView(model: model, factory: $factory, draft: $draft, selection: $selection, blocker: $blocker,
                                        approvalNote: "Setup updates Omarchy and system packages, then applies these selections and installs the apps your layout needs.").disabled(working)
            }
            infoRow("admin", ProvisioningSudoGrant.reviewStep(timed: !draft.permanentSudoGrant))
            changesLine
        case .pending:
            if let plan = pendingPlan {
                infoRow("software", SetupProposalFacts.software(plan.proposal))
                infoRow("desktop", SetupProposalFacts.desktop(plan.proposal))
                infoRow("admin", ProvisioningSudoGrant.reviewStep(timed: ProvisioningSudoGrant.isTimed(in: plan.proposal)))
                ForEach(plan.tasks, id: \.name) { task in
                    HStack {
                        Text(task.name).font(Theme.sans(13, weight: .medium))
                        Spacer()
                        Button(inspectedTasks.contains(task.name) ? "Inspect again…" : "Inspect task…") { Task { await inspect(plan, task) } }.disabled(working)
                    }.padding(.leading, 42).padding(.trailing, 20).padding(.vertical, 8).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            } else {
                infoRow("plan", "Loading the prepared plan…")
            }
        case .loading, .starting, .live, .cleanup:
            if let plan = lastPlan, phase != .loading {
                infoRow("software", SetupProposalFacts.software(plan.proposal))
                infoRow("desktop", SetupProposalFacts.desktop(plan.proposal))
            }
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Theme.mono(14)).foregroundStyle(Theme.lavender).frame(width: 88, alignment: .leading)
            Text(value).font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 42).padding(.trailing, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var changesLine: some View {
        if let baseline, changed {
            let added = draft.profiles.subtracting(baseline.profiles).map(Self.profileName).sorted()
            let removed = baseline.profiles.subtracting(draft.profiles).map(Self.profileName).sorted()
            VStack(alignment: .leading, spacing: 4) {
                if !added.isEmpty { Text("Adds " + added.joined(separator: ", ") + ".").foregroundStyle(Theme.green) }
                if !removed.isEmpty { Text("Removes " + removed.joined(separator: ", ") + " from the plan; installed packages stay.").foregroundStyle(Theme.amber) }
                Text(draft.source == "local" && draft.folder == nil ? "These choices came from a local setup folder. Choose it again in customise to apply changes." : "A new plan from these choices, built with the current setup engine.")
                    .foregroundStyle(.secondary)
            }
            .font(Theme.sans(13)).padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        } else if choicesUnknown {
            Text("The last run’s choices can’t be shown with this version of the setup engine. Run setup again repeats them; changing them starts from the defaults.")
                .font(Theme.sans(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 10).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    static func profileName(_ id: String) -> String {
        switch id { case "developer": "Developer"; case "web": "Web"; case "python": "Python"; case "project-managed": "Project managed"; default: id }
    }
    private var layoutSummary: String {
        if choicesUnknown, !changed { return "Same as the last run" }
        return switch draft.appearance.layoutMode {
        case "example": (try? BundledProvisioning.layoutExamples())?.first { $0.id == draft.appearance.layoutExample }?.title ?? "Example layout"
        case "file": "Custom layout"
        case "remove": "Omarchy default"
        default: lastPlan.map { ProvisioningAppearanceSummary(proposal: $0.proposal).layoutIncluded ? "Layout from the setup folder" : "Omarchy default" } ?? "Omarchy default"
        }
    }
    private var customiseSummary: String {
        if choicesUnknown, !changed { return "Same as the last run" }
        guard draft.source != "none" else { return "No developer setup" }
        let names = draft.profiles.map(Self.profileName).sorted()
        let theme = draft.appearance.themeChoice == .source ? nil : draft.appearance.themeChoice == .repository ? "GitHub theme" : draft.appearance.themeChoice.rawValue + " theme"
        return ([names.isEmpty ? "From the setup folder" : names.joined(separator: ", ")] + [theme].compactMap { $0 }).joined(separator: " · ")
    }
    private func paneBinding(_ pane: Pane) -> Binding<Bool> {
        Binding(get: { openPane == pane }, set: { openPane = $0 ? pane : nil })
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .edit = phase { consents(plan: nil) }
            if case .pending = phase { consents(plan: pendingPlan) }
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(Theme.sans(13)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
            if let note = footNote { Text(note).font(Theme.sans(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                secondaryActions
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                primaryActions
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.strongBorder).frame(height: 1) }
    }

    private var footNote: String? {
        switch phase {
        case .edit:
            if !executionEnabled { return "Setup execution is disabled in this build. Nothing here changes this VM." }
            if snapshot.profile.ssh == nil { return "Setup runs over the guest’s managed SSH, which is off for this guest. Turn on SSH in its settings while it’s stopped, then run setup." }
            let check = checkOnlyOffered && running && !changed ? " Run the check only finishes the last run with its configuration check alone: read-only, with no admin access." : ""
            return (running ? "" : "Starts the guest, then runs this plan once it’s reachable. ") + "Approving covers the whole run: setup updates Omarchy, applies these choices, restarts the guest once and checks the configuration." + check
        case .pending: return "Approving covers the whole run, including its restart and check. Discard cancels the prepared run; nothing in the guest changes."
        case .cleanup: return "Changing setup is unavailable until the hold is resolved."
        default: return nil
        }
    }

    @ViewBuilder private func consents(plan: ProvisioningPlanPreview?) -> some View {
        consent("Allow temporary admin access while setup runs", note: "Passwordless sudo in this guest until setup’s cleanup removes it. If cleanup can’t be confirmed, the run is held for review.", isOn: $grantConsent)
        if needsDocker {
            consent("Allow Docker without sudo", note: "The guest owner gets root-equivalent access inside this VM. It stays after setup.", isOn: $dockerConsent, warning: true)
        }
        if let plan, !plan.tasks.isEmpty {
            let inspected = plan.tasks.allSatisfy { inspectedTasks.contains($0.name) }
            consent("Allow custom tasks from this configuration", note: inspected
                    ? "Custom Ansible tasks can run on this Mac and in the VM, using credentials available to Ansible. Covers the reviewed configuration, task files and assets."
                    : "Inspect each custom task above before allowing it.", isOn: $taskConsent, warning: true)
                .disabled(!inspected)
        }
    }

    private func consent(_ title: String, note: String, isOn: Binding<Bool>, warning: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.sans(13, weight: .medium)).foregroundStyle(warning ? Theme.amber : Theme.text)
                Text(note).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox).disabled(working)
    }

    @ViewBuilder private var secondaryActions: some View {
        switch phase {
        case .pending: Button("Discard this run") { Task { await discard() } }.foregroundStyle(Theme.amber).disabled(working)
        case .live(let row):
            Button("View output", action: openOutput)
            if row.canCancel { Button("Cancel setup…") { confirmCancel = true }.foregroundStyle(Theme.amber) }
        case .starting: Button("Don’t set up") { model.autoSetup[snapshot.id] = nil }.foregroundStyle(Theme.amber)
        case .cleanup, .edit:
            if lastRun != nil { Button("View output", action: openOutput) }
        case .loading: EmptyView()
        }
    }

    @ViewBuilder private var primaryActions: some View {
        switch phase {
        case .edit:
            if checkOnlyOffered, running, let run = lastRun, !changed {
                Button("Run the check only") { Task { await runCheckOnly(run) } }.disabled(working || !executionEnabled).accessibilityIdentifier("setup.check-only")
            }
            Button(primaryTitle) { Task { await runSetup() } }
                .buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canRun).accessibilityIdentifier("setup.run")
        case .pending:
            Button("Approve & run") { Task { await approvePending() } }
                .buttonStyle(.primaryAction).keyboardShortcut(.defaultAction).disabled(!canApprovePending).accessibilityIdentifier("setup.apply")
        case .live(let row):
            let actions = row.availableActions
            if currentStatus.tint == .attention, actions.contains(.restart) || actions.contains(.check) {
                Button(actions.contains(.restart) ? "Restart & check" : "Run the check") { Task { await finish(row) } }
                    .buttonStyle(.primaryAction).disabled(working || !executionEnabled)
            }
        case .cleanup(let row):
            ForEach(DeveloperSetupView.visibleActions(row, guestRunning: running), id: \.self) { action in
                Button(action == .release ? "Release hold…" : action.title + "…") {
                    if action == .release { confirmRelease = row; releaseShown = true } else { Task { await workflowAction(row, action) } }
                }.buttonStyle(.primaryAction).disabled(working || !executionEnabled)
            }
        case .loading, .starting: EmptyView()
        }
    }

    private var canApprovePending: Bool {
        guard executionEnabled, !working, grantConsent, pendingPlan != nil, !needsDocker || dockerConsent else { return false }
        if let plan = pendingPlan, !plan.tasks.isEmpty {
            return taskConsent && plan.tasks.allSatisfy { inspectedTasks.contains($0.name) } && running
        }
        return true
    }

    // MARK: Loading

    private var loadKey: String {
        snapshot.id.uuidString + String(model.setupService != nil) + rows.map { $0.id.uuidString + $0.stage.rawValue }.sorted().joined()
    }

    @MainActor private func load() async {
        factory = snapshot.profile.factory == .official ? "official" : "custom"
        guard let service else { loaded = true; return }
        let value = await service.latestSetup(vmID: snapshot.id)
        latest = value
        if !draftLoaded {
            draftLoaded = true
            if let value, let plan = try? await service.preview(value.planID), plan.vmID == snapshot.id {
                lastPlan = plan
                let start = SetupProposalFacts.draft(plan)
                baseline = start; draft = start
            } else if value == nil {
                draft = NewVMSetupDraft(source: "bundled", profiles: ["developer"], permanentSudoGrant: model.setupDefaults.permanentSudoGrant,
                                        appearance: ProvisioningAppearanceDraft(model.desktopDefaults))
            } else {
                let start = NewVMSetupDraft(source: "bundled", profiles: ["developer"], permanentSudoGrant: model.setupDefaults.permanentSudoGrant)
                baseline = start; draft = start; choicesUnknown = true
            }
        }
        // A pending run: show its plan and fetch the review it was prepared with.
        if let pending = value?.pending, approvedID != pending.id, !model.checkOnlyRuns.contains(pending.id) {
            if pendingPlan?.id != pending.id { pendingPlan = try? await service.preview(pending.id); pendingReview = nil; resetConsents() }
            if pending.stage == .readyForReview, pendingReview == nil, reviewRequested != pending.id {
                reviewRequested = pending.id
                do { pendingReview = try await service.prepareApply(pending.id) }
                catch { reviewRequested = nil; failure = "This run’s approval isn’t available any more. Discard it, then run setup again." }
            }
        } else if let plan = pendingPlan, rows.contains(where: { $0.id == plan.id }), value?.pending?.id != plan.id {
            // The pending run has started or ended; it is no longer waiting here.
            pendingPlan = nil; pendingReview = nil
        }
        if let run = value?.workflow, let checking = service as? any ProvisioningCheckRunning {
            checkOnlyOffered = await checking.checkOnlyAvailable(run.id)
        } else { checkOnlyOffered = false }
        loaded = true
    }

    private func resetConsents() { grantConsent = false; dockerConsent = false; taskConsent = false; inspectedTasks.removeAll(); reviewRequested = nil }

    // MARK: Actions

    /// The main button: make the plan (the same choices again, or new ones), then
    /// approve it once for its whole run. Anything needing separate consent stops
    /// at Approve & run instead.
    @MainActor private func runSetup() async {
        guard let service, canRun else { return }
        working = true; failure = nil; defer { working = false }
        let plan: ProvisioningPlanPreview
        do {
            if !changed, let previous = lastRun, previous.runFinished || previous.endedBeforeRunning {
                plan = try await service.prepareRetry(id: UUID(), of: previous.id).preview
            } else if !changed, lastRun == nil, let lastPlan {
                plan = lastPlan // A creation plan that never ran.
            } else {
                guard let selection else { failure = blocker?.message ?? "Choose what to set up in customise."; return }
                plan = try await service.preview(id: UUID(), vmID: snapshot.id, source: selection)
            }
        } catch ProvisioningReviewFailure.conflictingProfiles {
            failure = "These profiles have conflicting settings. Choose a compatible combination."; return
        } catch ProvisioningServiceFailure.busy {
            failure = "Another setup run or a cleanup hold is in progress. Finish it first."; return
        } catch {
            failure = ProvisioningAppearance.failureMessage(error) ?? "Setup couldn’t make a plan from these choices. Nothing was changed."; return
        }
        guard plan.vmID == snapshot.id else { failure = "The plan doesn’t belong to this guest. Nothing was changed."; return }
        let docker = SetupProposalFacts.needsDocker(plan.proposal)
        if !plan.tasks.isEmpty || docker && !dockerConsent {
            // Separate consent first; nothing was prepared in the guest.
            let admin = grantConsent
            pendingPlan = plan; pendingReview = nil; resetConsents(); grantConsent = admin
            return
        }
        guard model.approveSetup(.init(preview: plan, dockerAcknowledged: docker && dockerConsent)) else {
            failure = "Setup couldn’t be approved for this guest right now. Nothing was changed."; return
        }
        if !running { await model.start(snapshot.id) }
        close() // Follow the run on Home, as New VM does.
    }

    /// A read-only check of the last run's exact plan, with no admin access and no
    /// custom tasks. The click is the owner's consent, like the reviewed restart.
    @MainActor private func runCheckOnly(_ run: ProvisioningWorkflowSnapshot) async {
        guard let service = service as? any ProvisioningCheckRunning, executionEnabled, running else { return }
        working = true; failure = nil; defer { working = false }
        let id = UUID()
        model.checkOnlyRuns.insert(id)
        do { _ = try await service.runCheckOnly(id: id, of: run.id); close() }
        catch ProvisioningReviewFailure.changed {
            model.checkOnlyRuns.remove(id); failure = "The setup engine has changed since that run, so its plan can’t be checked on its own. Run setup again instead."
        } catch {
            model.checkOnlyRuns.remove(id); failure = "The check couldn’t start. Check the guest’s current state; nothing was changed or retried."
        }
    }

    @MainActor private func approvePending() async {
        guard let service, let plan = pendingPlan, canApprovePending else { return }
        working = true; failure = nil; defer { working = false }
        let docker = SetupProposalFacts.needsDocker(plan.proposal)
        if plan.tasks.isEmpty, pendingReview == nil, !rows.contains(where: { $0.id == plan.id }) {
            // Not prepared in the guest yet: the approval prepares and runs it.
            guard model.approveSetup(.init(preview: plan, dockerAcknowledged: docker && dockerConsent)) else {
                failure = "Setup couldn’t be approved for this guest right now. Nothing was changed."; return
            }
            pendingPlan = nil
            if !running { await model.start(snapshot.id) }
            close()
            return
        }
        do {
            let review: ProvisioningApplyReview
            if let pendingReview { review = pendingReview } else { review = try await service.prepareApply(plan.id) }
            guard review.previewID == plan.id, review.vmID == snapshot.id else { failure = "The prepared run doesn’t match this plan. Nothing was changed."; return }
            let consent = ProvisioningApplyConsent(reviewIdentity: review.reviewIdentity, taskTrustIdentity: taskConsent ? review.taskTrustIdentity : nil,
                                                   persistentGrantAcknowledged: grantConsent, dockerRootAccessAcknowledged: review.dockerRootAccessRequired && dockerConsent)
            let run = try await service.apply(plan.id, consent: consent)
            model.followApprovedSetup(.init(preview: plan, dockerAcknowledged: review.dockerRootAccessRequired && dockerConsent), workflowID: run.id)
            pendingPlan = nil; pendingReview = nil
            close()
        } catch {
            failure = SetupRunPresentation.submissionFailure(error)
        }
    }

    @MainActor private func discard() async {
        working = true; failure = nil; defer { working = false }
        if case .pending(let row?) = phase, row.canCancel { await model.cancelSetup(row.id) }
        if case .following(_, let id, _)? = auto, id == pendingPlan?.id { model.autoSetup[snapshot.id] = nil }
        pendingPlan = nil; pendingReview = nil; resetConsents()
    }

    private func cancelLive() {
        guard case .live(let row) = phase, row.canCancel else { return }
        if auto?.plan?.previewID == row.id { model.autoSetup[snapshot.id] = .consumed }
        Task { await model.cancelSetup(row.id) }
    }

    @MainActor private func finish(_ row: ProvisioningWorkflowSnapshot) async {
        working = true; failure = nil; defer { working = false }
        failure = await model.finishSetup(row)
    }

    @MainActor private func workflowAction(_ row: ProvisioningWorkflowSnapshot, _ action: ProvisioningWorkflowAction) async {
        guard let service = model.setupService as? any ProvisioningWorkflowActing else { return }
        working = true; failure = nil; defer { working = false }
        do {
            let review = try await service.prepareAction(row.id, action: action, reviewID: UUID())
            guard review.workflowID == row.id, review.action == action else { return }
            _ = try await service.performAction(row.id, consent: .init(reviewID: review.id, action: action, reviewIdentity: review.reviewIdentity, acknowledged: true))
        } catch { failure = action.title + " isn’t possible right now. Check the guest’s current state; nothing was changed." }
    }

    @MainActor private func inspect(_ plan: ProvisioningPlanPreview, _ task: ProvisioningTaskReview) async {
        guard let service else { return }
        working = true; defer { working = false }
        do {
            var data = Data()
            while true {
                let chunk = try await service.taskSource(plan.id, name: task.name, offset: data.count)
                guard chunk.sha256 == task.sha256, chunk.total <= 64 * 1024, chunk.offset == data.count else { throw ProvisioningReviewFailure.invalid }
                data += chunk.bytes
                if data.count == chunk.total { break }
            }
            guard pendingPlan?.id == plan.id, let text = String(data: data, encoding: .utf8) else { throw ProvisioningReviewFailure.changed }
            taskText = text; showingTask = true; inspectedTasks.insert(task.name)
        } catch { failure = "The complete frozen task could not be displayed. Native review is limited to 64 KiB per task; larger files need explicit CLI inspection." }
    }

    // MARK: Presentation guards for the offscreen harness

    private var taskPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $showingTask
    }
    private var cancelPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $confirmCancel
    }
    private var releasePresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $releaseShown
    }

    @ViewBuilder private var acceptanceBinding: some View {
        #if DEBUG
        if let acceptance {
            Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("change", action: { command in
                    switch command {
                    case .profiles(let value): draft.profiles = Set(value)
                    case .source(let value): draft.source = value
                    case .grant(let sudo, let docker, let tasks): grantConsent = sudo; dockerConsent = docker; taskConsent = tasks
                    case .inspect: if let plan = pendingPlan, let task = plan.tasks.first { Task { await inspect(plan, task) } }
                    case .runAgain: Task { await runSetup() }
                    case .checkOnly: if let run = lastRun { Task { await runCheckOnly(run) } }
                    case .submit: Task { await approvePending() }
                    case .discard: Task { await discard() }
                    case .requestCancel: if case .live(let row) = phase, row.canCancel { confirmCancel = true }
                    case .confirmCancel: if confirmCancel { confirmCancel = false; cancelLive() }
                    case .reload: Task { await load() }
                    default: break
                    }
                }, snapshot: { acceptanceState })
            }
        }
        #endif
    }

    #if DEBUG
    private var acceptanceState: [String: String] {
        let status = currentStatus
        let phaseName: String = switch phase {
        case .loading: "loading"; case .edit: "edit"; case .starting: "starting"; case .pending: "pending"; case .live: "live"; case .cleanup: "cleanup"
        }
        return ["phase": phaseName, "title": status.title, "note": status.note, "label": status.label,
                "steps": status.steps.map { "\($0)" }.joined(separator: ","), "primary": primaryTitle, "canRun": String(canRun),
                "canApprove": String(canApprovePending), "changed": String(changed), "docker": String(needsDocker),
                "pending": pendingPlan?.id.uuidString ?? "", "review": pendingReview?.reviewIdentity ?? "", "failure": failure ?? "",
                "inspected": String(inspectedTasks.count), "cancelPending": String(confirmCancel), "lastRun": lastRun?.id.uuidString ?? "",
                "profiles": draft.profiles.sorted().joined(separator: ","), "footNote": footNote ?? "", "checkOnly": String(checkOnlyOffered && running && !changed)]
    }
    #endif
}
