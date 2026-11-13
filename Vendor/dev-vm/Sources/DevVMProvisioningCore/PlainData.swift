import CDevVMYAML
import Darwin
import Foundation

/// Plain manifest data, independent of Ansible, Python, transport and VM lifecycle.
public indirect enum ManifestValue: Hashable, Sendable, Encodable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([ManifestValue]), object([String: ManifestValue])

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var object: [String: ManifestValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [ManifestValue]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var integer: Int64? { if case .integer(let v) = self { v } else { nil } }
}

/// Diagnostics contain stable codes and numeric locations only; never manifest text or paths.
public struct ManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case inputSize, encoding, syntax, forbiddenYAML, depth, duplicateKey, stringKey
        case template, mergeKey, scalar, schema, file, changedFile, unsupportedFormat, resource
        case reference, cycle, conflict, disabledDependency, providerConflict, sourceLimit, sourceChanged, toml
    }
    public let code: Code
    public let line: Int?
    public let column: Int?
    init(_ code: Code, line: Int? = nil, column: Int? = nil) {
        self.code = code; self.line = line; self.column = column
    }
    public var description: String {
        if let line, let column { "manifest.\(code.rawValue) at \(line):\(column)" }
        else { "manifest.\(code.rawValue)" }
    }
}

public enum ManifestFormat: Sendable { case json, yaml }

struct PlainDocument: Sendable {
    let value: ManifestValue
    let objectKeys: [[String]: [String]]
}

public enum PlainDataParser {
    public static let maximumBytes = 256 * 1024
    public static let maximumDepth = 30

    public static func parse(_ data: Data, format: ManifestFormat) throws -> ManifestValue {
        try document(data, format: format).value
    }

    static func document(_ data: Data, format: ManifestFormat) throws -> PlainDocument {
        guard data.count <= maximumBytes else { throw ManifestError(.inputSize) }
        guard String(data: data, encoding: .utf8) != nil else { throw ManifestError(.encoding) }
        if format == .json {
            var reader = JSONGrammar(bytes: Array(data))
            let value = try reader.parse()
            return PlainDocument(value: value, objectKeys: reader.objectKeys)
        }
        let tree = try data.withUnsafeBytes { bytes -> PlainDocument in
            // Data's empty buffer may be nil. The C parser still requires a non-null buffer.
            var empty: UInt8 = 0
            return try withUnsafePointer(to: &empty) { fallback in
                guard let p = dvm_yaml_create(bytes.bindMemory(to: UInt8.self).baseAddress ?? fallback, data.count)
                else { throw ManifestError(.syntax) }
                defer { dvm_yaml_destroy(p) }
                var reader = EventReader(parser: p)
                try reader.advance()
                try reader.consume(1)
                try reader.consume(3)
                let value = try reader.value(depth: 0)
                try reader.consume(4)
                guard reader.current.kind == 2 else { throw reader.error(.syntax) }
                return PlainDocument(value: value, objectKeys: reader.objectKeys)
            }
        }
        return tree
    }

    /// Reads only this explicit regular file; referenced tasks/assets are never opened here.
    public static func read(_ url: URL) throws -> ManifestValue {
        try readDocument(url).value
    }

    static func readDocument(_ url: URL) throws -> PlainDocument {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw ManifestError(.file) }
        let format: ManifestFormat
        switch url.pathExtension.lowercased() {
        case "json": format = .json
        case "yml", "yaml": format = .yaml
        default: throw ManifestError(.unsupportedFormat)
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ManifestError(.file) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ManifestError(.file) }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw ManifestError(.inputSize) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw ManifestError(.file) }
            if n == 0 { break }
            guard data.count + n <= maximumBytes else { throw ManifestError(.inputSize) }
            data.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ManifestError(.changedFile) }
        return try document(data, format: format)
    }
}

func matches(_ value: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(value.startIndex..., in: value)
    return regex.firstMatch(in: value, range: range)?.range == range
}

private struct EventReader {
    let parser: OpaquePointer
    var current = dvm_yaml_event()
    var objectKeys: [[String]: [String]] = [:]

    func error(_ code: ManifestError.Code) -> ManifestError {
        ManifestError(code, line: Int(current.line), column: Int(current.column))
    }
    mutating func advance() throws {
        guard dvm_yaml_next(parser, &current) == 1 else { throw error(.syntax) }
        guard current.forbidden == 0 else { throw error(.forbiddenYAML) }
    }
    mutating func consume(_ kind: Int32) throws {
        guard current.kind == kind else { throw error(.syntax) }
        try advance()
    }
    mutating func value(depth: Int, path: [String] = []) throws -> ManifestValue {
        guard depth <= PlainDataParser.maximumDepth else { throw error(.depth) }
        switch current.kind {
        case 5:
            guard let bytes = current.value,
                  let s = String(bytes: UnsafeBufferPointer(start: bytes, count: current.length), encoding: .utf8)
            else { throw error(.encoding) }
            guard !["{{", "{%", "{#"].contains(where: s.contains) else { throw error(.template) }
            let v = try scalar(s, plain: current.plain != 0)
            try advance()
            return v
        case 6:
            guard depth < PlainDataParser.maximumDepth else { throw error(.depth) }
            try advance()
            var items: [ManifestValue] = []
            while current.kind != 7 { items.append(try value(depth: depth + 1, path: path + [String(items.count)])) }
            try advance()
            return .array(items)
        case 8:
            guard depth < PlainDataParser.maximumDepth else { throw error(.depth) }
            try advance()
            var result: [String: ManifestValue] = [:]
            objectKeys[path] = []
            while current.kind != 9 {
                guard case .string(let key) = try value(depth: depth + 1) else { throw error(.stringKey) }
                guard key != "<<" else { throw error(.mergeKey) }
                guard result[key] == nil else { throw error(.duplicateKey) }
                objectKeys[path, default: []].append(key)
                result[key] = try value(depth: depth + 1, path: path + [key])
            }
            try advance()
            return .object(result)
        default: throw error(.syntax)
        }
    }
    func scalar(_ s: String, plain: Bool) throws -> ManifestValue {
        guard plain else { return .string(s) }
        if ["", "~", "null", "Null", "NULL"].contains(s) { return .null }
        if ["true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON"].contains(s) { return .bool(true) }
        if ["false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF"].contains(s) { return .bool(false) }
        // Deliberately narrow, portable numeric subset. Never silently reinterpret YAML's
        // legacy octal/sexagesimal/underscored numbers or timestamps as ordinary strings.
        if matches(s, "[+-]?(?:0|[1-9][0-9]*)") {
            guard let n = Int64(s) else { throw error(.scalar) }
            return .integer(n)
        }
        if matches(s, "[+-]?(?:(?:[0-9]+\\.[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[0-9]+[eE][+-]?[0-9]+)") {
            guard let n = Double(s), n.isFinite else { throw error(.scalar) }
            return .number(n)
        }
        if matches(s, "[+-]?(?:0[0-9]+|0[xXoObB][0-9a-fA-F_]+|[0-9][0-9_]*_[0-9_]*|[0-9]+(?::[0-9]+)+(?:\\.[0-9]*)?)") ||
            (s.contains("_") && matches(s, "[+-]?[0-9][0-9_:.eE+-]*")) ||
            matches(s, "[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}.*") ||
            matches(s.lowercased(), "[+-]?\\.(?:inf|nan)") {
            throw error(.scalar)
        }
        return .string(s)
    }
}
