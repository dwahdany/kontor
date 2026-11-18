import Foundation
import KontorModel

/// Something the importer skipped, approximated or wants the user to know about.
/// Identical issues are aggregated: `count` tells how often it happened, `examples` shows a few cases.
public struct ImportWarning: Hashable, Sendable, Codable, CustomStringConvertible, Identifiable {
    public enum Severity: String, Hashable, Sendable, Codable {
        /// Informational: data without an equivalent in Kontor was left out on purpose (e.g. UI layouts).
        case info
        /// Data was approximated or dropped; the result may differ from the source.
        case warning
    }

    /// Stable machine-readable identifier of the kind of issue.
    public enum Code: String, Hashable, Sendable, Codable, CaseIterable {
        case unsupportedVersion
        case unresolvedReference
        case missingOwner
        case missingSecurity
        case unknownTransactionType
        case incompleteCrossEntry
        case approximatedTransaction
        case negativeValue
        case invalidValue
        case ignoredUnits
        case unknownQuoteFeed
        case approximatedQuoteFeed
        case approximatedPlan
        case skippedPlan
        case skippedAssignment
        case skippedDashboards
        case skippedAttribute
        case skippedSettings
        case skippedDocumentReference
        case skippedExDate
        case skippedEvent
        case orphanedObject
        case duplicateObject
        case exchangeRateSecurity
        case notExportable
    }

    public var severity: Severity
    public var code: Code
    /// Human-readable, self-contained description.
    public var message: String
    public var count: Int
    /// Up to five concrete occurrences (names, dates, line numbers).
    public var examples: [String]

    public init(severity: Severity = .warning, code: Code, message: String, count: Int = 1, examples: [String] = []) {
        self.severity = severity
        self.code = code
        self.message = message
        self.count = count
        self.examples = examples
    }

    /// Stable identity for lists: within one report, `code` + `message` is unique (repeats are merged into `count`).
    public var id: String { code.rawValue + "|" + message }

    public var description: String {
        var text = count > 1 ? "\(message) (\(count)×)" : message
        if !examples.isEmpty { text += " — e.g. " + examples.joined(separator: "; ") }
        return text
    }
}

/// Outcome of an import: what was read and what could not be represented exactly.
public struct ImportReport: Hashable, Sendable, Codable {
    public struct Counts: Hashable, Sendable, Codable {
        public var securities = 0
        /// Total number of historical prices over all securities.
        public var prices = 0
        public var securityEvents = 0
        public var accounts = 0
        public var depots = 0
        public var transactions = 0
        public var transactionsByKind: [Transaction.Kind: Int] = [:]
        public var taxonomies = 0
        public var classifications = 0
        public var assignments = 0
        public var watchlists = 0
        public var plans = 0
        public var exchangeRateSeries = 0
        public init() {}
    }

    /// e.g. "Portfolio Performance XML".
    public var sourceFormat: String
    /// The file-format version declared by the source (PP's `<version>`), if any.
    public var sourceVersion: Int?
    public var counts: Counts
    public var warnings: [ImportWarning]

    public init(sourceFormat: String, sourceVersion: Int? = nil, counts: Counts = Counts(), warnings: [ImportWarning] = []) {
        self.sourceFormat = sourceFormat
        self.sourceVersion = sourceVersion
        self.counts = counts
        self.warnings = warnings
    }

    /// True when nothing was approximated or dropped (informational notes are allowed).
    public var isLossless: Bool { !warnings.contains { $0.severity == .warning } }

    /// A short multi-line summary suitable for showing after an import.
    public var summary: String {
        var lines = ["\(sourceFormat)\(sourceVersion.map { " (version \($0))" } ?? "")"]
        lines.append("\(counts.securities) securities with \(counts.prices) prices, \(counts.accounts) accounts, \(counts.depots) depots, \(counts.transactions) transactions")
        lines.append("\(counts.taxonomies) taxonomies, \(counts.watchlists) watchlists, \(counts.plans) plans")
        for warning in warnings { lines.append((warning.severity == .warning ? "Warning: " : "Note: ") + warning.description) }
        return lines.joined(separator: "\n")
    }
}

/// Collects warnings, merging repeated occurrences of the same issue.
struct WarningCollector {
    private var order: [String] = []
    private var byKey: [String: ImportWarning] = [:]

    mutating func add(_ code: ImportWarning.Code, _ message: String, example: String? = nil, severity: ImportWarning.Severity = .warning) {
        let key = code.rawValue + "|" + message
        if var existing = byKey[key] {
            existing.count += 1
            if let example, existing.examples.count < 5, !existing.examples.contains(example) { existing.examples.append(example) }
            byKey[key] = existing
        } else {
            order.append(key)
            byKey[key] = ImportWarning(severity: severity, code: code, message: message, count: 1, examples: example.map { [$0] } ?? [])
        }
    }

    var warnings: [ImportWarning] { order.compactMap { byKey[$0] } }
}
