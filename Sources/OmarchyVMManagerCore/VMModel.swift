import Foundation
import TryOmarchyKitClient

public struct VMProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var memoryMiB: Int
    public var cpus: Int
    public var clipboardEnabled: Bool

    public init(id: UUID, name: String, memoryMiB: Int = 4096, cpus: Int = 2,
                clipboardEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.memoryMiB = memoryMiB
        self.cpus = cpus
        self.clipboardEnabled = clipboardEnabled
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
    case stopping
    case failed(VMFailure)

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .validating: "Validating"
        case .downloading: "Downloading"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
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
}

public enum POCProfiles {
    public static let all: [VMProfile] = [
        VMProfile(id: UUID(uuidString: "C7C2B381-E43C-4A5A-8246-4314596B4C0A")!, name: "Omarchy POC A"),
        VMProfile(id: UUID(uuidString: "89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B")!, name: "Omarchy POC B")
    ]

    public static func root(for profile: VMProfile, applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Omarchy VM Manager/VMs", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }
}
