import Foundation

/// A cash account (bank account, broker settlement account). Holds money in one currency.
public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var currency: CurrencyCode
    public var note: String
    public var isRetired: Bool

    public init(id: UUID = UUID(), name: String, currency: CurrencyCode, note: String = "", isRetired: Bool = false) {
        self.id = id
        self.name = name
        self.currency = currency
        self.note = note
        self.isRetired = isRetired
    }
}

/// A securities account (custody account / "Depot"). Holds share positions.
public struct Depot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// The cash account that buys/sells in this depot settle against by default.
    public var referenceAccountID: UUID?
    public var note: String
    public var isRetired: Bool

    public init(id: UUID = UUID(), name: String, referenceAccountID: UUID? = nil, note: String = "", isRetired: Bool = false) {
        self.id = id
        self.name = name
        self.referenceAccountID = referenceAccountID
        self.note = note
        self.isRetired = isRetired
    }
}
