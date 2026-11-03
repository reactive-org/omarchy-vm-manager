import Foundation

/// Explicit internal factory only. App/CLI execution gates do not construct it.
/// One admitted helper reservation at a time; no automatic restart or adoption.
actor ProvisioningHelperLauncher: ProvisioningServiceLaunching, ProvisioningTerminalLaunching {
    enum Phase: Sendable { case prepared, launching, registered, abandoned, exited, unconfirmed }
    private struct Pending: Sendable {
        let admission: ProvisioningHelperLaunchAdmission
        let credentials: ProvisioningHelperCredentials
        let delivery: ProvisioningFrozenDeliverySource?
        let transport: ProvisioningTransportHandoff?
    }
    private struct Entry {
        let ticket: ProvisioningHelperLaunchTicket
        var pending: Pending?
        let directory: URL
        var phase = Phase.prepared
        var child: ProvisioningHelperChild?
        var client: ProvisioningHelperIPCClient?
        var terminal: ProvisioningTerminalClient?
        var sessionServer: ProvisioningManagerSessionServer?
        var sessionTask: Task<Void, Never>?
    }
    private let layout: ProvisioningPackageLayout
    private let directory: URL
    private let policy: ProvisioningHelperSigningPolicy
    private var entries: [UUID: Entry] = [:]
    private var preparing = false
    init(layout: ProvisioningPackageLayout, directory: URL, policy: ProvisioningHelperSigningPolicy = .sameApplicationTeam) throws {
        self.layout = layout; self.directory = directory; self.policy = policy
        try PrivateFiles.directory(directory, create: true)
    }
    func prepare(_ original: ProvisioningHelperWorkerRegistration) async throws -> ProvisioningHelperLaunchTicket {
        guard original.delivery == nil else { throw ProvisioningJobFailure.artifactUnavailable }
        return try await prepare(original, source: nil, transport: nil)
    }
    func prepare(_ original: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource) async throws -> ProvisioningHelperLaunchTicket {
        guard original.delivery == delivery.receipt, original.transport == nil else { throw ProvisioningJobFailure.artifactUnavailable }
        _ = try delivery.read()
        return try await prepare(original, source: delivery, transport: nil)
    }
    func prepare(_ original: ProvisioningHelperWorkerRegistration, delivery: ProvisioningFrozenDeliverySource, transport: ProvisioningTransportHandoff) async throws -> ProvisioningHelperLaunchTicket {
        guard original.delivery == delivery.receipt else { throw ProvisioningJobFailure.invalidRequest }
        _ = try delivery.read(); try transport.verify(original)
        return try await prepare(original, source: delivery, transport: transport)
    }
    private func prepare(_ original: ProvisioningHelperWorkerRegistration, source: ProvisioningFrozenDeliverySource?, transport: ProvisioningTransportHandoff?) async throws -> ProvisioningHelperLaunchTicket {
        try original.validate()
        guard original.scope.helperIdentity == nil, !preparing, entries.count < 128,
              !entries.values.contains(where: { $0.ticket.registration.scope.jobID == original.scope.jobID || $0.phase != .exited }) else { throw ProvisioningHelperIPCFailure.ownership }
        preparing = true; defer { preparing = false }
        let layout = layout, policy = policy
        let admitted = try await helperBlocking { try ProvisioningHelperLaunchAdmission(layout: layout, policy: policy) }
        let identity = ProvisioningHelperIdentity(instanceID: UUID(), executableSHA256: admitted.executableSHA256, packageLockSHA256: ProvisioningPackagePin.lockSHA256)
        var registration = original; registration.scope.helperIdentity = identity
        let credentials = try ProvisioningHelperCredentials(identity: identity, registration: registration)
        let ticket = ProvisioningHelperLaunchTicket(id: UUID(), identity: identity, registration: registration)
        let root = directory.appendingPathComponent(identity.instanceID.uuidString)
        try PrivateFiles.directory(directory); try PrivateFiles.directory(root, create: true)
        entries[ticket.id] = Entry(ticket: ticket, pending: Pending(admission: admitted, credentials: credentials, delivery: source, transport: transport), directory: root)
        return ticket
    }
    func launch(_ ticket: ProvisioningHelperLaunchTicket) async throws -> ProvisioningHelperRegistrationReceipt {
        guard var entry = entries[ticket.id], entry.ticket == ticket, entry.phase == .prepared, let pending = entry.pending else { throw ProvisioningHelperIPCFailure.ownership }
        entry.phase = .launching; entries[ticket.id] = entry
        do {
            let root = entry.directory
            let child = try await helperBlocking { try ProvisioningHelperChild.spawn(admission: pending.admission, directory: root, hasDelivery: pending.delivery != nil, hasSessionAuthority: ticket.registration.sessionAuthorityVersion != nil, hasTransport: ticket.registration.transport != nil, hasTerminal: ticket.registration.terminalVersion == 1) }
            entries[ticket.id]?.child = child
            Task { [self] in let exit = await child.waitForExit(); observedExit(ticket.id, child: child.identity, exit: exit) }
            guard entries[ticket.id]?.phase == .launching else { child.disconnect(); throw ProvisioningHelperIPCFailure.unavailable }
            if let channel = child.sessionSocket {
                let server = try ProvisioningManagerSessionServer(socket: channel, credentials: pending.credentials)
                entries[ticket.id]?.sessionServer = server
                entries[ticket.id]?.sessionTask = Task { await server.serve() }
            }
            if let channel = child.terminalSocket {
                entries[ticket.id]?.terminal = ProvisioningTerminalClient(socket: channel, credentials: pending.credentials, jobID: ticket.registration.scope.jobID)
            }
            let client = ProvisioningHelperIPCClient(socket: child.socket, credentials: pending.credentials)
            entries[ticket.id]?.client = client
            // Verify both held file identity and the owned live child's loaded
            // code before giving that child the anonymous capability bytes.
            try await helperBlocking {
                try pending.admission.revalidate(); try pending.admission.verifyOwnedChild(child.pid)
                let bytes = try pending.delivery?.read()
                try pending.transport?.verify(ticket.registration)
                try child.bootstrap(pending.credentials.privateBootstrap())
                if let bytes { try child.deliver(bytes) }
                if let transport = pending.transport { try transport.verify(ticket.registration); try child.deliverTransport(transport.bytes) }
            }
            let receipt = try await client.awaitRegistration(ticket)
            guard entries[ticket.id]?.phase == .launching else { throw ProvisioningHelperIPCFailure.unavailable }
            entries[ticket.id]?.phase = .registered
            return receipt
        } catch {
            if entries[ticket.id]?.child == nil {
                entries[ticket.id]?.phase = .exited; entries[ticket.id]?.pending = nil
            } else { await abandon(ticket) }
            throw error
        }
    }
    func abandon(_ ticket: ProvisioningHelperLaunchTicket) async {
        guard let entry = entries[ticket.id], entry.ticket == ticket, entry.phase != .exited else { return }
        entries[ticket.id]?.phase = .abandoned
        entry.child?.disconnect(); entry.client?.disconnect(); entry.terminal?.disconnect(); entry.sessionServer?.stop()
        if entry.child == nil, entry.phase == .prepared { entries[ticket.id]?.pending = nil; entries[ticket.id]?.phase = .exited }
    }
    func reconcile(_ expectation: ProvisioningRecoveryExpectation) async throws -> ProvisioningRecoveryPermit {
        guard let entry = entries.values.first(where: { $0.ticket.registration.scope.sameWorker(as: expectation) }),
              entry.phase == .registered, let client = entry.client,
              expectation.helperIdentity == entry.ticket.identity else { throw ProvisioningHelperIPCFailure.ownership }
        return try await client.reconcile(expectation)
    }
    func bindSessionAuthority(_ activation: ProvisioningHelperActivation, check: @escaping ProvisioningManagerSessionCheck) async throws {
        guard let entry = entries.values.first(where: { $0.ticket.registration.scope.sameWorker(as: activation.scope) }),
              entry.phase == .registered, let server = entry.sessionServer else { throw ProvisioningHelperIPCFailure.ownership }
        try await server.bind(activation, check: check)
    }
    func dispatch(_ kind: ProvisioningHelperDispatchKind, activation: ProvisioningHelperActivation) async throws -> ProvisioningHelperWorkerSnapshot {
        guard let entry = entries.values.first(where: { $0.ticket.registration.scope.sameWorker(as: activation.scope) }),
              entry.phase == .registered, let client = entry.client,
              activation.registrationDigest == (try entry.ticket.registration.digest) else { throw ProvisioningHelperDispatchDenial.ownership }
        if kind == .activate { try entry.pending?.admission.revalidate(); try entry.pending?.transport?.verify(entry.ticket.registration) }
        return try await client.dispatch(kind, activation: activation)
    }
    func abort(_ activation: ProvisioningHelperActivation) async {
        guard let entry = entries.values.first(where: { $0.ticket.registration.scope.sameWorker(as: activation.scope) }) else { return }
        await abandon(entry.ticket)
    }
    func waitForExit(jobID: UUID, identity: ProvisioningHelperIdentity, timeout: Duration) async -> Bool {
        guard timeout > .zero, timeout <= .seconds(300) else { return false }
        let end = ContinuousClock.now + timeout
        repeat {
            guard let entry = entries.values.first(where: { $0.ticket.identity == identity && $0.ticket.registration.scope.jobID == jobID }) else { return false }
            if entry.phase == .exited { return true }
            if entry.phase == .unconfirmed { return false }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < end
        return false
    }
    func terminalClient(jobID: UUID) throws -> ProvisioningTerminalClient {
        guard let entry = entries.values.first(where: { $0.ticket.registration.scope.jobID == jobID }),
              entry.phase == .registered, entry.ticket.registration.terminalVersion == 1, let terminal = entry.terminal else { throw ProvisioningTerminalDenial.unavailable }
        return terminal
    }
    func phase(_ ticket: ProvisioningHelperLaunchTicket) -> Phase? { entries[ticket.id]?.phase }
    func releaseAfterCleanup(jobID: UUID, helperIdentity: ProvisioningHelperIdentity) async {
        guard let entry = entries.values.first(where: { $0.ticket.identity == helperIdentity && $0.ticket.registration.scope.jobID == jobID }) else { return }
        await abandon(entry.ticket)
    }
    private func observedExit(_ id: UUID, child: UUID, exit: ProvisioningHelperChild.Exit) {
        guard entries[id]?.child?.identity == child else { return }
        switch exit {
        case .exited:
            entries[id]?.phase = .exited; entries[id]?.client?.disconnect(); entries[id]?.terminal?.disconnect(); entries[id]?.sessionServer?.stop()
            entries[id]?.pending = nil; entries[id]?.client = nil; entries[id]?.terminal = nil; entries[id]?.child = nil
            entries[id]?.sessionServer = nil; entries[id]?.sessionTask = nil
        case .unconfirmed: entries[id]?.phase = .unconfirmed
        }
    }
}
