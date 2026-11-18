import Foundation
import KontorModel

/// Blueprint of a classification node, shared by the demo and starter files.
struct ClassificationTemplate: Sendable {
    var name: String
    var color: String
    /// Target weight in basis points relative to the parent.
    var target: Int?
    var children: [ClassificationTemplate] = []

    init(_ name: String, _ color: String, target: Int? = nil, children: [ClassificationTemplate] = []) {
        self.name = name
        self.color = color
        self.target = target
        self.children = children
    }
}

enum Templates {
    static let assetClassesName = "Asset Classes"
    static let regionsName = "Regions"
    static let investmentTypeName = "Investment Type"

    static let assetClasses: [ClassificationTemplate] = [
        .init("Equity", "#3B82F6", target: 6000, children: [
            .init("Developed Markets", "#60A5FA", target: 7500),
            .init("Emerging Markets", "#1D4ED8", target: 2500),
        ]),
        .init("Bonds", "#14B8A6", target: 2000),
        .init("Commodities", "#EAB308", target: 500),
        .init("Real Estate", "#F97316", target: 500),
        .init("Crypto", "#A855F7", target: 200),
        .init("Cash", "#94A3B8", target: 800),
    ]

    static let regions: [ClassificationTemplate] = [
        .init("North America", "#6366F1"),
        .init("Europe", "#10B981"),
        .init("Asia-Pacific", "#F59E0B"),
        .init("Emerging Markets", "#EF4444"),
        .init("Global / Other", "#9CA3AF"),
    ]

    static let investmentTypes: [ClassificationTemplate] = [
        .init("Funds & ETFs", "#0EA5E9", children: [
            .init("Equity ETFs", "#38BDF8"),
            .init("Bond ETFs", "#2DD4BF"),
            .init("Real Estate Funds", "#FB923C"),
            .init("Commodity ETCs", "#FACC15"),
        ]),
        .init("Single Stocks", "#EC4899"),
        .init("Crypto Assets", "#8B5CF6"),
        .init("Indices", "#64748B"),
        .init("Cash Accounts", "#A3A3A3"),
    ]

    /// Instantiates a taxonomy. `assignments` maps node names to their assignments; ids are drawn
    /// from `nextID` in a fixed order (taxonomy first, then nodes depth-first).
    static func taxonomy(
        name: String, nodes: [ClassificationTemplate], targets: Bool,
        assignments: [String: [Classification.Assignment]] = [:], nextID: () -> UUID
    ) -> Taxonomy {
        func build(_ template: ClassificationTemplate) -> Classification {
            let id = nextID()
            return Classification(
                id: id, name: template.name, color: template.color, targetWeight: targets ? template.target : nil,
                children: template.children.map(build), assignments: assignments[template.name] ?? []
            )
        }
        let id = nextID()
        return Taxonomy(id: id, name: name, root: nodes.map(build))
    }

    /// The default dashboard. Widget kinds are generic identifiers; the app owns the final catalogue.
    static func dashboard(allocationTaxonomy: UUID?, benchmark: UUID? = nil, nextID: () -> UUID) -> Dashboard {
        let id = nextID()
        var chart = ["period": "max"]
        if let benchmark { chart["benchmark"] = benchmark.uuidString }
        let allocation = allocationTaxonomy.map { ["taxonomy": $0.uuidString] } ?? [:]
        let widgets: [(kind: String, title: String, span: Int, config: [String: String])] = [
            ("total-value", "Net Worth", 1, [:]),
            ("ttwror", "Time-Weighted Return", 1, ["period": "max"]),
            ("irr", "Internal Rate of Return", 1, ["period": "max"]),
            ("max-drawdown", "Max Drawdown", 1, ["period": "max"]),
            ("performance-chart", "Performance", 4, chart),
            ("allocation", "Allocation", 2, allocation),
            ("earnings", "Dividends & Interest", 2, ["grouping": "year"]),
            ("top-movers", "Top Movers", 2, ["period": "1m"]),
        ]
        return Dashboard(id: id, name: "Overview", widgets: widgets.map {
            Dashboard.Widget(id: nextID(), kind: $0.kind, title: $0.title, span: $0.span, config: $0.config)
        })
    }
}
