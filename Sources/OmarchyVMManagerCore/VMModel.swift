import Foundation
import TryOmarchyKitClient

public struct VMProfile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var memoryMiB: Int
    public var cpus: Int
    public var diskGiB: Int?
    public var clipboardEnabled: Bool
    public let createdAt: Date
    public var immersiveMode: Bool?
    public var settingsFingerprint: String? = nil
    public var ssh: SSHOptions? = nil
    public var ownerSetup: OwnerSetupOptions? = nil
    public var factory: FactoryIdentity? = nil
    public var sharedFolder: SharedFolderMapping? = nil

    public var isRetainedPOC: Bool { POCProfiles.ids.contains(id) }

    public init(id: UUID, name: String, memoryMiB: Int = 4096, cpus: Int = 4, diskGiB: Int? = 64,
                clipboardEnabled: Bool = true, createdAt: Date = Date(), immersiveMode: Bool? = nil) {
        self.id = id
        self.name = name
        self.memoryMiB = memoryMiB
        self.cpus = cpus
        self.diskGiB = diskGiB
        self.clipboardEnabled = clipboardEnabled
        self.createdAt = createdAt
        self.immersiveMode = immersiveMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memoryMiB, cpus, diskGiB, clipboardEnabled, createdAt, immersiveMode
        case settingsFingerprint, ssh, ownerSetup, factory, sharedFolder
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        memoryMiB = try values.decode(Int.self, forKey: .memoryMiB)
        cpus = try values.decode(Int.self, forKey: .cpus)
        diskGiB = try values.decodeIfPresent(Int.self, forKey: .diskGiB)
        clipboardEnabled = try values.decode(Bool.self, forKey: .clipboardEnabled)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        immersiveMode = try values.decodeIfPresent(Bool.self, forKey: .immersiveMode)
        settingsFingerprint = try values.decodeIfPresent(String.self, forKey: .settingsFingerprint)
        ssh = try values.decodeIfPresent(SSHOptions.self, forKey: .ssh)
        ownerSetup = try values.decodeIfPresent(OwnerSetupOptions.self, forKey: .ownerSetup)
        factory = try values.decodeIfPresent(FactoryIdentity.self, forKey: .factory)
        sharedFolder = try values.decodeIfPresent(SharedFolderMapping.self, forKey: .sharedFolder)
    }
}

public struct VMFailure: Error, Equatable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public let diagnostics: String

    public init(code: String, message: String, diagnostics: String = "") {
        self.code = code
        self.message = String(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }.prefix(4096))
        self.diagnostics = String(diagnostics.suffix(16_384))
    }

    public var errorDescription: String? { message }
}

public enum VMState: Equatable, Sendable {
    case stopped
    case validating
    case downloading(phase: VMRunPhase, percent: Int?)
    case starting(phase: VMRunPhase, percent: Int?)
    case running
    case pausing
    case paused
    case resuming
    case hostSleeping
    case executionUnknown
    case stopping
    case deleting
    case failed(VMFailure)

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .validating: "Validating"
        case .downloading: "Downloading"
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        case .hostSleeping: "Paused for Mac sleep"
        case .executionUnknown: "Execution state unknown"
        case .stopping: "Stopping"
        case .deleting: "Moving to Trash"
        case .failed: "Failed"
        }
    }

    public var canStart: Bool {
        switch self {
        case .stopped, .failed: true
        default: false
        }
    }
}

public struct VMSnapshot: Identifiable, Equatable, Sendable {
    public var id: UUID { profile.id }
    public let profile: VMProfile
    public let state: VMState
    public let sessionID: UUID?
    public let lastFailure: VMFailure?
    public let notice: String?
    public var sshReadiness: SSHReadiness = .disabled
    public var ownerSetupReadiness: OwnerSetupReadiness = .manual
    public var sharedFolderReadiness: SharedFolderReadiness = .disabled
    public var hibernation: GuestHibernationCapability?
    public var suspension: ExperimentalSuspension?
    public var suspensionMetadataUnsafe = false
    public var experimentalPowerBusy = false
    public var canRestoreExperimentalSuspension: Bool {
        sessionID == nil && suspension != nil && suspension?.restoreAttempted == false && !suspensionMetadataUnsafe
    }
    public var canAttemptExperimentalSuspend: Bool {
        guard !experimentalPowerBusy, sessionID != nil, state == .running, suspension == nil, !suspensionMetadataUnsafe, hibernation?.canAttempt == true else { return false }
        if case .ready = sshReadiness { return true }; return false
    }

    public init(profile: VMProfile, state: VMState, sessionID: UUID? = nil, lastFailure: VMFailure? = nil,
                notice: String? = nil, sshReadiness: SSHReadiness = .disabled, ownerSetupReadiness: OwnerSetupReadiness = .manual, sharedFolderReadiness: SharedFolderReadiness = .disabled, hibernation: GuestHibernationCapability? = nil, suspension: ExperimentalSuspension? = nil, suspensionMetadataUnsafe: Bool = false, experimentalPowerBusy: Bool = false) {
        self.profile = profile; self.state = state; self.sessionID = sessionID
        self.lastFailure = lastFailure; self.notice = notice
        self.sshReadiness = sshReadiness; self.ownerSetupReadiness = ownerSetupReadiness
        self.sharedFolderReadiness = sharedFolderReadiness
        self.hibernation = hibernation; self.suspension = suspension; self.suspensionMetadataUnsafe = suspensionMetadataUnsafe; self.experimentalPowerBusy = experimentalPowerBusy
    }
}

public enum POCProfiles {
    public static let ids: Set<UUID> = [UUID(uuidString: "C7C2B381-E43C-4A5A-8246-4314596B4C0A")!, UUID(uuidString: "89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B")!]
    public static let all: [VMProfile] = [
        VMProfile(id: UUID(uuidString: "C7C2B381-E43C-4A5A-8246-4314596B4C0A")!, name: "Omarchy POC A", diskGiB: nil),
        VMProfile(id: UUID(uuidString: "89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B")!, name: "Omarchy POC B", diskGiB: nil)
    ]

    public static func root(for profile: VMProfile, applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Omarchy VM Manager/VMs", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }
}

public struct VMLifecycleRecord: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let vmID: UUID
    public let sessionID: UUID
    public let text: String
}
