import Foundation
import KontorModel

/// A non-fatal problem encountered while indexing or calculating. The engine never traps on bad
/// or incomplete data; instead the affected value is excluded (counted as zero) and a diagnostic
/// is attached to the result so the UI can flag it.
public enum EngineDiagnostic: Hashable, Sendable, CustomStringConvertible {
    /// No exchange rate (direct, inverse or triangulated) exists between the two currencies.
    /// Amounts in `from` are excluded from totals in `to`.
    case missingExchangeRate(from: CurrencyCode, to: CurrencyCode)
    /// The security has no quotes and none could be derived; its positions are valued at zero.
    case missingPrice(securityID: UUID)
    /// The security has no quotes; prices were derived from its buy/sell transactions instead.
    case pricesDerivedFromTransactions(securityID: UUID)
    /// The transaction references an unknown or missing account/depot/security and was ignored.
    case invalidTransaction(transactionID: UUID, reason: String)
    /// More shares were removed than held; the position went short on `day`.
    case shortPosition(securityID: UUID, depotID: UUID, day: Day)

    public var description: String {
        switch self {
        case .missingExchangeRate(let from, let to):
            return "No exchange rate \(from) → \(to); affected amounts are excluded."
        case .missingPrice(let id):
            return "Security \(id) has no prices; its positions are valued at zero."
        case .pricesDerivedFromTransactions(let id):
            return "Security \(id) has no quotes; prices were derived from its transactions."
        case .invalidTransaction(let id, let reason):
            return "Transaction \(id) ignored: \(reason)."
        case .shortPosition(let security, let depot, let day):
            return "Security \(security) in depot \(depot) was oversold on \(day)."
        }
    }
}

/// Order-preserving, de-duplicating diagnostic sink.
struct DiagnosticCollector: Sendable {
    private var seen = Set<EngineDiagnostic>()
    private(set) var items: [EngineDiagnostic] = []

    init() {}
    init(_ initial: [EngineDiagnostic]) { for d in initial { add(d) } }

    mutating func add(_ diagnostic: EngineDiagnostic) {
        if seen.insert(diagnostic).inserted { items.append(diagnostic) }
    }
    mutating func add(contentsOf other: [EngineDiagnostic]) { for d in other { add(d) } }
}
