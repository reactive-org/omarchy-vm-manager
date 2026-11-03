import Foundation

/// Incremental, bounded display policy shared by the native emulator and host
/// CLI terminal. This is deliberately a display subset, not a general terminal.
/// OSC (including 8/52/1337), DCS, APC, PM, SOS, queries, window operations and
/// C1 controls never reach a host renderer. Unicode is validated across frames.
public struct ProvisioningTerminalDisplay: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private enum State: Sendable { case text, escape, charset, csi, discardCSI, string, stringEscape }
    private var state: State = .text
    private var csi = [UInt8]()
    private var unicode = [UInt8]()
    private var cluster = ""
    private var clusterCount = 0
    public init() {}
    public var description: String { "ProvisioningTerminalDisplay(redacted)" }
    public var debugDescription: String { description }
    /// Reset both decoder and emulator after a reported gap. No claim that the
    /// remaining tail reconstructs the prior screen. Stray UTF-8 is discarded.
    public mutating func reset() { self = .init() }
    public mutating func consume(_ bytes: Data) -> Data {
        var output = Data()
        for byte in bytes {
            switch state {
            case .string:
                if byte == 7 || byte == 0x9c { state = .text }
                else if byte == 27 { state = .stringEscape }
            case .stringEscape:
                if byte == 92 || byte == 7 || byte == 0x9c { state = .text }
                else { state = byte == 27 ? .stringEscape : .string }
            case .escape:
                switch byte {
                case 91: state = .csi; csi.removeAll(keepingCapacity: true)
                case 93, 80, 95, 94, 88: state = .string
                case 40, 41: state = .charset
                case 55, 56, 68, 69, 77, 99: output.append(contentsOf: [27, byte]); state = .text
                case 27: break
                default: state = .text
                }
            case .charset:
                if byte == 66 || byte == 48 { output.append(contentsOf: [27, 40, byte]) }
                state = .text
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    if allowedCSI(csi, final: byte) { output.append(contentsOf: [27, 91] + csi + [byte]) }
                    csi.removeAll(keepingCapacity: true); state = .text
                } else if byte == 27 { csi.removeAll(keepingCapacity: true); state = .escape }
                else if csi.count < 64, (0x20...0x3f).contains(byte) { csi.append(byte) }
                else { csi.removeAll(keepingCapacity: true); state = .discardCSI }
            case .discardCSI:
                if (0x40...0x7e).contains(byte) { state = .text }
                else if byte == 27 { state = .escape }
            case .text:
                if !unicode.isEmpty {
                    if (0x80...0xbf).contains(byte) {
                        unicode.append(byte)
                        let expected = unicode[0] < 0xe0 ? 2 : (unicode[0] < 0xf0 ? 3 : 4)
                        if unicode.count == expected {
                            if let string = String(bytes: unicode, encoding: .utf8), let scalar = string.unicodeScalars.first,
                               !(0x80...0x9f).contains(scalar.value) {
                                let joined = cluster + string
                                if joined.count == 1 {
                                    if clusterCount < 16 { output.append(contentsOf: unicode); cluster = joined; clusterCount += 1 }
                                } else { output.append(contentsOf: unicode); cluster = string; clusterCount = 1 }
                            }
                            unicode.removeAll(keepingCapacity: true)
                        }
                        continue
                    }
                    unicode.removeAll(keepingCapacity: true)
                }
                switch byte {
                case 27: state = .escape; cluster = ""; clusterCount = 0
                case 9, 10, 13, 8: output.append(byte); cluster = ""; clusterCount = 0
                case 0x20...0x7e: output.append(byte); cluster = String(UnicodeScalar(byte)); clusterCount = 1
                case 0xc2...0xf4: unicode.append(byte)
                // Single-byte C1 introducers are discarded as complete strings,
                // so a legacy OSC payload cannot become visible or executable.
                case 0x90, 0x98, 0x9d, 0x9e, 0x9f: state = .string
                case 0x9b: state = .discardCSI
                default: break
                }
            }
        }
        return output
    }
    private func allowedCSI(_ bytes: [UInt8], final: UInt8) -> Bool {
        let isPrivate = bytes.first == 63
        let params = isPrivate ? Array(bytes.dropFirst()) : bytes
        guard params.allSatisfy({ (48...57).contains($0) || $0 == 59 || $0 == 58 }) else { return false }
        let values = String(decoding: params, as: UTF8.self).split(whereSeparator: { $0 == ";" || $0 == ":" })
        guard values.count <= 16, values.allSatisfy({ $0.count <= 4 && (Int($0) ?? 10000) <= (isPrivate ? 2004 : 1000) }) else { return false }
        if isPrivate { return [UInt8(104), 108].contains(final) && !values.isEmpty && values.allSatisfy({ ["25", "1047", "1049", "2004"].contains(String($0)) }) }
        if final == 104 || final == 108 { return !values.isEmpty && values.allSatisfy({ $0 == "4" || $0 == "20" }) }
        return Array("ABCDEFGHJKLMPSTXdfmrsu@".utf8).contains(final)
    }
}
