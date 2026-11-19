import SwiftUI
import KontorModel
import KontorEngine

/// "Last good value + is it being refreshed" — the state of an asynchronously derived screen model.
///
/// While a newer value is computed the previous one stays in `value`, so content never flashes or
/// collapses during recomputation. Use it with ``SwiftUICore/View/analysisTask(_:id:scope:interval:variant:_:)``
/// or ``SwiftUICore/View/ledgerTask(_:id:variant:_:)``:
///
/// ```swift
/// @State private var model = Loadable<HoldingsModel>()
///
/// var body: some View {
///     HoldingsContent(model: model.value)                      // nil only before the first result
///         .loadingOverlay(model.isInitialLoad)                 // spinner only when there is nothing to show
///         .opacity(model.isRefreshing ? 0.6 : 1)               // optional: dim stale content
///         .analysisTask($model, id: "holdings.model") { analysis in HoldingsModel(analysis) }
/// }
/// ```
public struct Loadable<Value> {
    /// The most recent successfully computed value.
    public var value: Value?
    /// True while a computation for newer inputs is running.
    public var isLoading: Bool
    /// The document revision `value` was computed from.
    public var revision: Int?

    public init(_ value: Value? = nil) {
        self.value = value
        isLoading = false
        revision = nil
    }

    /// Loading and nothing to show yet — the moment for a full-size progress indicator.
    public var isInitialLoad: Bool { isLoading && value == nil }
    /// Loading while an older value is still on screen.
    public var isRefreshing: Bool { isLoading && value != nil }

    /// Transforms the value, keeping the loading state.
    public func map<T>(_ transform: (Value) -> T) -> Loadable<T> {
        var result = Loadable<T>(value.map(transform))
        result.isLoading = isLoading
        result.revision = revision
        return result
    }
}

extension Loadable: Sendable where Value: Sendable {}
extension Loadable: Equatable where Value: Equatable {}

private struct AnalysisTaskInputs<Variant: Hashable & Sendable>: Hashable {
    var revision: Int
    var scope: Scope
    var interval: DayInterval?
    var variant: Variant
}

private struct AnalysisTaskModifier<Value: Sendable, Variant: Hashable & Sendable>: ViewModifier {
    @Environment(PortfolioStore.self) private var store
    @Binding var target: Loadable<Value>
    let id: String
    let scope: Scope?
    let interval: DayInterval?
    let variant: Variant
    let work: @Sendable (Analysis) throws -> Value

    func body(content: Content) -> some View {
        let scope = scope ?? store.scope, interval = interval ?? store.periodInterval
        content.task(id: AnalysisTaskInputs(revision: store.revision, scope: scope, interval: interval, variant: variant)) {
            let revision = store.revision
            if !target.isLoading { target.isLoading = true }
            do {
                let value = try await store.analyze(id, scope: scope, interval: interval, variant: variant, work)
                target = Loadable(value: value, revision: revision)
            } catch is CancellationError {
                // Superseded: the task for the new inputs owns `isLoading` now.
            } catch {
                target.isLoading = false
            }
        }
    }
}

private struct LedgerTaskModifier<Value: Sendable, Variant: Hashable & Sendable>: ViewModifier {
    @Environment(PortfolioStore.self) private var store
    @Binding var target: Loadable<Value>
    let id: String
    let variant: Variant
    let work: @Sendable (Ledger) throws -> Value

    func body(content: Content) -> some View {
        content.task(id: AnalysisTaskInputs(revision: store.revision, scope: .portfolio, interval: nil, variant: variant)) {
            let revision = store.revision
            if !target.isLoading { target.isLoading = true }
            do {
                let key = AnalysisRequestKey(id: id, scope: .portfolio, interval: nil, variant: variant)
                let value = try await store.compute(key, work)
                target = Loadable(value: value, revision: revision)
            } catch is CancellationError {
            } catch {
                target.isLoading = false
            }
        }
    }
}

extension Loadable {
    init(value: Value, revision: Int) {
        self.value = value
        self.revision = revision
        isLoading = false
    }
}

extension View {
    /// Keeps `target` up to date with a model derived from the shared engine ``Analysis``.
    ///
    /// Recomputes — off the main actor, through the store's analysis cache — whenever the document
    /// (`store.revision`), the scope, the interval or `variant` changes; the previous value stays in
    /// `target.value` meanwhile. Results are memoized under (`id`, scope, interval, `variant`), so
    /// returning to a screen or switching back to a period is instant.
    ///
    /// - Parameters:
    ///   - id: Names the computation, namespaced by feature: `"earnings.model"`.
    ///   - scope: `nil` follows the window's scope (`store.scope`).
    ///   - interval: `nil` follows the reporting period (`store.periodInterval`).
    ///   - variant: Any further `Hashable & Sendable` inputs of `work` (e.g. a taxonomy id).
    ///   - work: Pure, runs on a background thread. Touch every `analysis` property you need here —
    ///     they compute lazily on first access.
    public func analysisTask<Value: Sendable, Variant: Hashable & Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, scope: Scope? = nil, interval: DayInterval? = nil,
        variant: Variant, _ work: @escaping @Sendable (Analysis) throws -> Value
    ) -> some View {
        modifier(AnalysisTaskModifier(target: target, id: id, scope: scope, interval: interval, variant: variant, work: work))
    }

    /// ``analysisTask(_:id:scope:interval:variant:_:)`` without extra inputs.
    public func analysisTask<Value: Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, scope: Scope? = nil, interval: DayInterval? = nil,
        _ work: @escaping @Sendable (Analysis) throws -> Value
    ) -> some View {
        modifier(AnalysisTaskModifier(target: target, id: id, scope: scope, interval: interval, variant: NoVariant(), work: work))
    }

    /// Keeps `target` up to date with a model derived from the engine ``Ledger`` — for screens that
    /// depend on the document only (lists of securities, accounts, transactions), not on a scope
    /// or period. Same caching and "last good value" semantics as `analysisTask`.
    public func ledgerTask<Value: Sendable, Variant: Hashable & Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, variant: Variant,
        _ work: @escaping @Sendable (Ledger) throws -> Value
    ) -> some View {
        modifier(LedgerTaskModifier(target: target, id: id, variant: variant, work: work))
    }

    /// ``ledgerTask(_:id:variant:_:)`` without extra inputs.
    public func ledgerTask<Value: Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, _ work: @escaping @Sendable (Ledger) throws -> Value
    ) -> some View {
        modifier(LedgerTaskModifier(target: target, id: id, variant: NoVariant(), work: work))
    }
}
