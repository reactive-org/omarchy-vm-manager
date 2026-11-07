import DevVMProvisioningCore
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

struct FactoryImagesView: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var model: AppModel
    @ObservedObject private var builder: FactoryBuildModel
    let use: (FactoryIdentity) -> Void
    @State private var importing = false
    @State private var showJob = true
    init(model: AppModel, use: @escaping (FactoryIdentity) -> Void) { self.model = model; builder = model.factoryBuilder; self.use = use }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ScreenHeader("Factory images", subtitle: "Reusable starting images for new virtual machines.", symbol: "square.3.layers.3d") {
                HStack(spacing: 8) {
                    Button("Import factory…", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.factoryImportInProgress)
                    Button("Build factory…", systemImage: "hammer") { builder.showingBuild = true }
                        .disabled(!builder.service.enabled || builder.jobs.contains { $0.active || $0.cleanupRequired } || model.registryError != nil)
                        .accessibilityIdentifier("factory.build")
                }
            }
            if let error = builder.error { Text(error).foregroundStyle(.orange).font(.callout).accessibilityIdentifier("factory.error") }
            if let job = builder.current, showJob {
                jobView(job)
            } else {
                if let job = builder.current, job.active || job.cleanupRequired {
                    HStack { Label(FactoryBuildModel.title(job), systemImage: "hammer"); Spacer(); Button("View build") { showJob = true } }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    factoryCard(title: "Try Omarchy", subtitle: "Official factory", icon: "opticaldisc", description: "Omarchy’s standard desktop and application collection, ready to make your own.", status: "Downloads when a VM first starts", action: "Use for new VM", source: model.officialFactorySource) { use(.official) }
                    factoryCard(title: "Lean Omarchy", subtitle: "Reviewed lean foundation", icon: "square.3.layers.3d", description: "The essential Omarchy desktop, native Mac integration, Git, Python and build tools. Choose additional apps per VM.", status: "Build once, reuse for new VMs", action: "Build lean factory…", disabled: !builder.service.enabled || builder.jobs.contains { $0.active || $0.cleanupRequired }) { builder.showingBuild = true }
                    ForEach(model.factories.filter { $0.kind == .custom }, id: \.selector) { factory in
                        factoryCard(title: factory.name, subtitle: "Custom factory", icon: "externaldrive", description: "Verified for this runtime and available for new virtual machines.", status: "Built or imported · Boot validation is separate", action: "Use for new VM") { use(factory) }
                    }
                }
                Text("Each VM has its own disk and account. Building a factory does not change existing VMs.").font(.callout).foregroundStyle(.secondary)
                if !builder.service.enabled { Text("Factory building is available in Dev.").font(.callout).foregroundStyle(.secondary) }
                if !builder.jobs.isEmpty {
                    DisclosureGroup("Build history") {
                        ForEach(builder.jobs) { job in
                            HStack { VStack(alignment: .leading) { Text(job.plan.name); Text(FactoryBuildModel.title(job)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("View") { builder.selectedID = job.id; showJob = true } }.padding(.vertical, 7)
                        }
                    }
                }
            }
        }
        .task { await builder.observe() }
        .onChange(of: builder.current?.id) { _, _ in showJob = true }
        .sheet(isPresented: buildPresentation) { FactoryBuildSheet(builder: builder) }
        .sheet(isPresented: $importing) { FactoryImportView(model: model) { _ in importing = false } }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.terminalScreen = builder.terminal
                acceptance.bind("factory", action: { command in
                    switch command {
                    case .preview: builder.showingBuild = true
                    case .requestCancel: Task { await builder.cancel() }
                    case .inspect: Task { await builder.recover() }
                    case .save: if let factory = builder.current?.factory { use(factory) }
                    default: break
                    }
                }, snapshot: { ["stage": builder.current?.stage.rawValue ?? "none", "enabled": String(builder.service.enabled), "buildingSheet": String(builder.showingBuild), "follow": String(builder.terminal.follow)] })
            } }
            #endif
        }
    }
    private var buildPresentation: Binding<Bool> {
        #if DEBUG
        if acceptance != nil { return .constant(false) }
        #endif
        return $builder.showingBuild
    }
    private func factoryCard(title: String, subtitle: String, icon: String, description: String, status: String, action: String, disabled: Bool = false,
                             source: OfficialFactorySource? = nil, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 29)).foregroundStyle(.purple).frame(width: 54, height: 54).background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                if source != nil { Spacer(minLength: 8); OfficialSourceBadge(compact: true) }
            }
            Text(description).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
            if let source { FactorySourceDetails(source: source, compact: true) }
            Divider()
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button(action, action: perform).frame(maxWidth: .infinity).disabled(disabled)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
    @ViewBuilder private func jobView(_ job: FactoryBuildJob) -> some View {
        Button("Factory library", systemImage: "chevron.left") { showJob = false }.buttonStyle(.plain).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 7) { Text(FactoryBuildModel.title(job)).font(.title.bold()); Text("\(job.plan.name) · ARM64 · \(job.plan.sizeGiB) GiB factory").foregroundStyle(.secondary) }
        if job.stage == .failed {
            Text(job.failure.flatMap(FactoryBuildFailure.init(rawValue:))?.explanation ?? "No factory was added. The build output was preserved; inspect the terminal and build details.")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if let factory = job.factory {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 8) { Text("Built, checked and added to your library").font(.headline); Text("Use this foundation for a new VM, then apply your developer setup.").foregroundStyle(.secondary); Button("Use for new VM", systemImage: "plus") { use(factory) }.buttonStyle(.borderedProminent) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Text("First-boot and graphics checks have not been run for this image.").font(.caption).foregroundStyle(.secondary)
        }
        if job.cleanupRequired {
            Label("Cleanup must verify this job’s labeled container and volume before another build can start.", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
            Button("Verify and clean up owned resources") { Task { await builder.recover() } }.disabled(builder.submitting)
        }
        if job.active {
            HStack(spacing: 8) {
                ForEach([("Download", FactoryBuildStage.downloading), ("Packages", .packages), ("Image", .image), ("Verify", .verifying), ("Add to library", .importing)], id: \.0) { label, stage in
                    VStack(alignment: .leading, spacing: 6) { Capsule().fill(job.stage == stage ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 3); Text(label).font(.caption).foregroundStyle(job.stage == stage ? .primary : .secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        VStack(spacing: 0) {
            HStack { Circle().fill(job.active ? .green : .secondary).frame(width: 7, height: 7); Text(job.active ? "Live terminal" : "Build output").font(.callout.bold()); Spacer(); Text("120 × 30").font(.caption).foregroundStyle(.secondary); Toggle("Follow output", isOn: Binding(get: { builder.terminal.follow }, set: { builder.terminal.follow = $0 })).toggleStyle(.switch).controlSize(.small) }.padding(11).background(.quaternary)
            ProvisioningNativeTerminal(screen: builder.terminal).frame(height: 360)
        }.clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
        HStack { Text(job.active ? "You can leave this page. The build will continue." : "Existing factories and VMs are unchanged.").font(.caption).foregroundStyle(.secondary); Spacer(); if job.active { Button("Cancel build") { Task { await builder.cancel() } }.accessibilityIdentifier("factory.cancel") } }
        DisclosureGroup("Build details") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Job: " + job.id.uuidString).textSelection(.enabled)
                Text("Recipe: " + job.plan.recipeSHA256).textSelection(.enabled)
                Text("Factory capacity: \(job.plan.sizeGiB) GiB · New VM disks can grow")
                Text("Package checks and image sealing are separate from guest boot testing.")
                if let failure = job.failure { Text("Result: " + failure) }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 7)
        }
    }
}

struct FactoryBuildSheet: View {
    #if DEBUG
    @Environment(\.setupAcceptance) private var acceptance
    #endif
    @ObservedObject var builder: FactoryBuildModel
    @State private var name = "Lean Omarchy"
    @State private var size = 20
    @Environment(\.dismiss) private var dismiss
    private var canStart: Bool { builder.review != nil && builder.review?.plan.name == name && builder.review?.plan.sizeGiB == size && !builder.checking && !builder.submitting }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Build lean factory", systemImage: "hammer").font(.title2.bold())
            Text("A reusable starting image for your new VMs.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { Text("Lean Omarchy foundation").font(.headline); Text("Omarchy desktop · Native Mac integration · Git, Python and build tools"); Text("Choose apps, profiles, themes and layouts per VM.").font(.caption).foregroundStyle(.secondary) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text("Image name").font(.callout.bold())
                TextField("Lean Omarchy", text: $name).textFieldStyle(.roundedBorder)
            }
            if builder.checking { HStack { ProgressView().controlSize(.small); Text("Checking existing Docker and build storage…").foregroundStyle(.secondary) } }
            if let review = builder.review {
                Label("Local ARM64 engine ready · " + review.context, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("At least \(size + 4) GiB on the artifact volume + 3 GiB of Docker scratch space. Additional space is checked before import.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Available: " + ByteCountFormatter.string(fromByteCount: review.availableBytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            if let error = builder.error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("Downloads sources and packages, then uses a privileged Docker container to prepare the disk. Existing VMs are unaffected.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Advanced") { Picker("Factory disk capacity", selection: $size) { ForEach([20,32,64,128], id: \.self) { Text("\($0) GiB").tag($0) } }; Text("New VMs can use a larger disk. Build inputs come from this app’s reviewed recipe.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack { Button("Check again") { Task { await builder.check(name: name, size: size) } }.disabled(builder.checking || builder.submitting); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Build factory") { Task { await builder.start() } }.buttonStyle(.borderedProminent).disabled(!canStart).accessibilityIdentifier("factory.start") }
        }.padding(26).frame(width: 570).disabled(builder.submitting)
        .task(id: name + ":" + String(size)) {
            builder.review = nil
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await builder.check(name: name, size: size)
        }
        .background {
            #if DEBUG
            if let acceptance { Color.clear.allowsHitTesting(false).onAppear {
                acceptance.bind("factory-sheet", action: { command in
                    switch command {
                    case .name(let value): name = value
                    case .resources(_, _, let value): size = value
                    case .save: if canStart { Task { await builder.start() } }
                    default: break
                    }
                }, snapshot: { ["name": name, "size": String(size), "ready": String(canStart), "error": builder.error ?? "", "checking": String(builder.checking)] })
            } }
            #endif
        }
    }
}
