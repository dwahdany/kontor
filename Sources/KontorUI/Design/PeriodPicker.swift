import SwiftUI
import KontorModel

/// The toolbar control for the global reporting period (`store.period`). The shell already places
/// one in the window toolbar; use it elsewhere only for screen-local overrides via the binding initialiser.
public struct PeriodPicker: View {
    @Environment(PortfolioStore.self) private var store
    private let external: Binding<ReportingPeriod>?
    @State private var isCustomPresented = false

    /// Bound to the store's global period.
    public init() { external = nil }

    /// Bound to a local period (e.g. a per-widget override).
    public init(selection: Binding<ReportingPeriod>) { external = selection }

    private var selection: ReportingPeriod {
        get { external?.wrappedValue ?? store.period }
        nonmutating set {
            if let external { external.wrappedValue = newValue } else { store.period = newValue }
        }
    }

    public var body: some View {
        Menu {
            Section("Trailing") {
                ForEach(ReportingPeriod.presets, id: \.self) { period in
                    item(period)
                }
            }
            Section("To Date") {
                item(.monthToDate)
                item(.quarterToDate)
            }
            Section("Calendar Year") {
                ForEach(calendarYears, id: \.self) { year in
                    item(.calendarYear(year))
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
        .help("Reporting period: \(selection.title)")
        .accessibilityLabel("Reporting period")
        .accessibilityValue(selection.title)
        .popover(isPresented: $isCustomPresented, arrowEdge: .bottom) {
            CustomRangeEditor(initial: selection.interval(today: store.today, inception: store.inception)) { range in
                selection = .custom(from: range.lowerBound, to: range.upperBound)
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
