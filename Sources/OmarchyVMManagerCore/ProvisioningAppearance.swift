import Darwin
import DevVMProvisioningCore
import Foundation

public struct ProvisioningAppearanceSelection: Codable, Equatable, Sendable {
    public let theme: String?
    public let minimumStars: Int
    public let layoutFile: String?
    public let removeLayout: Bool
    public let layoutExample: ProvisioningLayoutExampleID?
    public init(theme: String? = nil, minimumStars: Int = 10, layoutFile: String? = nil, removeLayout: Bool = false, layoutExample: ProvisioningLayoutExampleID? = nil) {
        self.theme = theme; self.minimumStars = minimumStars; self.layoutFile = layoutFile; self.removeLayout = removeLayout; self.layoutExample = layoutExample
    }
    public var isEmpty: Bool { theme == nil && layoutFile == nil && layoutExample == nil && !removeLayout }
    public func validate() throws {
        guard minimumStars >= 0, [layoutFile != nil, layoutExample != nil, removeLayout].filter({ $0 }).count <= 1 else { throw ProvisioningAppearanceFailure.invalidLayout }
        if let theme { try ThemeSelection.validate(theme) }
        if let layoutFile {
            guard layoutFile.hasPrefix("/"), layoutFile.utf8.count <= 4096, !layoutFile.contains("//"),
                  !layoutFile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !layoutFile.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ProvisioningAppearanceFailure.invalidLayout }
        }
    }
}
public enum ProvisioningAppearanceFailure: Error, Sendable { case invalidLayout, workstationDisabled }
public enum ProvisioningAppearance {
    public static func failureMessage(_ error: any Error) -> String? {
        if let error = error as? ProvisioningAppearanceFailure {
            return error == .invalidLayout ? "Choose one layout example, a readable UTF-8 Lua file (up to 256 KiB), or removal of the managed layout." : "Theme and layout changes require Workstation preferences. Remove its disable setting from the configuration."
        }
        guard let error = error as? ThemeSelectionFailure else { return nil }
        switch error {
        case .invalidSelector: return "Enter an HTTPS GitHub repository URL, random, or most-starred."
        case .inaccessible: return "The theme repository could not be reached with a GET request. Check the URL and connectivity."
        case .catalogue, .responseTooLarge: return "The Omarchy theme catalogue is unavailable or invalid. Try a repository URL."
        case .starsUnavailable: return "Star-based choices need an existing, authenticated GitHub CLI (gh). Check gh authentication, use a repository URL, or use random with a minimum of 0 stars."
        case .noEligibleThemes: return "No available catalogue themes meet this choice. Try a lower minimum star count or a repository URL."
        }
    }
}
struct ProvisioningFrozenAppearance: Sendable {
    let selection: ProvisioningAppearanceSelection
    let theme: String?
    let layout: Data?
}
extension ProvisioningService {
    static let selectionLayout = ".omarchy-manager-layout.lua"
    func freezeAppearance(_ selection: ProvisioningAppearanceSelection?) async throws -> ProvisioningFrozenAppearance? {
        guard let selection, !selection.isEmpty else { return nil }
        try selection.validate(); try environment.admitPackage()
        // Read the selected file before a potentially slow lookup, retaining its
        // bytes rather than consulting the mutable path at apply time.
        let layout: Data?
        if let example = selection.layoutExample { layout = try LayoutExamples.source(example) }
        else { layout = try selection.layoutFile.map { try readSelectedLayout($0) } }
        let theme: String?
        if let value = selection.theme { theme = try await environment.themeResolver.resolve(value, minimumStars: selection.minimumStars) }
        else { theme = nil }
        try Task.checkCancellation(); try reviewAvailable()
        return .init(selection: selection, theme: theme, layout: layout)
    }
}
private func readSelectedLayout(_ path: String) throws -> Data {
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.isEmpty, parts.count <= 64 else { throw ProvisioningAppearanceFailure.invalidLayout }
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw ProvisioningAppearanceFailure.invalidLayout }
    defer { close(parent) }
    for part in parts.dropLast() {
        let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw ProvisioningAppearanceFailure.invalidLayout }
        close(parent); parent = next
    }
    let fd = openat(parent, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ProvisioningAppearanceFailure.invalidLayout }; defer { close(fd) }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 256 * 1024 else { throw ProvisioningAppearanceFailure.invalidLayout }
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 256 * 1024 + 1) ?? Data()
    guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
          data.count == before.st_size, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw ProvisioningAppearanceFailure.invalidLayout }
    return data
}

public struct ProvisioningAppearanceSummary: Sendable {
    public let theme: String?
    public let layoutIncluded: Bool
    public let layoutRemoved: Bool
    public let layoutExample: ProvisioningLayoutExample?
    public init(proposal: Data) {
        var values: [String: ManifestValue] = [:], receipts: [ManifestValue] = []
        if let parsed = try? PlainDataParser.parse(proposal, format: .json), case .object(let doc) = parsed,
           case .object(let features) = doc["features"], case .object(let options) = features["options"], case .object(let workstation) = options["workstation"] {
            values = workstation
            if case .array(let inputs) = doc["inputs"] { receipts = inputs }
        }
        if case .string(let value) = values["theme"], !value.isEmpty { theme = value } else { theme = nil }
        if case .string(let value) = values["layout"], !value.isEmpty { layoutIncluded = true } else { layoutIncluded = false }
        layoutRemoved = values["remove_layout"] == .bool(true)
        var matching: ProvisioningLayoutExample?
        if case .string(let path) = values["layout"], !path.isEmpty,
           let input = receipts.first(where: { if case .object(let file) = $0 { return file["path"] == .string(path) }; return false }),
           case .object(let file) = input, case .string(let hash) = file["sha256"],
           let examples = try? BundledProvisioning.layoutExamples() { matching = examples.first { $0.sourceSHA256 == hash } }
        layoutExample = matching
    }
}
