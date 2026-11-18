import Foundation

/// JSON value that keeps object key order and number text, so an edit of a user's config file
/// changes only what we touch. Output matches `JSON.stringify(value, null, 2)` (Claude Code's format).
nonisolated indirect enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    case null
    case bool(Bool)
    /// Number text as written in the file.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    static let emptyObject = OrderedJSON.object([])

    // MARK: - Access

    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// Number as written in the file, e.g. "5".
    var numberText: String? {
        if case .number(let value) = self { value } else { nil }
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    var members: [Member]? {
        if case .object(let value) = self { value } else { nil }
    }

    // MARK: - Parse

    struct ParseError: Error, CustomStringConvertible {
        var offset: Int
        var reason: String
        var description: String { "JSON error at byte \(offset): \(reason)" }
    }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("extra text after the value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ reason: String) -> ParseError {
            ParseError(offset: index, reason: reason)
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("expected \(word)")
            }
            index += expected.count
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                members.append(Member(key: key, value: try value()))
                skipWhitespace()
                guard index < bytes.count else { throw error("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw error("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            let allowed = Set("+-.eE0123456789".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else {
                index = start
                throw error("unexpected character")
            }
            return .number(text)
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = [UInt8]()
            func flush() {
                scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
                run.removeAll(keepingCapacity: true)
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    flush()
                    index += 1
                    guard index < bytes.count else { throw error("unexpected end") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), index + 6 <= bytes.count,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default:
                        throw error("bad escape")
                    }
                default:
                    guard byte >= 0x20 else { throw error("control character in string") }
                    run.append(byte)
                    index += 1
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("bad \\u escape")
            }
            index += 4
            return code
        }
    }

    // MARK: - Write

    /// Pretty text, 2-space indent, like `JSON.stringify(value, null, 2)`.
    func prettyText(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let text): return text
        case .string(let value): return Self.quoted(value)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.prettyText(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { "\(inner)\(Self.quoted($0.key)): \($0.value.prettyText(indent: inner))" }
                .joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
