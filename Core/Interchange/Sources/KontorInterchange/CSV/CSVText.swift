import Foundation

/// Text encodings the CSV reader distinguishes.
public enum CSVTextEncoding: String, Hashable, Sendable, Codable, CaseIterable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    /// Windows-1252 (a superset of ISO-8859-1/Latin-1 for all printable characters) — the usual
    /// encoding of legacy German broker and bank exports.
    case windows1252

    /// Detects the encoding: byte-order marks first, then UTF-16 without BOM (NUL pattern), then
    /// strict UTF-8 validation, falling back to Windows-1252.
    public static func detect(_ data: Data) -> CSVTextEncoding {
        let head = [UInt8](data.prefix(4096))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if head.count >= 4 {
            var evenZeros = 0, oddZeros = 0
            for (index, byte) in head.enumerated() where byte == 0 {
                if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let half = head.count / 2
            if oddZeros > half * 4 / 10, evenZeros < half / 10 { return .utf16LittleEndian }
            if evenZeros > half * 4 / 10, oddZeros < half / 10 { return .utf16BigEndian }
        }
        return isValidUTF8(data) ? .utf8 : .windows1252
    }

    private static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var i = 0
            let n = buffer.count
            while i < n {
                let b = buffer[i]
                if b < 0x80 { i += 1; continue }
                let length: Int
                if b >= 0xC2, b <= 0xDF { length = 1 } else if b >= 0xE0, b <= 0xEF { length = 2 } else if b >= 0xF0, b <= 0xF4 { length = 3 } else { return false }
                for k in 1...length {
                    guard i + k < n, buffer[i + k] & 0xC0 == 0x80 else { return false }
                }
                if b == 0xE0, buffer[i + 1] < 0xA0 { return false }
                if b == 0xED, buffer[i + 1] > 0x9F { return false }
                if b == 0xF0, buffer[i + 1] < 0x90 { return false }
                if b == 0xF4, buffer[i + 1] > 0x8F { return false }
                i += length + 1
            }
            return true
        }
    }

    /// The code points of Windows-1252 bytes 0x80…0x9F (unassigned bytes map to their C1 control).
    private static let windows1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    /// Decodes `data` (byte-order marks are removed; invalid sequences become U+FFFD).
    public func decode(_ data: Data) -> String {
        switch self {
        case .utf8:
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            return String(decoding: bytes, as: UTF8.self)
        case .utf16LittleEndian, .utf16BigEndian:
            let little = self == .utf16LittleEndian
            var units = [UInt16]()
            units.reserveCapacity(data.count / 2)
            var iterator = data.makeIterator()
            while let first = iterator.next(), let second = iterator.next() {
                units.append(little ? UInt16(first) | UInt16(second) << 8 : UInt16(first) << 8 | UInt16(second))
            }
            if units.first == 0xFEFF { units.removeFirst() }
            return String(decoding: units, as: UTF16.self)
        case .windows1252:
            var scalars = String.UnicodeScalarView()
            scalars.reserveCapacity(data.count)
            for byte in data {
                let value = byte >= 0x80 && byte <= 0x9F ? CSVTextEncoding.windows1252High[Int(byte) - 0x80] : UInt32(byte)
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            }
            return String(scalars)
        }
    }
}

/// Low-level CSV record splitting and joining (RFC 4180 with the usual real-world leniency).
enum CSVCodec {
    struct Record {
        var fields: [String]
        /// 1-based line on which the record starts.
        var line: Int
    }

    /// Splits `text` into records. Handles quoted fields with embedded delimiters, doubled quotes and
    /// line breaks, CR/LF/CRLF line endings; unquoted fields are trimmed; blank lines are skipped.
    /// - Parameter limit: stop after this many records (for sniffing).
    static func parse(_ text: String, delimiter: UInt8, quote: UInt8 = 34, limit: Int = .max) -> [Record] {
        var records: [Record] = []
        var text = text
        text.withUTF8 { b in
            let n = b.count
            var i = 0
            var line = 1
            var fields: [String] = []
            var recordLine = 1
            var hasContent = false

            func finishRecord() {
                if hasContent { records.append(Record(fields: fields, line: recordLine)) }
                fields.removeAll(keepingCapacity: true)
                hasContent = false
            }

            while i <= n, records.count < limit {
                // Parse one field starting at i.
                if fields.isEmpty { recordLine = line }
                var j = i
                while j < n, b[j] == 32 || b[j] == 9 && delimiter != 9 { j += 1 }
                if j < n, b[j] == quote {
                    // Quoted field.
                    var value = [UInt8]()
                    j += 1
                    while j < n {
                        if b[j] == quote {
                            if j + 1 < n, b[j + 1] == quote {
                                value.append(quote)
                                j += 2
                                continue
                            }
                            j += 1
                            break
                        }
                        if b[j] == 10 { line += 1 }
                        value.append(b[j])
                        j += 1
                    }
                    // Lenient: keep anything between the closing quote and the delimiter.
                    let restStart = j
                    while j < n, b[j] != delimiter, b[j] != 10, b[j] != 13 { j += 1 }
                    if j > restStart {
                        let rest = String(decoding: UnsafeBufferPointer(rebasing: b[restStart..<j]), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                        value.append(contentsOf: rest.utf8)
                    }
                    fields.append(String(decoding: value, as: UTF8.self))
                    hasContent = true
                } else {
                    let start = i
                    j = i
                    while j < n, b[j] != delimiter, b[j] != 10, b[j] != 13 { j += 1 }
                    var s = start, e = j
                    while s < e, b[s] == 32 || b[s] == 9 { s += 1 }
                    while e > s, b[e - 1] == 32 || b[e - 1] == 9 { e -= 1 }
                    if e > s { hasContent = true }
                    fields.append(String(decoding: UnsafeBufferPointer(rebasing: b[s..<e]), as: UTF8.self))
                }
                // What ended the field?
                if j >= n {
                    finishRecord()
                    break
                }
                if b[j] == delimiter {
                    i = j + 1
                    if i == n { // trailing delimiter: one more empty field
                        fields.append("")
                        finishRecord()
                        break
                    }
                    continue
                }
                // Line break.
                if b[j] == 13, j + 1 < n, b[j + 1] == 10 { j += 1 }
                line += 1
                i = j + 1
                finishRecord()
            }
        }
        return records
    }

    /// Quotes `field` if needed and appends it to `output`.
    static func append(_ field: String, to output: inout String, delimiter: Character, alwaysQuote: Bool = false) {
        var needsQuotes = alwaysQuote
        if !needsQuotes {
            for scalar in field.unicodeScalars {
                if scalar == "\"" || scalar == "\n" || scalar == "\r" || Character(scalar) == delimiter {
                    needsQuotes = true
                    break
                }
            }
            if !needsQuotes, let first = field.first, let last = field.last, first == " " || last == " " { needsQuotes = true }
        }
        if needsQuotes {
            output.append("\"")
            output.append(field.replacingOccurrences(of: "\"", with: "\"\""))
            output.append("\"")
        } else {
            output.append(field)
        }
    }
}
