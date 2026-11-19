import SwiftUI
import KontorModel
import KontorEngine

/// The toolbar control for the global reporting period (`store.period`). The shell already places
/// one in the window toolbar; use it elsewhere only for screen-local overrides via the binding initialiser.
///
/// Toolbar items are hosted outside the screen's view tree: pass the store there
/// (`PeriodPicker(store: store)`). Without a store the picker renders nothing instead of trapping.
public struct PeriodPicker: View {
    @Environment(PortfolioStore.self) private var environmentStore: PortfolioStore?
    private let explicitStore: PortfolioStore?
    private let external: Binding<ReportingPeriod>?

    /// Bound to the store's global period.
    public init(store: PortfolioStore? = nil) {
        explicitStore = store
        external = nil
    }

    /// Bound to a local period (e.g. a per-widget override).
    public init(selection: Binding<ReportingPeriod>, store: PortfolioStore? = nil) {
        explicitStore = store
        external = selection
    }

    public var body: some View {
        if let store = explicitStore ?? environmentStore {
            PeriodPickerMenu(store: store, external: external)
        }
    }
}

private struct PeriodPickerMenu: View {
    let store: PortfolioStore
    let external: Binding<ReportingPeriod>?
    @State private var isCustomPresented = false

    private var selection: ReportingPeriod {
        get { external?.wrappedValue ?? store.period }
        nonmutating set {
            if let external { external.wrappedValue = newValue } else { store.period = newValue }
        }
    }

    var body: some View {
        Menu {
            Section("Recent") {
                ForEach(ReportingPeriod.presets.filter { $0 != .ytd && $0 != .allTime }, id: \.self) { period in
                    item(period)
                }
            }
            Section("To Date") {
                item(.monthToDate)
                item(.quarterToDate)
                item(.ytd)
                item(.allTime)
            }
            Section("Calendar Year") {
                ForEach(calendarYears, id: \.self) { year in
                    item(.year(year))
                }
            }
            Divider()
            Button("Custom Range…") { isCustomPresented = true }
        } label: {
            Label {
                Text(selection.shortTitle).numeric()
            } icon: {
                Image(systemName: "calendar")
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Reporting period: \(selection.title) (\(Fmt.interval(store.interval(for: selection))))")
        .accessibilityLabel("Reporting period")
        .accessibilityValue(selection.title)
        .popover(isPresented: $isCustomPresented, arrowEdge: .bottom) {
            // The editor shows the days the period covers; the engine's `custom(from:)` is the
            // baseline day before the first of them.
            let current = store.interval(for: selection)
            CustomRangeEditor(initial: min(current.firstDay, current.end)...current.end) { range in
                selection = .custom(from: range.lowerBound.advanced(by: -1), to: range.upperBound)
            }
        }
    }

    private func item(_ period: ReportingPeriod) -> some View {
        Toggle(period.title, isOn: Binding(
            get: { selection == period },
            set: { if $0 { selection = period } }
        ))
    }

    /// The running year and up to five previous ones, not reaching before the first transaction.
    private var calendarYears: [Int] {
        let current = store.today.year
        let first = max(store.inception?.year ?? current, current - 5)
        return Array((first...current).reversed())
    }
}

private struct CustomRangeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var from: Day
    @State private var to: Day
    let apply: (ClosedRange<Day>) -> Void

    init(initial: ClosedRange<Day>, apply: @escaping (ClosedRange<Day>) -> Void) {
        _from = State(initialValue: initial.lowerBound)
        _to = State(initialValue: initial.upperBound)
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Custom Range").font(.headline)
            Text("First and last day included in the period.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    DayField("From", day: $from)
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    DayField("To", day: $to)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply(min(from, to)...max(from, to))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 280)
    }
}
