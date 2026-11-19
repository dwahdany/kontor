import Foundation
import KontorUI

// Pure editing operations on `Taxonomy` — everything the Edit tab does goes through these, wrapped
// in one `store.mutate` per user action. No engine math here: only tree surgery and the integer
// bookkeeping of weights (basis points, 10_000 = 100 %).

extension AllocationVehicle {
    init?(_ assignment: Classification.Assignment) {
        if let id = assignment.securityID {
            self = .security(id)
        } else if let id = assignment.accountID {
            self = .account(id)
        } else {
            return nil
        }
    }

    var assignment: Classification.Assignment {
        switch self {
        case .security(let id): Classification.Assignment(securityID: id, weight: 0)
        case .account(let id): Classification.Assignment(accountID: id, weight: 0)
        }
    }

    var isSecurity: Bool {
        if case .security = self { true } else { false }
    }

    /// Text form used for drag & drop and row ids: `s:<uuid>` / `a:<uuid>`.
    var token: String {
        switch self {
        case .security(let id): "s:\(id.uuidString)"
        case .account(let id): "a:\(id.uuidString)"
        }
    }

    init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "s": self = .security(id)
        case "a": self = .account(id)
        default: return nil
        }
    }
}

extension Classification.Assignment {
    func refers(to vehicle: AllocationVehicle) -> Bool {
        switch vehicle {
        case .security(let id): securityID == id
        case .account(let id): securityID == nil && accountID == id
        }
    }
}

/// Splits `total` into integer parts proportional to `weights` (largest remainder; exact sum).
func apportion(_ total: Int, weights: [Int]) -> [Int] {
    let sum = weights.reduce(0) { $0 + max($1, 0) }
    guard sum > 0, total > 0 else { return [Int](repeating: 0, count: weights.count) }
    var parts = weights.map { max($0, 0) * total / sum }
    let remainders = weights.enumerated().map { (index: $0, rest: (max($1, 0) * total) % sum) }
        .sorted { $0.rest != $1.rest ? $0.rest > $1.rest : $0.index < $1.index }
    var left = total - parts.reduce(0, +)
    for r in remainders where left > 0 {
        parts[r.index] += 1
        left -= 1
    }
    return parts
}

/// The state of the target weights among one group of siblings.
struct TargetGroupStatus: Equatable, Sendable {
    var count: Int
    var targeted: Int
    /// Sum of the stored targets in basis points.
    var sum: Int

    var hasTargets: Bool { targeted > 0 }
    var isComplete: Bool { !hasTargets || (sum == 10_000 && targeted == count) }
    /// What is missing to 100 % (negative: too much).
    var remainder: Int { 10_000 - sum }
}

extension Taxonomy {
    // MARK: Lookup

    /// The ids from the root down to `id` (inclusive); nil if unknown.
    func path(to id: UUID) -> [UUID]? {
        func find(_ nodes: [Classification], _ trail: [UUID]) -> [UUID]? {
            for node in nodes {
                let here = trail + [node.id]
                if node.id == id { return here }
                if let hit = find(node.children, here) { return hit }
            }
            return nil
        }
        return find(root, [])
    }

    /// The parent of a classification: `.some(nil)` for root nodes, `nil` if unknown.
    func parentID(of id: UUID) -> UUID?? {
        guard let path = path(to: id) else { return nil }
        return .some(path.count >= 2 ? path[path.count - 2] : nil)
    }

    func siblings(ofParent parent: UUID?) -> [Classification] {
        guard let parent else { return root }
        return classification(parent)?.children ?? []
    }

    var classificationCount: Int { flattened.count }

    func contains(_ id: UUID) -> Bool { path(to: id) != nil }

    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        guard let path = path(to: id) else { return false }
        return path.dropLast().contains(ancestor)
    }

    /// "Equity ▸ Developed Markets"
    func pathTitle(of id: UUID) -> String {
        guard let path = path(to: id) else { return "" }
        return path.compactMap { classification($0)?.name }.joined(separator: " ▸ ")
    }

    // MARK: Structural edits

    /// Applies `body` to the classification with `id`. Returns false if it does not exist.
    @discardableResult
    mutating func update(_ id: UUID, _ body: (inout Classification) -> Void) -> Bool {
        func visit(_ nodes: inout [Classification]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    body(&nodes[i])
                    return true
                }
                if visit(&nodes[i].children) { return true }
            }
            return false
        }
        return visit(&root)
    }

    private mutating func withSiblings(ofParent parent: UUID?, _ body: (inout [Classification]) -> Void) {
        if let parent {
            update(parent) { body(&$0.children) }
        } else {
            body(&root)
        }
    }

    /// Removes a classification with everything below it and returns it.
    @discardableResult
    mutating func remove(_ id: UUID) -> Classification? {
        func visit(_ nodes: inout [Classification]) -> Classification? {
            if let i = nodes.firstIndex(where: { $0.id == id }) { return nodes.remove(at: i) }
            for i in nodes.indices {
                if let hit = visit(&nodes[i].children) { return hit }
            }
            return nil
        }
        return visit(&root)
    }

    mutating func remove(_ ids: Set<UUID>) {
        for id in ids { remove(id) }
    }

    mutating func insert(_ node: Classification, parent: UUID?, at index: Int? = nil) {
        withSiblings(ofParent: parent) { siblings in
            siblings.insert(node, at: min(max(index ?? siblings.count, 0), siblings.count))
        }
    }

    /// Adds a new classification below `parent` (or after `sibling` on the same level). The color is
    /// the next palette color on that level.
    @discardableResult
    mutating func addClassification(named name: String = "New Classification", parent: UUID? = nil, after sibling: UUID? = nil) -> UUID {
        var parent = parent
        var index: Int?
        if let sibling, let found = parentID(of: sibling) {
            parent = found
            index = siblings(ofParent: found).firstIndex { $0.id == sibling }.map { $0 + 1 }
        }
        let level = siblings(ofParent: parent)
        let used = Set(level.map { $0.color.uppercased() })
        let color = (0..<CategoryPalette.count).map(CategoryPalette.hex).first { !used.contains($0.uppercased()) }
            ?? CategoryPalette.hex(level.count % max(CategoryPalette.count, 1))
        let node = Classification(name: uniqueName(name, among: level.map(\.name)), color: color)
        insert(node, parent: parent, at: index)
        return node.id
    }

    /// Moves a classification (with its subtree) below `parent` (nil = top level). Refuses to move a
    /// node into itself or one of its descendants.
    @discardableResult
    mutating func move(_ id: UUID, toParent parent: UUID?, at index: Int? = nil) -> Bool {
        if let parent {
            guard parent != id, !isDescendant(parent, of: id), contains(parent) else { return false }
        }
        guard let node = remove(id) else { return false }
        insert(node, parent: parent, at: index)
        return true
    }

    /// Makes the classification the last child of the sibling above it.
    @discardableResult
    mutating func indent(_ id: UUID) -> Bool {
        guard let parent = parentID(of: id) else { return false }
        let level = siblings(ofParent: parent)
        guard let i = level.firstIndex(where: { $0.id == id }), i > 0 else { return false }
        return move(id, toParent: level[i - 1].id)
    }

    /// Moves the classification one level up, right after its former parent.
    @discardableResult
    mutating func outdent(_ id: UUID) -> Bool {
        guard let parent = parentID(of: id), let parent, let grandparent = parentID(of: parent) else { return false }
        let index = siblings(ofParent: grandparent).firstIndex { $0.id == parent }.map { $0 + 1 }
        return move(id, toParent: grandparent, at: index)
    }

    func canIndent(_ id: UUID) -> Bool {
        guard let parent = parentID(of: id) else { return false }
        return siblings(ofParent: parent).first?.id != id
    }

    func canOutdent(_ id: UUID) -> Bool {
        if let parent = parentID(of: id), parent != nil { return true }
        return false
    }

    /// Moves the classification among its siblings by `offset` positions (−1 = up).
    @discardableResult
    mutating func shift(_ id: UUID, by offset: Int) -> Bool {
        guard let parent = parentID(of: id) else { return false }
        var moved = false
        withSiblings(ofParent: parent) { siblings in
            guard let i = siblings.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard siblings.indices.contains(j) else { return }
            siblings.swapAt(i, j)
            moved = true
        }
        return moved
    }

    // MARK: Target weights

    func targetStatus(ofParent parent: UUID?, overrides: [UUID: Int?] = [:]) -> TargetGroupStatus {
        let level = siblings(ofParent: parent)
        let targets = level.map { node in overrides[node.id] ?? node.targetWeight }
        return TargetGroupStatus(count: level.count, targeted: targets.count { $0 != nil }, sum: targets.reduce(0) { $0 + max($1 ?? 0, 0) })
    }

    /// Scales the targets of one sibling group proportionally so that they sum to 100 %. Siblings
    /// without a target get 0 %.
    mutating func normalizeTargets(ofParent parent: UUID?) {
        withSiblings(ofParent: parent) { siblings in
            let weights = siblings.map { max($0.targetWeight ?? 0, 0) }
            guard weights.contains(where: { $0 > 0 }) else { return }
            let parts = apportion(10_000, weights: weights)
            for i in siblings.indices { siblings[i].targetWeight = parts[i] }
        }
    }

    /// Spreads what is missing to 100 % equally over the siblings without a target — or, if every
    /// sibling has one (or the group is over 100 %), equally over all of them.
    mutating func distributeRemainder(ofParent parent: UUID?) {
        withSiblings(ofParent: parent) { siblings in
            guard !siblings.isEmpty else { return }
            let sum = siblings.reduce(0) { $0 + max($1.targetWeight ?? 0, 0) }
            let remainder = 10_000 - sum
            guard remainder != 0 else {
                for i in siblings.indices where siblings[i].targetWeight == nil { siblings[i].targetWeight = 0 }
                return
            }
            let open = siblings.indices.filter { siblings[$0].targetWeight == nil }
            if remainder > 0, !open.isEmpty {
                let parts = apportion(remainder, weights: [Int](repeating: 1, count: open.count))
                for (n, i) in open.enumerated() { siblings[i].targetWeight = parts[n] }
            } else if remainder > 0 {
                let parts = apportion(remainder, weights: [Int](repeating: 1, count: siblings.count))
                for i in siblings.indices { siblings[i].targetWeight = max(siblings[i].targetWeight ?? 0, 0) + parts[i] }
            } else {
                // Over 100 %: take the excess away in proportion to the current targets.
                let weights = siblings.map { max($0.targetWeight ?? 0, 0) }
                let cuts = apportion(-remainder, weights: weights)
                for i in siblings.indices { siblings[i].targetWeight = weights[i] - cuts[i] }
            }
        }
    }

    /// Gives every sibling of the group the same target.
    mutating func equalizeTargets(ofParent parent: UUID?) {
        withSiblings(ofParent: parent) { siblings in
            let parts = apportion(10_000, weights: [Int](repeating: 1, count: siblings.count))
            for i in siblings.indices { siblings[i].targetWeight = parts[i] }
        }
    }

    mutating func clearTargets(ofParent parent: UUID?) {
        withSiblings(ofParent: parent) { siblings in
            for i in siblings.indices { siblings[i].targetWeight = nil }
        }
    }

    var hasTargets: Bool { flattened.contains { $0.classification.targetWeight != nil } }

    // MARK: Assignments

    /// Every assignment of a vehicle: classification id + weight (basis points), in tree order.
    func assignments(of vehicle: AllocationVehicle) -> [(classification: UUID, weight: Int)] {
        flattened.flatMap { entry in
            entry.classification.assignments.filter { $0.refers(to: vehicle) }.map { (entry.classification.id, $0.weight) }
        }
    }

    func assignedWeight(of vehicle: AllocationVehicle) -> Int {
        assignments(of: vehicle).reduce(0) { $0 + max($1.weight, 0) }
    }

    /// What is not assigned yet, 0 … 10_000.
    func unassignedWeight(of vehicle: AllocationVehicle) -> Int { max(0, 10_000 - assignedWeight(of: vehicle)) }

    /// All vehicles that appear anywhere in the taxonomy with their total weight.
    var assignedWeights: [AllocationVehicle: Int] {
        var totals: [AllocationVehicle: Int] = [:]
        for entry in flattened {
            for a in entry.classification.assignments {
                guard let vehicle = AllocationVehicle(a) else { continue }
                totals[vehicle, default: 0] += max(a.weight, 0)
            }
        }
        return totals
    }

    /// Assigns `weight` of a vehicle to a classification (nil = whatever is still unassigned; if
    /// nothing is left, the vehicle is *moved* there completely). An existing assignment in the same
    /// classification is increased.
    @discardableResult
    mutating func assign(_ vehicle: AllocationVehicle, to classification: UUID, weight: Int? = nil) -> Bool {
        guard contains(classification) else { return false }
        var amount = weight ?? unassignedWeight(of: vehicle)
        if weight == nil, amount == 0 {
            removeAssignments(of: vehicle)
            amount = 10_000
        }
        guard amount > 0 else { return false }
        return update(classification) { node in
            if let i = node.assignments.firstIndex(where: { $0.refers(to: vehicle) }) {
                node.assignments[i].weight = min(10_000, node.assignments[i].weight + amount)
            } else {
                var a = vehicle.assignment
                a.weight = amount
                node.assignments.append(a)
            }
        }
    }

    /// Moves the part of a vehicle assigned to `source` over to `target`.
    mutating func moveAssignment(of vehicle: AllocationVehicle, from source: UUID, to target: UUID) {
        guard source != target, contains(target),
              let weight = classification(source)?.assignments.first(where: { $0.refers(to: vehicle) })?.weight else { return }
        unassign(vehicle, from: source)
        assign(vehicle, to: target, weight: weight)
    }

    mutating func unassign(_ vehicle: AllocationVehicle, from classification: UUID) {
        update(classification) { $0.assignments.removeAll { $0.refers(to: vehicle) } }
    }

    mutating func removeAssignments(of vehicle: AllocationVehicle) {
        func visit(_ nodes: inout [Classification]) {
            for i in nodes.indices {
                nodes[i].assignments.removeAll { $0.refers(to: vehicle) }
                visit(&nodes[i].children)
            }
        }
        visit(&root)
    }

    mutating func setWeight(_ weight: Int, of vehicle: AllocationVehicle, in classification: UUID) {
        update(classification) { node in
            if let i = node.assignments.firstIndex(where: { $0.refers(to: vehicle) }) {
                node.assignments[i].weight = min(max(weight, 0), 10_000)
            }
        }
    }

    /// Replaces all assignments of a vehicle by `parts` (zero-weight parts are dropped; several
    /// parts naming the same classification are merged).
    mutating func setSplit(of vehicle: AllocationVehicle, parts: [(classification: UUID, weight: Int)]) {
        removeAssignments(of: vehicle)
        for part in parts where part.weight > 0 {
            assign(vehicle, to: part.classification, weight: part.weight)
        }
    }

    /// A copy with fresh ids (taxonomy and every classification), for "Duplicate".
    func duplicated(named name: String) -> Taxonomy {
        func copy(_ node: Classification) -> Classification {
            var c = node
            c.id = UUID()
            c.children = node.children.map(copy)
            return c
        }
        return Taxonomy(name: name, root: root.map(copy))
    }
}

/// "Name", "Name 2", "Name 3", … — the first that is not taken.
func uniqueName(_ base: String, among existing: [String]) -> String {
    let taken = Set(existing.map { $0.lowercased() })
    guard taken.contains(base.lowercased()) else { return base }
    var n = 2
    while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
    return "\(base) \(n)"
}

// MARK: - Templates

/// The starting points offered by "New Taxonomy".
enum TaxonomyTemplate: String, CaseIterable, Identifiable, Sendable {
    case assetClasses, regions, sectors, investmentType, currency, empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assetClasses: "Asset Classes"
        case .regions: "Regions"
        case .sectors: "Sectors"
        case .investmentType: "Investment Type"
        case .currency: "Currency"
        case .empty: "Empty Taxonomy"
        }
    }

    var symbol: String {
        switch self {
        case .assetClasses: "chart.pie"
        case .regions: "globe.europe.africa"
        case .sectors: "building.2"
        case .investmentType: "square.stack.3d.up"
        case .currency: "dollarsign.circle"
        case .empty: "square.dashed"
        }
    }

    var summary: String {
        switch self {
        case .assetClasses: "Equity, bonds, commodities, real estate, cash — with a 60/20/20 starting target."
        case .regions: "North America, Europe, Asia-Pacific, emerging markets."
        case .sectors: "The eleven common equity sectors."
        case .investmentType: "Funds & ETFs, single stocks, crypto, cash accounts."
        case .currency: "One class per currency; securities and accounts are assigned automatically."
        case .empty: "Start from scratch."
        }
    }

    private struct Node {
        var name: String
        var target: Int?
        var children: [Node] = []
        init(_ name: String, _ target: Int? = nil, _ children: [Node] = []) {
            self.name = name
            self.target = target
            self.children = children
        }
    }

    private var nodes: [Node] {
        switch self {
        case .assetClasses:
            [Node("Equity", 6_000, [Node("Developed Markets", 7_500), Node("Emerging Markets", 2_500)]),
             Node("Bonds", 2_000), Node("Commodities", 500), Node("Real Estate", 500), Node("Cash", 1_000)]
        case .regions:
            ["North America", "Europe", "Asia-Pacific", "Emerging Markets", "Global / Other"].map { Node($0) }
        case .sectors:
            ["Technology", "Financials", "Health Care", "Consumer Discretionary", "Consumer Staples", "Industrials",
             "Energy", "Materials", "Utilities", "Real Estate", "Communication Services"].map { Node($0) }
        case .investmentType:
            [Node("Funds & ETFs", nil, [Node("Equity ETFs"), Node("Bond ETFs"), Node("Other Funds")]),
             Node("Single Stocks"), Node("Bonds"), Node("Crypto Assets"), Node("Cash Accounts")]
        case .currency, .empty:
            []
        }
    }

    /// Builds the taxonomy for `file` with a name that is not taken yet.
    func make(in file: PortfolioFile) -> Taxonomy {
        let name = uniqueName(self == .empty ? "New Taxonomy" : title, among: file.taxonomies.map(\.name))
        func build(_ node: Node, index: Int, parentColor: String?) -> Classification {
            // Top level: palette colors in order; below: the parent's color (charts tint children).
            let color = parentColor ?? (index < CategoryPalette.count ? CategoryPalette.hex(index) : "#8E8E93")
            return Classification(
                name: node.name, color: color, targetWeight: node.target,
                children: node.children.enumerated().map { build($1, index: $0, parentColor: color) })
        }
        var root = nodes.enumerated().map { build($1, index: $0, parentColor: nil) }
        if self == .currency {
            var codes: [CurrencyCode] = []
            for code in [file.settings.baseCurrency] + file.accounts.map(\.currency) + file.securities.map(\.currency) where !codes.contains(code) {
                codes.append(code)
            }
            root = codes.enumerated().map { index, code in
                Classification(
                    name: code, color: index < CategoryPalette.count ? CategoryPalette.hex(index) : "#8E8E93",
                    assignments: file.securities.filter { $0.currency == code }.map { Classification.Assignment(securityID: $0.id) }
                        + file.accounts.filter { $0.currency == code }.map { Classification.Assignment(accountID: $0.id) })
            }
        }
        return Taxonomy(name: name, root: root)
    }
}
