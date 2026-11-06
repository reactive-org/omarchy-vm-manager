import Foundation
import TOMLDecoder

extension Resolver {
    func requirements(_ name: String, config: [String: ManifestValue]) throws -> ([String], [String: ManifestValue]) {
        let d = definitions[name]!.object!, handler = d["handler"]!.string!
        var packages: [String] = [], tools: [String: ManifestValue] = [:]
        func list(_ value: ManifestValue?) -> [String] { value?.array?.map { $0.string! } ?? [] }
        switch handler {
        case "tools": packages = list(config["packages"]); tools = config["tools"]!.object!
        case "selection", "browsers":
            let option = d["option"]?.string ?? "browsers", choices = d["choices"]!.object!
            packages = list(config[option]).map { choices[$0]!.string! }
        case "docker": packages = list(d["packages"])
        case "credentials": packages = list(config["packages"])
        case "keyring":
            packages = list(d["packages"])
            if config["seahorse"] == .bool(true) { packages.append(d["choices"]!.object!["seahorse"]!.string!) }
        case "workstation":
            packages = list(catalogue["workstation_packages"])
            if config["shell"] != .string("keep") { packages.append(config["shell"]!.string!) }
            if config["shell"] == .string("zsh") {
                if config["oh_my_zsh"] == .bool(true) { packages.append("git") }
                if config["starship"] == .bool(true) { packages.append("starship") }
            }
        case "toolchain":
            packages = ["mise-bin"]
            for language in list(config["prerequisites"]) { packages += list(catalogue["language_packages"]!.object![language]) }
        case "languages", "agents":
            tools = config["tools"]!.object!
            if handler == "languages" {
                for tool in tools.keys.sorted() { packages += list(catalogue["language_packages"]!.object![tool]) }
            }
        default: throw ManifestError(.resource)
        }
        if !tools.isEmpty { packages.append("mise-bin") }
        var seen = Set<String>()
        return (packages.filter { seen.insert($0).inserted }, tools)
    }

    func effects(configs: [String: ManifestValue], hasMise: Bool) -> ManifestValue {
        var files: [String] = [], sources: [ManifestValue] = []
        if let workstation = configs["workstation"]?.object {
            files += ["~/.config/foot/foot.ini", "~/.config/omarchy/shell.json", "~/.config/hypr/ (selected theme/layout)",
                      "~/.config/systemd/user/ (native idle/known first-login compatibility)"]
            let shell = workstation["shell"]!.string!
            if shell != "keep" { files.append("owner login shell (" + shell + ")") }
            if shell == "zsh" {
                files.append("~/.zshenv and ~/.zshrc (Omarchy environment and conditional mise activation)")
                if workstation["oh_my_zsh"] == .bool(true) {
                    files.append("~/.oh-my-zsh (official upstream clone when absent; existing installation preserved)")
                    sources.append(.object(["url": catalogue["features"]!.object!["workstation"]!.object!["oh_my_zsh_repository"]!,
                                            "destination": .string("~/.oh-my-zsh"),
                                            "updates": .string("Oh My Zsh updater; no pull on reapplication")]))
                }
                if workstation["starship"] == .bool(true) {
                    files.append("~/.zshrc (Starship prompt; existing starship.toml preserved)")
                    if workstation["starship_config"] != .string("") { files.append("~/.config/dev-vm/starship.toml (managed TOML selected via STARSHIP_CONFIG)") }
                }
            }
        }
        if configs["toolchain"] != nil { files.append("mise shims (initialized only on native mise installation); Bash and selected zsh activation verified") }
        if hasMise { files.append("~/.config/mise/config.toml (explicit selections only; native declarations reused)") }
        if configs["docker"]?.object?["access"] == .string("sudoless") {
            files.append("owner docker-group membership via native interactive Sudoless Docker opt-in (root-equivalent inside guest; desktop restart required)")
        }
        return .object(["files": .array(files.map(ManifestValue.string)), "sources": .array(sources),
                        "native": .string("Packages, browser integration and shims remain owned by native Omarchy/mise commands"),
                        "services": .array(configs["docker"] == nil ? [] : [.string("Docker UFW integration and socket activation")])])
    }
}

/// Bounded text and a lexical bracket/key-depth preflight protect the parser.
/// Only the selected, enabled zsh Starship configuration requires TOML parsing.
func validatePromptTOML(_ text: String) throws {
    guard text.utf8.count <= 65536 else { throw ManifestError(.toml) }
    let bytes = Array(text.utf8)
    var i = 0, depth = 0, dots = 0
    var containers: [UInt8] = [], previous: UInt8 = 0, token: [UInt8] = []
    var quote: UInt8? = nil, triple = false, comment = false
    func checkToken() throws {
        let value = String(decoding: token, as: UTF8.self)
        if matches(value, "(?:[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt])?[0-9]{2}:[0-9]{2}(?:[Zz]|[+-][0-9]{2}:[0-9]{2})?") {
            throw ManifestError(.toml) // TOML 1.0 requires seconds.
        }
    }
    while i < bytes.count {
        let c = bytes[i]
        if comment {
            if c == 10 {
                guard containers.last != 123 else { throw ManifestError(.toml) }
                comment = false; dots = 0
            }
            i += 1; continue
        }
        if let q = quote {
            if q == 34, c == 92 {
                if i + 1 < bytes.count, [101, 120].contains(bytes[i + 1]) { throw ManifestError(.toml) }
                i += 2; continue
            }
            if c == q {
                if !triple { quote = nil }
                else if i + 2 < bytes.count, bytes[i + 1] == q, bytes[i + 2] == q { quote = nil; i += 2 }
            }
        } else {
            if (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || [95, 58, 46, 43, 45].contains(c) {
                token.append(c)
            } else { try checkToken(); token = [] }
            switch c {
            case 34, 39:
                quote = c; triple = i + 2 < bytes.count && bytes[i + 1] == c && bytes[i + 2] == c
                if triple { i += 2 }
            case 35: comment = true
            case 91, 123: depth += 1; containers.append(c)
            case 93, 125:
                if c == 125, previous == 44 { throw ManifestError(.toml) }
                depth -= 1
                if !containers.isEmpty { containers.removeLast() }
            case 46: dots += 1
            case 10:
                guard containers.last != 123 else { throw ManifestError(.toml) }
                dots = 0
            case 61, 44: dots = 0
            default: break
            }
            guard depth <= 30, dots < 30 else { throw ManifestError(.toml) }
        }
        if ![9, 10, 13, 32].contains(c) { previous = c }
        i += 1
    }
    try checkToken()
    do { _ = try TOMLTable(source: text) }
    catch { throw ManifestError(.toml) }
}
