import SwiftUI
import KontorUI

/// The "Tax Years" tab: realized gains and losses, dividends, interest, fees and taxes per calendar
/// year — always over all years of the window's scope — with a chart, ⌘C and CSV export.
struct TaxYearsView: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<TaxYearsModel>()
    @State private var selection = Set<TaxYearRow.ID>()

    let pinsHover: Bool
    /// Shows the closed trades of a year.
    let showYear: (Int) -> Void
    let export: (TaxYearsModel) -> Void

    var body: some View {
        Group {
            if let model = model.value {
                if model.isEmpty {
                    EmptyState(
                        "Nothing to Report Yet", symbol: "calendar",
                        message: "Sales, dividends, interest and taxes\(store.isWholePortfolioScope ? "" : " of \(store.scopeTitle)") will be summarized here per calendar year."
                    ) {
                        if !store.isWholePortfolioScope {
                            Button("Whole Portfolio") { store.scopeSelection = .portfolio }
                        }
                    }
                } else {
                    content(model)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "trades.years", interval: store.interval(for: .allTime)) { analysis in TaxYearsModel(analysis) }
        // A selected year can disappear (scope change, undo): drop it instead of keeping a phantom selection.
        .onChange(of: model.value?.years.map(\.id)) { _, years in
            let valid = selection.intersection(Set(years ?? []).union([0]))
            if valid != selection { selection = valid }
        }
    }

    private func content(_ model: TaxYearsModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Spacing.xs) {
                            Text("Per Calendar Year").font(.title3.weight(.semibold))
                            HelpButton(.realizedGains)
                        }
                        Text("All years · \(store.scopeTitle) · amounts in \(model.currency). Realized results are after trading fees and before taxes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: DS.Spacing.s)
                    Button("Copy", systemImage: "doc.on.doc") {
                        Pasteboard.copy(model.tsv())
                        store.toast("Copied \(Fmt.integer(model.years.count)) tax years", style: .success)
                    }
                    .help("Copy the table for pasting into a spreadsheet")
                    Button("Export CSV…", systemImage: "square.and.arrow.up") { export(model) }
                        .help("Save the table as a CSV file")
                }
                if !model.unconvertedCurrencies.isEmpty {
                    Label(
                        "No exchange rate for \(model.unconvertedCurrencies.joined(separator: ", ")) → \(model.currency): amounts booked in \(model.unconvertedCurrencies.count == 1 ? "that currency" : "those currencies") are missing from this summary.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Card {
                    chart(model)
                        .frame(height: 170)
                }
            }
            .padding(.horizontal, DS.Spacing.xl)
            table(model)
                .opacity(self.model.isRefreshing ? 0.7 : 1)
        }
    }

    private func chart(_ model: TaxYearsModel) -> some View {
        let years = Array(model.years.reversed())
        return BarSeriesChart(
            categories: years.map { .year($0.id) },
            series: [
                BarSeries("Net realized", values: years.map(\.net)),
                BarSeries("Dividends", values: years.map(\.dividends)),
                BarSeries("Interest", values: years.map(\.interest)),
                BarSeries("Taxes paid", values: years.map(\.taxes), color: ChartColors.neutral),
            ],
            format: .money(model.currency), layout: .grouped, coloring: .series, title: "Realized gains, income and taxes per year")
            .selection(selection.count == 1 ? selection.first.map { String($0) } : nil) { id in
                selection = id.flatMap { Int($0) }.map { [$0] } ?? []
            }
            .pinnedHover(pinsHover ? years.last.map { String($0.id) } : nil)
            .loading(self.model.isRefreshing)
    }

    private func table(_ model: TaxYearsModel) -> some View {
        let currency = model.currency
        return Table(model.years + [model.total], selection: $selection) {
            TableColumn("Year") { row in
                Text(row.displayLabel).numeric().fontWeight(row.isTotal ? .semibold : .regular)
                    .help(row.isPartial ? "The year is still running: figures for the year so far" : "")
            }
            .width(min: 64, ideal: 72)
            TableColumn("Trades") { row in
                Text(Fmt.integer(row.trades)).numeric().fontWeight(row.isTotal ? .semibold : .regular)
                    .foregroundStyle(row.trades == 0 ? .tertiary : .primary)
            }
            .width(min: 50, ideal: 60)
            .alignment(.trailing)
            TableColumn("Gains") { row in amount(row.gains, currency, row) }
                .width(min: 68, ideal: 100)
                .alignment(.trailing)
            TableColumn("Losses") { row in amount(row.losses, currency, row) }
                .width(min: 68, ideal: 100)
                .alignment(.trailing)
            TableColumn("Net Realized") { row in
                GainText(money: Money(minor: row.net, currency: currency), symbol: false).fontWeight(row.isTotal ? .semibold : .regular)
            }
            .width(min: 68, ideal: 100)
            .alignment(.trailing)
            TableColumn("Dividends") { row in amount(row.dividends, currency, row) }
                .width(min: 68, ideal: 100)
                .alignment(.trailing)
            TableColumn("Interest") { row in amount(row.interest, currency, row) }
                .width(min: 68, ideal: 100)
                .alignment(.trailing)
            TableColumn("Fees") { row in
                amount(row.fees, currency, row)
                    .help("All fees booked in the year, including the trading fees already deducted from the realized results")
            }
            .width(min: 68, ideal: 100)
            .alignment(.trailing)
            TableColumn("Taxes Paid") { row in
                amount(row.taxes, currency, row)
                    .help("All taxes booked in the year (on sales, dividends and interest), net of refunds")
            }
            .width(min: 68, ideal: 100)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: TaxYearRow.ID.self) { ids in
            if ids.count == 1, let year = ids.first, year != 0 {
                Button("Show Closed Trades of \(String(year))") { showYear(year) }
                Divider()
            }
            Button(ids.isEmpty ? "Copy Table" : "Copy") { Pasteboard.copy(tsv(model, ids)) }
            Button("Export CSV…") { export(model) }
        } primaryAction: { ids in
            if ids.count == 1, let year = ids.first, year != 0 { showYear(year) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(model, selection) as NSString)] }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: model.years.count, noun: "year", selected: selection.count) {
                Text("Double-click a year to see its closed trades")
            }
        }
        .accessibilityLabel("Tax years")
    }

    private func amount(_ minor: Int64, _ currency: CurrencyCode, _ row: TaxYearRow) -> some View {
        Text(Fmt.money(Money(minor: minor, currency: currency), symbol: false))
            .numeric()
            .fontWeight(row.isTotal ? .semibold : .regular)
            .foregroundStyle(minor == 0 ? .tertiary : .primary)
    }

    /// The selected years (or the whole table) as TSV.
    private func tsv(_ model: TaxYearsModel, _ ids: Set<TaxYearRow.ID>) -> String {
        guard !ids.isEmpty else { return model.tsv() }
        var subset = model
        subset.years = model.years.filter { ids.contains($0.id) }
        let full = subset.tsv().split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Keep the totals line only if it was selected.
        return (ids.contains(0) ? full : Array(full.dropLast())).joined(separator: "\n")
    }
}
