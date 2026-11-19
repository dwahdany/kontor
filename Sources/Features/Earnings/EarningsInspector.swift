import SwiftUI
import KontorModel
import KontorUI

/// Dividend history of the security selected on the Earnings screen (all years, window scope).
struct EarningsInspector: View {
    struct Model: Sendable {
        struct Payment: Identifiable, Sendable {
            var id: UUID
            var day: Day
            var gross: Int64
            var perShare: Price?
        }

        var name: String
        var currency: CurrencyCode
        var total: Int64
        var count: Int
        var years: [BarCategory]
        var perYear: [Int64]
        /// Newest first.
        var recent: [Payment]
        var last: Payment?

        var isEmpty: Bool { count == 0 }

        init(_ analysis: Analysis, securityID: UUID?) {
            // For a cash account: the dividends booked on it (see `EarningsData`).
            let report = EarningsData.make(analysis, detailed: false)
            let history = securityID.map { id in report.payments.filter { $0.securityID == id } } ?? []
            name = securityID.flatMap { analysis.ledger.security($0)?.name } ?? ""
            currency = analysis.currency
            total = history.reduce(0) { $0 + $1.gross }
            var byYear: [Int: Int64] = [:]
            for payment in history { byYear[payment.day.year, default: 0] += payment.gross }
            let span = report.years.map(\.year).filter { year in
                guard let first = history.first?.day.year else { return false }
                return year >= first
            }
            years = span.map { BarCategory.year($0) }
            perYear = span.map { byYear[$0] ?? 0 }
            // Bookings of one day (the security sits in several depots) are one payment, as in the
            // Securities view; a click reveals its first booking.
            let withoutShares = history.isEmpty ? [] : DividendGroup.bookingsWithoutShares(in: analysis.ledger)
            let payments = DividendGroup.groups(history, withoutShares: withoutShares).map {
                Payment(id: $0.transactionIDs[0], day: $0.day, gross: $0.gross, perShare: $0.perShare)
            }
            count = payments.count
            recent = Array(payments.suffix(8).reversed())
            last = payments.last
        }
    }

    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<Model>()

    var body: some View {
        let securityID = store.route.securityID
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                if securityID == nil {
                    EmptyState("No Security Selected", symbol: "banknote",
                               message: "Select a security under Securities or Calendar to see its dividend history.")
                        .frame(minHeight: 240)
                } else if let value = model.value, !value.isEmpty {
                    details(value, securityID: securityID!)
                } else if let value = model.value, !model.isLoading {
                    EmptyState("No Dividends", symbol: "banknote",
                               message: "\(value.name.isEmpty ? "This security" : value.name) has not paid a dividend in \(store.isWholePortfolioScope ? "this portfolio" : store.scopeTitle).") {
                        Button("Record Dividend…") {
                            store.present(.newTransaction(EarningsActions.prefill(.dividend, securityID: securityID, store: store)))
                        }
                    }
                    .frame(minHeight: 240)
                }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .analysisTask($model, id: "earnings.inspector", interval: store.interval(for: .allTime), variant: securityID) { analysis in
            Model(analysis, securityID: securityID)
        }
    }

    @ViewBuilder private func details(_ value: Model, securityID: UUID) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(value.name).font(.headline)
            Text("Dividends, all years").font(.callout).foregroundStyle(.secondary)
        }
        VStack(spacing: DS.Spacing.s) {
            KeyValueRow("Received", Fmt.money(minor: value.total, currency: value.currency))
            KeyValueRow("Payments", Fmt.integer(value.count))
            if let last = value.last {
                KeyValueRow("Last Payment", Fmt.day(last.day, style: .medium))
                KeyValueRow("Per Share", EarningsFormat.perShare(last.perShare, currency: value.currency))
            }
        }
        .numeric()
        if value.years.count > 1 {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Per Year").font(.kontorCaption).foregroundStyle(.secondary)
                BarSeriesChart(
                    categories: value.years,
                    series: [BarSeries(id: "dividends", "Dividends", values: value.perYear, color: EarningsKind.dividends.color)],
                    format: .money(value.currency), title: "Dividends per year")
                    .legendHidden()
                    .loading(model.isRefreshing)
                    .frame(height: 140)
            }
        }
        if !value.recent.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Recent Payments").font(.kontorCaption).foregroundStyle(.secondary)
                ForEach(value.recent) { payment in
                    Button {
                        store.navigate(to: .transaction(payment.id))
                    } label: {
                        HStack {
                            Text(Fmt.day(payment.day, style: .medium))
                            Spacer()
                            Text(Fmt.money(minor: payment.gross, currency: value.currency))
                        }
                        .numeric()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this payment in Transactions")
                }
            }
        }
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Button("Record Dividend…") {
                store.present(.newTransaction(EarningsActions.prefill(.dividend, securityID: securityID, store: store)))
            }
            Button("Show Security") { store.navigate(to: .security(securityID)) }
        }
        .controlSize(.small)
    }
}
