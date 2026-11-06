import Foundation

public enum ThemeSelectionFailure: String, Error, Sendable {
    case invalidSelector, inaccessible, catalogue, starsUnavailable, noEligibleThemes, responseTooLarge
}
public struct ThemeHTTPResponse: Sendable {
    public let status: Int
    public let url: URL
    public let data: Data
    public init(status: Int, url: URL, data: Data = Data()) { self.status = status; self.url = url; self.data = data }
}
public protocol ThemeHTTPFetching: Sendable {
    /// A GET, never a clone. Body capture is needed only for the public catalogue.
    func get(_ url: URL, body: Bool) async throws -> ThemeHTTPResponse
}
public protocol ThemeStarProviding: Sendable {
    /// Missing/deleted repositories may be omitted; other incomplete results fail.
    func counts(for repositories: [String]) async throws -> [String: Int]
}
public enum ThemeSelection {
    public static let catalogueURL = URL(string: "https://raw.githubusercontent.com/omacom/omarchy-site/master/themes/index.html")!
    public static let markers = ["random", "most-starred"]
    public static func repository(_ input: String) throws -> String {
        guard input.utf8.count <= 2048, matches(input, "https://github\\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_][A-Za-z0-9._+\\-]*)/?") else { throw ThemeSelectionFailure.invalidSelector }
        let parts = input.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
        var name = String(parts.last!)
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.hasSuffix(".git") else { throw ThemeSelectionFailure.invalidSelector }
        var theme = name
        if theme.hasPrefix("omarchy-") { theme = String(theme.dropFirst(8)) }
        if theme.hasSuffix("-theme") { theme = String(theme.dropLast(6)) }
        guard matches(theme.lowercased(), "[a-z0-9_][a-z0-9._+\\-]*") else { throw ThemeSelectionFailure.invalidSelector }
        return "https://github.com/" + parts[parts.count - 2] + "/" + name
    }
    public static func validate(_ input: String) throws {
        guard !markers.contains(input) else { return }; _ = try repository(input)
    }
    /// Extract only repository links inside the upstream catalogue's theme figures.
    public static func catalogue(_ bytes: Data) throws -> [String] {
        guard bytes.count <= 2 * 1024 * 1024, let html = String(data: bytes, encoding: .utf8) else { throw ThemeSelectionFailure.catalogue }
        let tags = try NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive])
        let attributes = try NSRegularExpression(pattern: "(?:^|\\s)([A-Za-z][A-Za-z0-9:_-]*)\\s*=\\s*[\"']([^\"']*)[\"']")
        var inside = false, urls: [String: String] = [:]
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = (html as NSString).substring(with: match.range), lower = tag.lowercased()
            if lower.hasPrefix("</figure") { inside = false; continue }
            var fields: [String: String] = [:]
            for item in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                fields[(tag as NSString).substring(with: item.range(at: 1)).lowercased()] = (tag as NSString).substring(with: item.range(at: 2))
            }
            if lower.hasPrefix("<figure ") || lower.hasPrefix("<figure>") { inside = fields["class"]?.split(whereSeparator: { $0.isWhitespace }).contains("themes__theme") == true }
            if inside, lower.hasPrefix("<a "), let href = fields["href"], let url = try? repository(href) { urls[url.lowercased()] = urls[url.lowercased()] ?? url }
        }
        guard !urls.isEmpty, urls.count <= 1024 else { throw ThemeSelectionFailure.catalogue }
        return urls.values.sorted { $0.lowercased() < $1.lowercased() }
    }
}
public struct ThemeResolver: Sendable {
    let http: any ThemeHTTPFetching
    let stars: any ThemeStarProviding
    let choose: @Sendable (Int) -> Int
    public init(http: any ThemeHTTPFetching, stars: any ThemeStarProviding, choose: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }) {
        self.http = http; self.stars = stars; self.choose = choose
    }
    /// Resolve once before offline planning; the returned URL is frozen in the plan.
    public func resolve(_ selector: String, minimumStars: Int = 10) async throws -> String {
        try Task.checkCancellation(); try ThemeSelection.validate(selector)
        guard minimumStars >= 0 else { throw ThemeSelectionFailure.invalidSelector }
        let selected: String
        if ThemeSelection.markers.contains(selector) {
            let response = try await http.get(ThemeSelection.catalogueURL, body: true)
            guard response.status == 200, response.url == ThemeSelection.catalogueURL else { throw ThemeSelectionFailure.catalogue }
            let urls = try ThemeSelection.catalogue(response.data)
            let eligible: [String]
            if selector == "most-starred" || minimumStars > 0 {
                let counts = try await stars.counts(for: urls)
                guard Set(counts.keys).isSubset(of: Set(urls)), counts.values.allSatisfy({ $0 >= 0 }) else { throw ThemeSelectionFailure.starsUnavailable }
                if selector == "most-starred" {
                    eligible = counts.keys.sorted { counts[$0]! == counts[$1]! ? $0.lowercased() < $1.lowercased() : counts[$0]! > counts[$1]! }.prefix(1).map { $0 }
                } else { eligible = urls.filter { counts[$0].map { $0 >= minimumStars } == true } }
            } else { eligible = urls }
            guard !eligible.isEmpty else { throw ThemeSelectionFailure.noEligibleThemes }
            let index = selector == "most-starred" ? 0 : choose(eligible.count)
            guard eligible.indices.contains(index) else { throw ThemeSelectionFailure.noEligibleThemes }
            selected = eligible[index]
        } else { selected = try ThemeSelection.repository(selector) }
        try Task.checkCancellation()
        let response = try await http.get(URL(string: selected)!, body: false)
        guard (200..<300).contains(response.status), let canonical = try? ThemeSelection.repository(response.url.absoluteString) else { throw ThemeSelectionFailure.inaccessible }
        try Task.checkCancellation(); return canonical
    }
}
