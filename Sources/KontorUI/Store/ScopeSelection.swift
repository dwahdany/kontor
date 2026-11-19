import Foundation
import KontorModel
import KontorEngine

/// What part of the portfolio a window looks at — the user-facing counterpart of the engine's
/// `Scope`. Stored per window in `PortfolioStore.scopeSelection` and edited with `ScopePicker`.
///
/// ```swift
/// store.scopeSelection = .depot(depotID)
/// store.scope                 // engine Scope for calculations (falls back to .portfolio)
/// store.scopeTitle            // "Main Depot"
/// ```
public enum ScopeSelection: Hashable, Codable, Sendable {
    /// Everything in the file.
    case portfolio
    /// The securities held in one depot (no cash).
    case depot(UUID)
    /// One cash account.
    case account(UUID)
    /// Everything assigned to a classification of a taxonomy (including its sub-classifications),
    /// weighted by the assignments.
    case classification(taxonomy: UUID, id: UUID)

    /// The engine scope, or nil if the selection refers to something that no longer exists.
    public func resolve(in file: PortfolioFile) -> Scope? {
        switch self {
        case .portfolio:
            return .portfolio
        case .depot(let id):
            return file.depots.contains { $0.id == id } ? .depot(id) : nil
        case .account(let id):
            return file.accounts.contains { $0.id == id } ? .account(id) : nil
        case .classification(let taxonomyID, let id):
            return file.taxonomies.first { $0.id == taxonomyID }?.scope(forClassification: id)
        }
    }

    /// Display name: "Whole Portfolio", the depot's or account's name, "Asset Classes ▸ Equity".
    public func title(in file: PortfolioFile) -> String {
        switch self {
        case .portfolio:
            return "Whole Portfolio"
        case .depot(let id):
            return file.depots.first { $0.id == id }?.name ?? "Whole Portfolio"
        case .account(let id):
            return file.accounts.first { $0.id == id }?.name ?? "Whole Portfolio"
        case .classification(let taxonomyID, let id):
            guard let taxonomy = file.taxonomies.first(where: { $0.id == taxonomyID }),
                  let classification = taxonomy.classification(id) else { return "Whole Portfolio" }
            return "\(taxonomy.name) ▸ \(classification.name)"
        }
    }

    /// SF Symbol for menus and chips.
    public var symbol: String {
        switch self {
        case .portfolio: "square.stack.3d.up"
        case .depot: "briefcase"
        case .account: "creditcard"
        case .classification: "chart.pie"
        }
    }

    /// Compact text form used by scene storage and `--scope`: `portfolio`, `depot:<uuid>`,
    /// `account:<uuid>`, `classification:<taxonomy uuid>/<classification uuid>`.
    public var stringValue: String {
        switch self {
        case .portfolio: "portfolio"
        case .depot(let id): "depot:\(id.uuidString)"
        case .account(let id): "account:\(id.uuidString)"
        case .classification(let taxonomy, let id): "classification:\(taxonomy.uuidString)/\(id.uuidString)"
        }
    }

    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        if text == "portfolio" || text.isEmpty {
            self = .portfolio
            return
        }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let value = text[text.index(after: colon)...]
        switch text[..<colon] {
        case "depot":
            guard let id = UUID(uuidString: String(value)) else { return nil }
            self = .depot(id)
        case "account":
            guard let id = UUID(uuidString: String(value)) else { return nil }
            self = .account(id)
        case "classification":
            let parts = value.split(separator: "/")
            guard parts.count == 2, let taxonomy = UUID(uuidString: String(parts[0])), let id = UUID(uuidString: String(parts[1])) else { return nil }
            self = .classification(taxonomy: taxonomy, id: id)
        default:
            return nil
        }
    }
}

extension Taxonomy {
    /// All classifications depth-first, with their depth (0 = root level).
    public var flattened: [(classification: Classification, depth: Int)] {
        var result: [(Classification, Int)] = []
        func visit(_ nodes: [Classification], _ depth: Int) {
            for node in nodes {
                result.append((node, depth))
                visit(node.children, depth + 1)
            }
        }
        visit(root, 0)
        return result
    }
}

extension PortfolioStore {
    /// The engine scope of `scopeSelection`; `.portfolio` if the selected depot, account or
    /// classification no longer exists.
    public var scope: Scope { scopeSelection.resolve(in: file) ?? .portfolio }

    /// The scope's display name ("Whole Portfolio", "Main Depot", "Asset Classes ▸ Equity").
    public var scopeTitle: String { scopeSelection.title(in: file) }

    /// False when the window is narrowed to a depot, an account or a classification.
    public var isWholePortfolioScope: Bool { scope == .portfolio }
}
