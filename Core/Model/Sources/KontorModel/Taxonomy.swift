import Foundation

/// A classification scheme (asset classes, regions, sectors, …) as a tree of `Classification`s.
public struct Taxonomy: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var root: [Classification]

    public init(id: UUID = UUID(), name: String, root: [Classification] = []) {
        self.id = id
        self.name = name
        self.root = root
    }
}

public struct Classification: Identifiable, Hashable, Codable, Sendable {
    /// Assigns (part of) a security or cash account to a classification.
    public struct Assignment: Hashable, Codable, Sendable {
        /// Exactly one of `securityID` / `accountID` is set.
        public var securityID: UUID?
        public var accountID: UUID?
        /// Share of the vehicle assigned here, in basis points (10_000 = 100 %).
        public var weight: Int

        public init(securityID: UUID? = nil, accountID: UUID? = nil, weight: Int = 10_000) {
            self.securityID = securityID
            self.accountID = accountID
            self.weight = weight
        }
    }

    public var id: UUID
    public var name: String
    /// "#RRGGBB"
    public var color: String
    /// Target allocation relative to the parent (or the whole portfolio for root nodes), in basis points. nil = no target.
    public var targetWeight: Int?
    public var note: String
    public var children: [Classification]
    public var assignments: [Assignment]

    public init(
        id: UUID = UUID(), name: String, color: String = "#8E8E93", targetWeight: Int? = nil, note: String = "",
        children: [Classification] = [], assignments: [Assignment] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.targetWeight = targetWeight
        self.note = note
        self.children = children
        self.assignments = assignments
    }
}
