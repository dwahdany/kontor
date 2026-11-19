import SwiftUI
import KontorModel
import KontorEngine

// Bridges from engine results to chart inputs. All of them are pure and `Sendable`-friendly:
// call them inside `analysisTask` / `store.analyze` and hand the result to the view.

extension ChartNode {
    /// A classification with its sub-classifications — and, with `includesItems`, the securities
    /// and accounts assigned to it as leaves. Ids are the classification UUID strings (items:
    /// `"<classification>/<vehicle>"`); colors come from the classification's stored color,
    /// adjusted for legibility.
    public init(_ node: AllocationNode, fallbackColorIndex: Int = Int.max, includesItems: Bool = false, changes: [UUID: Double] = [:]) {
        var children = node.children.enumerated().map { i, child in
            // Sub-classifications are tints of their parent unless they are top level.
            ChartNode(child, fallbackColorIndex: i, includesItems: includesItems, changes: changes).tinted()
        }
        if includesItems {
            children += node.items.filter { $0.value > 0 }.map { item in
                ChartNode(item.name, id: "\(node.id.uuidString)/\(item.vehicle.id.uuidString)", value: Double(item.value), change: changes[item.vehicle.id])
            }
        }
        self.init(node.name, id: node.id.uuidString, value: Double(node.value),
                  color: ChartColors.classification(node.color, fallbackIndex: fallbackColorIndex), children: children)
    }

    /// Drops the explicit color so the chart derives a tint from the parent.
    func tinted() -> ChartNode {
        var copy = self
        copy.color = nil
        return copy
    }

    /// The top-level nodes of a taxonomy allocation, largest first, plus a gray "Unassigned" node
    /// for what the taxonomy does not classify.
    ///
    /// - Parameters:
    ///   - includesItems: adds the assigned securities / accounts as leaves (treemaps).
    ///   - changes: performance per security id (e.g. `SecurityPerformance.ttwror`) for
    ///     `TreemapChart(coloring: .performance)`.
    public static func nodes(
        from allocation: TaxonomyAllocation, includesItems: Bool = false, changes: [UUID: Double] = [:], unassignedName: String = "Unassigned"
    ) -> [ChartNode] {
        var nodes = allocation.roots.enumerated().filter { $0.element.value > 0 }.map { i, root in
            ChartNode(root, fallbackColorIndex: i, includesItems: includesItems, changes: changes)
        }
        if allocation.unassignedValue > 0 {
            let items = includesItems ? allocation.unassigned.filter { $0.value > 0 }.map { item in
                ChartNode(item.name, id: "unassigned/\(item.vehicle.id.uuidString)", value: Double(item.value), change: changes[item.vehicle.id])
            } : []
            nodes.append(ChartNode(unassignedName, id: "chart.unassigned", value: Double(allocation.unassignedValue), color: ChartColors.other, children: items))
        }
        return nodes
    }
}

extension ChartSlice {
    /// The top level of a taxonomy allocation as donut slices (plus "Unassigned"), folded to
    /// eight parts.
    public static func slices(from allocation: TaxonomyAllocation, unassignedName: String = "Unassigned") -> [ChartSlice] {
        var slices = allocation.roots.enumerated().filter { $0.element.value > 0 }.map { i, root in
            ChartSlice(id: root.id.uuidString, root.name, value: Double(root.value), color: ChartColors.classification(root.color, fallbackIndex: i))
        }
        if allocation.unassignedValue > 0 {
            slices.append(ChartSlice(id: "chart.unassigned", unassignedName, value: Double(allocation.unassignedValue), color: ChartColors.other))
        }
        return folded(slices)
    }
}

extension ChartMarker {
    /// Markers for the transactions of a security: buys and inbound deliveries ▲, sales and
    /// outbound deliveries ▼, dividends ◆ (on the time axis). Other kinds are skipped. Ids are the
    /// transaction UUID strings.
    public static func markers(for transactions: [KontorModel.Transaction]) -> [ChartMarker] {
        transactions.compactMap { t in
            switch t.kind {
            case .buy, .deliveryIn:
                ChartMarker(.buy, id: t.id.uuidString, day: t.date, label: "\(t.kind.title) \(Fmt.shares(t.shares)) · \(Fmt.money(t.amount))")
            case .sell, .deliveryOut:
                ChartMarker(.sell, id: t.id.uuidString, day: t.date, label: "\(t.kind.title) \(Fmt.shares(t.shares)) · \(Fmt.money(t.amount))")
            case .dividend:
                ChartMarker(.dividend, id: t.id.uuidString, day: t.date, label: "\(t.kind.title) · \(Fmt.money(t.amount))")
            default:
                nil
            }
        }
    }
}

extension BarCategory {
    /// One category per calendar month (engine `EarningsMonth`, `MonthReturn`): "Mar" within a
    /// single year, "Mar 2024" for longer ranges (the chart thins labels that do not fit).
    public static func months(_ months: [(year: Int, month: Int)]) -> [BarCategory] {
        let showsYear = months.count > 12
        return months.map { BarCategory.month(year: $0.year, month: $0.month, showsYear: showsYear) }
    }
}
