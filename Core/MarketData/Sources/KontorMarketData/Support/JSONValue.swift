import Foundation

/// A parsed JSON document. Objects keep their members in document order, which the generic JSON
/// feed relies on when it pairs the keys of an object with values inside it.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Parses UTF-8 encoded JSON (RFC 8259). Throws ``MarketDataError/malformedResponse(_:)``.
    public init(data: Data) throws {
        self = try data.withUnsafeBytes { raw in
            var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            return try parser.parseDocument()
        }
    }

    /// Parses a JSON string.
    public init(parsing text: String) throws {
        try self.init(data: Data(text.utf8))
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Member `key` of an object, nil otherwise.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Element `index` of an array (negative indexes count from the end), nil otherwise.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self else { return nil }
        let i = index < 0 ? a.count + index : index
        return a.indices.contains(i) ? a[i] : nil
    }
}

/// A JSON object with members in document order.
public struct JSONObject: Hashable, Sendable {
    public private(set) var keys: [String]
    public private(set) var values: [JSONValue]

    public init(keys: [String] = [], values: [JSONValue] = []) {
        precondition(keys.count == values.count)
        self.keys = keys
        self.values = values
    }

    public var count: Int { keys.count }

    /// The value of the first member named `key`.
    public subscript(key: String) -> JSONValue? {
        keys.firstIndex(of: key).map { values[$0] }
    }

    mutating func append(_ key: String, _ value: JSONValue) {
        keys.append(key)
        values.append(value)
    }
}

/// Recursive-descent JSON parser over raw UTF-8 bytes.
private struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var i = 0
    var depth = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        let value = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw error("unexpected trailing data") }
        return value
    }

    private func error(_ message: String) -> MarketDataError {
        .malformedResponse("Invalid JSON at byte \(i): \(message)")
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard i < bytes.count else { throw error("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: StaticString) throws {
        let n = literal.utf8CodeUnitCount
        guard i + n <= bytes.count else { throw error("unexpected end") }
        let matches = literal.withUTF8Buffer { lit in
            (0..<n).allSatisfy { bytes[i + $0] == lit[$0] }
        }
        guard matches else { throw error("invalid literal") }
        i += n
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= 256 else { throw error("nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        i += 1
        var object = JSONObject()
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected member name") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
            i += 1
            object.append(key, try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw error("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        i += 1
        var array = [JSONValue]()
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(array) }
        while true {
            array.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw error("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(array) }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        i += 1 // opening quote
        let start = i
        // Fast path: no escapes.
        while i < bytes.count, bytes[i] != UInt8(ascii: "\""), bytes[i] != UInt8(ascii: "\\") { i += 1 }
        guard i < bytes.count else { throw error("unterminated string") }
        if bytes[i] == UInt8(ascii: "\"") {
            let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            i += 1
            return s
        }
        var buffer = Array(bytes[start..<i])
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let c = bytes[i]
            i += 1
            if c == UInt8(ascii: "\"") { break }
            guard c == UInt8(ascii: "\\") else { buffer.append(c); continue }
            guard i < bytes.count else { throw error("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(e)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try parseHex4()
                if (0xD800..<0xDC00).contains(scalar), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    let saved = i
                    i += 2
                    let low = try parseHex4()
                    if (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = saved
                    }
                }
                let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(Character(unicode)).utf8))
            default: throw error("invalid escape")
            }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw error("unterminated \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            i += 1
            switch c {
            case 48...57: v = v << 4 | UInt32(c - 48)
            case 65...70: v = v << 4 | UInt32(c - 55)
            case 97...102: v = v << 4 | UInt32(c - 87)
            default: throw error("invalid \\u escape")
            }
        }
        return v
    }

    private mutating func parseNumber() throws -> Double {
        let start = i
        var isInteger = true
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        let digitsStart = i
        scan: while i < bytes.count {
            switch bytes[i] {
            case 48...57: i += 1
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                isInteger = false
                i += 1
            default: break scan
            }
        }
        guard i > digitsStart else { throw error("unexpected character") }
        if isInteger, i - digitsStart <= 15 {
            var v: Int64 = 0
            for k in digitsStart..<i { v = v * 10 + Int64(bytes[k] - 48) }
            return bytes[start] == UInt8(ascii: "-") ? -Double(v) : Double(v)
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        guard let v = Double(text) else { throw error("invalid number") }
        return v
    }
}
