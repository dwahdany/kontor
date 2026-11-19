import SwiftUI
import KontorUI

/// View state of the Allocation screen that has to be reachable from outside the screen's view
/// hierarchy: palette commands switch the tab, the inspector and the review sheet need the taxonomy
/// and the rebalancing inputs. One session per `PortfolioStore` (= per window), kept weakly.
@MainActor @Observable
final class AllocationSession {
    enum Tab: String, CaseIterable, Identifiable {
        case allocation, edit, rebalancing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .allocation: "Allocation"
            case .edit: "Edit"
            case .rebalancing: "Rebalancing"
            }
        }
    }

    enum Visual: String, CaseIterable, Identifiable {
        case donut, sunburst, treemap, bars
        var id: String { rawValue }
        var title: String {
            switch self {
            case .donut: "Donut"
            case .sunburst: "Sunburst"
            case .treemap: "Treemap"
            case .bars: "Target vs. Actual"
            }
        }
        var symbol: String {
            switch self {
            case .donut: "chart.pie"
            case .sunburst: "circle.circle"
            case .treemap: "rectangle.split.2x2"
            case .bars: "chart.bar.xaxis"
            }
        }
    }

    enum ProposalMode: String, CaseIterable, Identifiable {
        case classes, orders
        var id: String { rawValue }
        var title: String { self == .classes ? "By Classification" : "By Security" }
    }

    var tab = Tab.allocation
    var visual = Visual.donut
    /// The taxonomy the user picked; resolved against the file by `taxonomy(in:)`.
    var taxonomyID: UUID?
    /// Rebalancing inputs per taxonomy: cash, options and exclusions typed for one taxonomy never
    /// apply to another.
    private var rebalancingInputs: [UUID: RebalancingInputs] = [:]
    var proposalMode = ProposalMode.classes
    /// Selected classification in the Edit tab (shared so "Edit Classification" can reveal it).
    var editSelection: UUID?

    /// True once the window's stored state (scene storage) has been applied to this session.
    var isRestored = false
    /// A command chose the tab explicitly; restoring the stored tab must not override it.
    var hasExplicitTab = false
    /// The focus this screen last reported itself (`setFocus`), to tell its own selection changes
    /// from navigation that arrives from elsewhere.
    private(set) var ownFocus: Route.Focus?

    func inputs(for taxonomy: UUID) -> RebalancingInputs { rebalancingInputs[taxonomy] ?? RebalancingInputs() }

    func setInputs(_ inputs: RebalancingInputs, for taxonomy: UUID) {
        if inputs == RebalancingInputs() { rebalancingInputs[taxonomy] = nil } else { rebalancingInputs[taxonomy] = inputs }
    }

    /// Reports the screen's own selection (the inspector follows) without it counting as a deep link.
    func setFocus(_ focus: Route.Focus?, in store: PortfolioStore) {
        ownFocus = focus
        store.setFocus(focus)
    }

    /// Reacts to the route's focus. A classification that this screen did not select itself is a
    /// deep link (Dashboard slice, Securities): it must be selected and revealed, which the
    /// Allocation tab does — so Edit and Rebalancing give way to it. Returns true if the focus came
    /// from outside.
    @discardableResult
    func adopt(route focus: Route.Focus?, in file: PortfolioFile) -> Bool {
        guard focus != ownFocus else { return false }
        ownFocus = focus
        switch focus {
        case .taxonomy(let id):
            if file.taxonomies.contains(where: { $0.id == id }) { taxonomyID = id }
        case .classification(let taxonomy, let id):
            guard let match = file.taxonomies.first(where: { $0.id == taxonomy }) else { return true }
            taxonomyID = taxonomy
            if match.contains(id) { tab = .allocation }
        default:
            break
        }
        return true
    }

    /// The selected taxonomy, or the first one if the selection is gone.
    func taxonomy(in file: PortfolioFile) -> Taxonomy? {
        file.taxonomies.first { $0.id == taxonomyID } ?? file.taxonomies.first
    }

    // MARK: Per-store lookup

    private struct Entry {
        weak var store: PortfolioStore?
        let session: AllocationSession
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func session(for store: PortfolioStore) -> AllocationSession {
        let key = ObjectIdentifier(store)
        if let entry = entries[key], entry.store === store { return entry.session }
        entries = entries.filter { $0.value.store != nil }
        let session = AllocationSession()
        entries[key] = Entry(store: store, session: session)
        return session
    }
}

/// What the user typed into the Rebalancing tab. Hashable + Sendable: it is the cache key of the
/// proposal.
struct RebalancingInputs: Hashable, Sendable {
    enum Direction: String, Hashable, Sendable, CaseIterable, Identifiable {
        case invest, withdraw
        var id: String { rawValue }
        var title: String { self == .invest ? "Invest" : "Withdraw" }
    }

    /// Magnitude in minor units of the reporting currency.
    var amount: Int64 = 0
    var direction = Direction.invest
    var buyOnly = false
    var wholeShares = true
    var excludedClassifications: Set<UUID> = []
    var excludedVehicles: Set<AllocationVehicle> = []

    /// Signed cash for the engine: > 0 invests, < 0 withdraws.
    var cash: Int64 { direction == .invest ? amount : -amount }

    var options: RebalancingOptions {
        RebalancingOptions(cash: cash, mode: buyOnly ? .noSales : .buyAndSell, wholeShares: wholeShares)
    }

    var hasExclusions: Bool { !excludedClassifications.isEmpty || !excludedVehicles.isEmpty }
    var exclusionCount: Int { excludedClassifications.count + excludedVehicles.count }

    /// The inputs with only those exclusions that exist in `taxonomy` — ids of deleted
    /// classifications or of vehicles that are no longer assigned do not count.
    func sanitized(for taxonomy: Taxonomy) -> RebalancingInputs {
        guard hasExclusions else { return self }
        var copy = self
        let classifications = Set(taxonomy.flattened.map(\.classification.id))
        copy.excludedClassifications.formIntersection(classifications)
        copy.excludedVehicles.formIntersection(taxonomy.assignedWeights.keys)
        return copy
    }

    /// Checks or unchecks a classification. Checking it also clears every exclusion below it, so a
    /// classification that was frozen because everything inside was excluded takes part again.
    mutating func setIncluded(_ included: Bool, classification id: UUID, in taxonomy: Taxonomy) {
        guard included else {
            excludedClassifications.insert(id)
            return
        }
        guard let node = taxonomy.classification(id) else {
            excludedClassifications.remove(id)
            return
        }
        func visit(_ node: Classification) {
            excludedClassifications.remove(node.id)
            for a in node.assignments { if let vehicle = AllocationVehicle(a) { excludedVehicles.remove(vehicle) } }
            node.children.forEach(visit)
        }
        visit(node)
    }

    // Text form for the review sheet's payload.
    var payload: [String: String] {
        [
            "amount": String(amount), "direction": direction.rawValue, "buyOnly": buyOnly ? "1" : "0",
            "wholeShares": wholeShares ? "1" : "0",
            "excludedClasses": excludedClassifications.map(\.uuidString).sorted().joined(separator: ","),
            "excludedVehicles": excludedVehicles.map(\.token).sorted().joined(separator: ","),
        ]
    }

    init() {}

    init(payload: [String: String]) {
        amount = payload["amount"].flatMap(Int64.init) ?? 0
        direction = payload["direction"].flatMap(Direction.init(rawValue:)) ?? .invest
        buyOnly = payload["buyOnly"] == "1"
        wholeShares = payload["wholeShares"] != "0"
        excludedClassifications = Set((payload["excludedClasses"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        excludedVehicles = Set((payload["excludedVehicles"] ?? "").split(separator: ",").compactMap { AllocationVehicle(token: String($0)) })
    }
}
