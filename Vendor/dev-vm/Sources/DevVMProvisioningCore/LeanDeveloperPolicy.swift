import Foundation

/// Planning/transport wiring for the upstream guest helper. Omarchy and its
/// dependency preview retain ownership of actual package removals.
enum LeanDeveloperPolicy {
    static func keep(vmPackages: [String], features: ManifestValue) -> [String] {
        let requested = vmPackages.flatMap { value -> [String] in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(trimmed.split(separator: ":", maxSplits: 1).last ?? Substring(trimmed))
            // Preserve both the selector and native package name for repo/name selectors.
            return [name, String(name.split(separator: "/").last ?? Substring(name))]
        }
        return Set(requested + (features.object?["packages"]?.object?.map { $0.key } ?? [])).sorted()
    }
    static func candidates(keeping keep: [String]) throws -> [String] {
        guard let url = Bundle.module.url(forResource: "lean-developer", withExtension: "packages", subdirectory: "Resources/Provisioning/omarchy/guest"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { throw ManifestError(.resource) }
        let names = text.split(separator: "\n").map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.allSatisfy({ matches($0, "[A-Za-z0-9][A-Za-z0-9@._+\\-]*") }), Set(names).count == names.count else { throw ManifestError(.resource) }
        return names.filter { !keep.contains($0) }
    }
}
