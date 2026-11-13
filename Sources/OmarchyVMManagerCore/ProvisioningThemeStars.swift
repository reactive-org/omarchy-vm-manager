import DevVMProvisioningCore
import Foundation

/// Reuses the bounded read-only tool runner. gh supplies its existing GitHub
/// authentication; this never logs a response or initiates an auth/install flow.
struct ProvisioningThemeStars: ThemeStarProviding {
    let files: any ProvisioningToolFiles
    let probe: any ProvisioningToolProbing
    let directories: [String]
    let home: String
    init(files: any ProvisioningToolFiles = LocalProvisioningToolFiles(), probe: any ProvisioningToolProbing = LocalProvisioningToolProbe(),
         directories: [String] = ProvisioningToolConfiguration.host().homebrewDirectories + ProvisioningToolConfiguration.host().searchDirectories,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.files = files; self.probe = probe; self.directories = directories; self.home = home
    }
    func counts(for repositories: [String]) async throws -> [String: Int] {
        guard repositories.count <= 1024,
              let gh = directories.lazy.compactMap({ files.executable($0 + "/gh") }).first else { throw ThemeSelectionFailure.starsUnavailable }
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: repositories.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(repositories[start..<min(start + 50, repositories.count)])
            let fields = try batch.enumerated().map { index, url -> String in
                let canonical = try ThemeSelection.repository(url), parts = canonical.split(separator: "/")
                return "r\(index): repository(owner: \"\(parts[parts.count - 2])\", name: \"\(parts.last!)\") { stargazerCount }"
            }
            let request = ProvisioningProbeRequest(executable: gh.identity,
                arguments: ["api", "--hostname", "github.com", "graphql", "-f", "query=query { " + fields.joined(separator: " ") + " }"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0", "GH_PAGER": "cat"],
                workingDirectory: "/private/tmp", timeout: 30, outputLimit: 256 * 1024)
            let result = await probe.run(request)
            guard result.failure == nil, case .object(let reply) = try? PlainDataParser.parse(result.output, format: .json),
                  case .object(let data) = reply["data"], Set(data.keys) == Set(batch.indices.map { "r\($0)" }) else { throw ThemeSelectionFailure.starsUnavailable }
            var missing = Set<String>()
            if let errors = reply["errors"] {
                guard case .array(let items) = errors else { throw ThemeSelectionFailure.starsUnavailable }
                for item in items {
                    guard case .object(let error) = item, error["type"] == .string("NOT_FOUND"),
                          case .array(let path) = error["path"], path.count == 1, case .string(let alias) = path[0], data[alias] == .null else { throw ThemeSelectionFailure.starsUnavailable }
                    missing.insert(alias)
                }
            }
            guard result.status == 0 || !missing.isEmpty else { throw ThemeSelectionFailure.starsUnavailable }
            for (index, repository) in batch.enumerated() {
                let alias = "r\(index)"
                if missing.contains(alias) { continue }
                guard case .object(let entry) = data[alias], case .integer(let count) = entry["stargazerCount"], count >= 0, let value = Int(exactly: count) else { throw ThemeSelectionFailure.starsUnavailable }
                counts[repository] = value
            }
        }
        return counts
    }
}
