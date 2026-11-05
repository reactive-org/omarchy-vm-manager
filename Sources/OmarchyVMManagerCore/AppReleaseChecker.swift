import Foundation

/// Semantic version precedence, including numeric prerelease identifiers (dev.10 > dev.2).
/// Build metadata does not affect precedence or equality.
public struct AppReleaseVersion: Comparable, Sendable {
    let numbers: [Int]
    let prerelease: [String]

    public init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pattern = #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let precedence = value.split(separator: "+", maxSplits: 1)[0]
        let parts = precedence.split(separator: "-", maxSplits: 1)
        numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        guard prerelease.allSatisfy({ !Self.numeric($0) || $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = numeric(left), rightNumeric = numeric(right)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numeric(_ value: String) -> Bool { value.utf8.allSatisfy { (48...57).contains($0) } }
}

public struct AppRelease: Equatable, Sendable {
    public let tag: String
    public let url: URL
}

public enum AppReleaseCheckResult: Equatable, Sendable {
    case available(AppRelease)
    case upToDate
    case noReleases
}

public enum AppReleaseCheckError: Error, LocalizedError, Equatable {
    case unknownInstalledVersion, network, timedOut, rateLimited, server(Int), invalidResponse, tooManyReleases

    public var errorDescription: String? {
        switch self {
        case .unknownInstalledVersion:
            "This build has no valid embedded release tag. Install a packaged release for this app channel to compare versions."
        case .network: "GitHub could not be reached. Check your internet connection and try again."
        case .timedOut: "GitHub took too long to respond. Please try again."
        case .rateLimited: "GitHub is limiting update requests. Please try again later."
        case .server(let status): "GitHub returned an error (HTTP \(status)). Please try again later."
        case .invalidResponse: "GitHub returned an unexpected release response. Please try again later."
        case .tooManyReleases: "The release list could not be checked completely. Please visit the repository’s Releases page."
        }
    }
}

/// Reads release metadata only. It never downloads assets, changes the runtime or touches VM storage.
public struct AppReleaseChecker: Sendable {
    public static let releaseTagKey = "OmarchyReleaseTag"
    private static let repository = "https://github.com/reactive-org/omarchy-vm-manager"
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let channel: AppChannel

    public init(channel: AppChannel = .current, fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.fetch) {
        self.channel = channel
        self.fetch = fetch
    }

    public func check(installedTag: String?, shortVersion: String?) async throws -> AppReleaseCheckResult {
        guard let installedTag, installedTag.hasPrefix("v"),
              let installed = AppReleaseVersion(installedTag), let shortVersion,
              let bundleVersion = AppReleaseVersion(shortVersion), bundleVersion.prerelease.isEmpty,
              installed.numbers == bundleVersion.numbers else { throw AppReleaseCheckError.unknownInstalledVersion }

        var newest: (AppReleaseVersion, AppRelease)?
        // Follow all pages, including pages occupied by runtime-only dependency releases.
        // Refuse an incomplete check instead of claiming the app is current.
        for page in 1...10 {
            let url = URL(string: "https://api.github.com/repos/reactive-org/omarchy-vm-manager/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Omarchy-VM-Manager", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do { (data, response) = try await fetch(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw error.code == .timedOut ? AppReleaseCheckError.timedOut : .network
            } catch { throw AppReleaseCheckError.network }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AppReleaseCheckError.invalidResponse }
            if http.statusCode == 429 || (http.statusCode == 403 &&
                (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil)) {
                throw AppReleaseCheckError.rateLimited
            }
            guard http.statusCode == 200 else { throw AppReleaseCheckError.server(http.statusCode) }
            guard data.count <= 4 * 1024 * 1024,
                  let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
                throw AppReleaseCheckError.invalidResponse
            }
            for release in releases where !release.draft && release.tag_name.hasPrefix("v") {
                guard let version = AppReleaseVersion(release.tag_name) else { continue }
                let expectedPrefix: String
                switch channel {
                case .stable:
                    guard !release.prerelease, version.prerelease.isEmpty else { continue }
                    expectedPrefix = "Omarchy-VM-Manager"
                case .development:
                    guard release.prerelease, version.prerelease.count == 2, version.prerelease[0] == "dev",
                          version.prerelease[1].allSatisfy(\.isNumber) else { continue }
                    expectedPrefix = "Omarchy-VM-Manager-Dev"
                }
                guard release.assets.contains(where: { asset in
                    asset.state == "uploaded" && asset.name == "\(expectedPrefix)-\(release.tag_name)-macOS-arm64-notarized.zip"
                }) else { continue }
                if newest == nil || newest!.0 < version {
                    // Construct the link from our fixed repository and validated tag, never a response-supplied URL.
                    newest = (version, AppRelease(tag: release.tag_name,
                        url: URL(string: Self.repository + "/releases/tag/")!.appendingPathComponent(release.tag_name)))
                }
            }
            let hasNext = http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true
            if !hasNext {
                guard let newest else { return .noReleases }
                return installed < newest.0 ? .available(newest.1) : .upToDate
            }
        }
        throw AppReleaseCheckError.tooManyReleases
    }

    public static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let state: String }
    }
}
