import Foundation
import KontorModel

/// Reading and writing `.kontor` documents with the checks the bare model coding does not make.
///
/// The model decodes leniently (every key is optional, so older and hand-written files keep
/// loading). On its own that means *any* JSON object opens as an empty portfolio, and autosave
/// would then overwrite the original. And a single non-finite number (an exchange rate of 0 that
/// became infinity) makes a document impossible to save. Both are handled here, for the document
/// layer and for anything else that opens or writes portfolio files.
public enum DocumentIO {
    public enum ReadError: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// Valid JSON, but nothing in it says "Kontor portfolio".
        case notAPortfolio
        /// A collection that must be a list is `null` or of another type.
        case damaged(key: String)
        case invalidVersion(Int)
        /// A key that differs from a known one only in spelling (letter case); its content would be dropped.
        case unknownSpelling(key: String, expected: String)

        public var description: String {
            switch self {
            case .notAPortfolio:
                "This is not a Kontor portfolio. The file is valid JSON, but it contains none of the data a portfolio has."
            case .damaged(let key):
                "The file is damaged: “\(key)” should be a list. Nothing was changed; restore the file from a backup or fix it in a text editor."
            case .invalidVersion(let version):
                "The file has an invalid format version (\(version))."
            case .unknownSpelling(let key, let expected):
                "The file is damaged: it contains “\(key)” where “\(expected)” is expected. Nothing was changed; fix the key in a text editor."
            }
        }

        public var errorDescription: String? { description }
    }

    /// What ``read(_:)`` repaired while opening.
    public struct Repairs: Equatable, Sendable {
        /// Exchange rates that were zero, negative or not a number, and were dropped.
        public var droppedRates = 0
        /// The risk-free rate was not a number and was reset to 0.
        public var resetRiskFreeRate = false

        public init() {}

        public var isEmpty: Bool { droppedRates == 0 && !resetRiskFreeRate }

        public var summary: String {
            var parts: [String] = []
            if droppedRates > 0 { parts.append("\(droppedRates) unusable exchange rate\(droppedRates == 1 ? " was" : "s were") removed") }
            if resetRiskFreeRate { parts.append("the risk-free rate was reset") }
            return parts.joined(separator: ", ")
        }
    }

    private static let collectionKeys: Set<String> = [
        "securities", "accounts", "depots", "transactions", "taxonomies", "watchlists", "plans", "exchangeRates", "dashboards",
    ]

    private static let knownKeys = collectionKeys.union(["formatVersion", "name", "settings"])

    /// Decodes a document, refusing JSON that is not a portfolio and repairing numbers that could
    /// not be written back.
    public static func read(_ data: Data) throws -> (file: PortfolioFile, repairs: Repairs) {
        try preflight(data)
        var file = try PortfolioFile(data: data)
        let repairs = sanitize(&file)
        return (file, repairs)
    }

    /// Checks the top level of a document without decoding it: it must be an object that carries a
    /// format version (≥ 1) or at least one portfolio collection, and no collection may be `null`.
    /// Malformed JSON is left to the decoder, which reports it better.
    public static func preflight(_ data: Data) throws {
        guard let keys = topLevelKeys(of: data) else { return }
        var recognised = false
        for (key, kind) in keys {
            if key == "formatVersion" {
                if case .integer(let version) = kind {
                    guard version >= 1 else { throw ReadError.invalidVersion(version) }
                    recognised = true
                }
            } else if collectionKeys.contains(key) {
                guard kind == .array else { throw ReadError.damaged(key: key) }
                recognised = true
            } else if let expected = knownKeys.first(where: { $0 != key && $0.lowercased() == key.lowercased() }) {
                throw ReadError.unknownSpelling(key: key, expected: expected)
            }
        }
        guard recognised else { throw ReadError.notAPortfolio }
    }

    /// Removes values that JSON cannot represent or the engine cannot divide by.
    @discardableResult
    public static func sanitize(_ file: inout PortfolioFile) -> Repairs {
        var repairs = Repairs()
        for i in file.exchangeRates.indices {
            let series = file.exchangeRates[i]
            guard series.rates.contains(where: { !($0.isFinite && $0 > 0) }) || series.rates.count != series.days.count else { continue }
            var days = [Int32](), rates = [Double]()
            for (day, rate) in zip(series.days, series.rates) where rate.isFinite && rate > 0 {
                days.append(day)
                rates.append(rate)
            }
            repairs.droppedRates += max(series.rates.count, series.days.count) - rates.count
            file.exchangeRates[i].days = days
            file.exchangeRates[i].rates = rates
        }
        if !file.settings.riskFreeRate.isFinite {
            file.settings.riskFreeRate = 0
            repairs.resetRiskFreeRate = true
        }
        return repairs
    }

    /// Encodes a document. A file that holds a number JSON cannot represent is repaired rather than
    /// refused: losing one damaged rate is better than being unable to save anything.
    public static func write(_ file: PortfolioFile, pretty: Bool) throws -> Data {
        do {
            return try file.encoded(pretty: pretty)
        } catch let error as EncodingError {
            var repaired = file
            guard !sanitize(&repaired).isEmpty else { throw error }
            return try repaired.encoded(pretty: pretty)
        }
    }

    // MARK: Top-level scan

    private enum ValueKind: Equatable { case array, integer(Int), other }

    /// The keys of the top-level JSON object with the kind of each value; nil if the data is not a
    /// JSON object (the decoder then produces the error). A small scanner rather than
    /// `JSONSerialization`, so that a 40 MB document is not parsed twice.
    private static func topLevelKeys(of data: Data) -> [(String, ValueKind)]? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [(String, ValueKind)]? in
            let count = bytes.count
            var i = 0
            func skipSpace() { while i < count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
            /// Reads a string starting at the opening quote; returns its raw (still escaped) text.
            func string() -> String? {
                guard i < count, bytes[i] == 0x22 else { return nil }
                i += 1
                let start = i
                while i < count, bytes[i] != 0x22 {
                    i += bytes[i] == 0x5C ? 2 : 1
                }
                guard i < count else { return nil }
                let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                i += 1
                return text
            }
            /// Skips one value; reports what it was.
            func value() -> ValueKind? {
                skipSpace()
                guard i < count else { return nil }
                switch bytes[i] {
                case 0x22:
                    return string() == nil ? nil : .other
                case 0x5B, 0x7B:
                    let isArray = bytes[i] == 0x5B
                    var depth = 0
                    while i < count {
                        switch bytes[i] {
                        case 0x22:
                            guard string() != nil else { return nil }
                            continue
                        case 0x5B, 0x7B: depth += 1
                        case 0x5D, 0x7D: depth -= 1
                        default: break
                        }
                        i += 1
                        if depth == 0 { return isArray ? .array : .other }
                    }
                    return nil
                default:
                    let start = i
                    while i < count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
                    let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                    return Int(text).map { .integer($0) } ?? .other
                }
            }
            // A UTF-8 byte order mark is tolerated by the decoder as well.
            if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
            skipSpace()
            guard i < count, bytes[i] == 0x7B else { return nil }
            i += 1
            var result: [(String, ValueKind)] = []
            while true {
                skipSpace()
                guard i < count else { return nil }
                if bytes[i] == 0x7D { return result }
                guard let key = string() else { return nil }
                skipSpace()
                guard i < count, bytes[i] == 0x3A else { return nil }
                i += 1
                guard let kind = value() else { return nil }
                result.append((key, kind))
                skipSpace()
                guard i < count else { return nil }
                if bytes[i] == 0x2C { i += 1 } else if bytes[i] != 0x7D { return nil }
            }
        }
    }
}
