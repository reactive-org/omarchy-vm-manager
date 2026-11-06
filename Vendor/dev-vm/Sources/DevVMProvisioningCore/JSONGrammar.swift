import Foundation

/// Bounded JSON grammar with duplicate keys checked before dictionary insertion.
/// Foundation decodes string escapes, including valid UTF-16 surrogate pairs
/// (which YAML's different escape rules do not accept).
struct JSONGrammar {
    let bytes: [UInt8]
    private var index = 0
    private var nodes = 0
    private let maximumNodes: Int?
    var objectKeys: [[String]: [String]] = [:]
    init(bytes: [UInt8], maximumNodes: Int? = nil) { self.bytes = bytes; self.maximumNodes = maximumNodes }

    mutating func parse() throws -> ManifestValue {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw ManifestError(.syntax) }
        return result
    }
    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        if index < bytes.count, bytes[index] == byte { index += 1; return true }
        return false
    }
    private mutating func require(_ byte: UInt8) throws {
        guard take(byte) else { throw ManifestError(.syntax) }
    }
    private mutating func value(depth: Int, path: [String] = []) throws -> ManifestValue {
        nodes += 1
        guard maximumNodes == nil || nodes <= maximumNodes! else { throw ManifestError(.sourceLimit) }
        guard depth <= PlainDataParser.maximumDepth else { throw ManifestError(.depth) }
        whitespace()
        guard index < bytes.count else { throw ManifestError(.syntax) }
        switch bytes[index] {
        case 123: // object
            guard depth < PlainDataParser.maximumDepth else { throw ManifestError(.depth) }
            index += 1
            var result: [String: ManifestValue] = [:]
            objectKeys[path] = []
            if take(125) { return .object(result) }
            repeat {
                let key = try string()
                guard key != "<<" else { throw ManifestError(.mergeKey) }
                guard result[key] == nil else { throw ManifestError(.duplicateKey) }
                try require(58)
                objectKeys[path, default: []].append(key)
                result[key] = try value(depth: depth + 1, path: path + [key])
                if take(125) { return .object(result) }
                try require(44)
            } while true
        case 91: // array
            guard depth < PlainDataParser.maximumDepth else { throw ManifestError(.depth) }
            index += 1
            var result: [ManifestValue] = []
            if take(93) { return .array(result) }
            repeat {
                result.append(try value(depth: depth + 1, path: path + [String(result.count)]))
                if take(93) { return .array(result) }
                try require(44)
            } while true
        case 34: return .string(try string())
        case 116: try literal(Array("true".utf8)); return .bool(true)
        case 102: try literal(Array("false".utf8)); return .bool(false)
        case 110: try literal(Array("null".utf8)); return .null
        default: return try number()
        }
    }
    private mutating func literal(_ word: [UInt8]) throws {
        guard bytes[index...].starts(with: word) else { throw ManifestError(.syntax) }
        index += word.count
    }
    private mutating func string() throws -> String {
        whitespace()
        let start = index
        try require(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                let text: String
                do { text = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                catch { throw ManifestError(.syntax) }
                guard !["{{", "{%", "{#"].contains(where: text.contains) else { throw ManifestError(.template) }
                return text
            }
            guard byte >= 32 else { throw ManifestError(.syntax) }
            if byte == 92 {
                guard index < bytes.count else { throw ManifestError(.syntax) }
                let escape = bytes[index]; index += 1
                if escape == 117 {
                    guard index + 4 <= bytes.count,
                          bytes[index..<index + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
                    else { throw ManifestError(.syntax) }
                    index += 4
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) { throw ManifestError(.syntax) }
            }
        }
        throw ManifestError(.syntax)
    }
    private mutating func number() throws -> ManifestValue {
        let start = index
        if index < bytes.count, bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw ManifestError(.syntax) }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw ManifestError(.syntax) }
            digits()
        }
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            let fraction = index; digits()
            guard index > fraction else { throw ManifestError(.syntax) }
        }
        if index < bytes.count, [69, 101].contains(bytes[index]) {
            index += 1
            if index < bytes.count, [43, 45].contains(bytes[index]) { index += 1 }
            let exponent = index; digits()
            guard index > exponent else { throw ManifestError(.syntax) }
        }
        guard index > start else { throw ManifestError(.syntax) }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if !token.contains("."), !token.contains("e"), !token.contains("E") {
            guard let n = Int64(token) else { throw ManifestError(.scalar) }
            return .integer(n)
        }
        guard let n = Double(token), n.isFinite else { throw ManifestError(.scalar) }
        return .number(n)
    }
    private mutating func digits() {
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
    }
}
