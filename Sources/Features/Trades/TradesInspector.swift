import SwiftUI
import KontorUI

/// Inspector of the Trades screen: the selected trade with the lots that were matched to it and
/// deep links to the closing transaction and the security.
///
/// Follows `store.route.focus`: `.transaction(id)` → the trade closed by that transaction,
/// `.security(id)` → the open trades of that security.
struct TradesInspector: View {
    @Environment(PortfolioStore.self) private var store
    @AppStorage(LongTermThreshold.storageKey) private var storedThreshold = LongTermThreshold.defaultDays
    @State private var details = Loadable<[TradeDetail]>()

    private var focus: TradeFocus? {
        switch store.route.focus {
        case .transaction(let id): .closing(id)
        case .security(let id): .open(securityID: id)
        default: nil
        }
    }

    private var thresholdDays: Int {
        store.launchValue("threshold").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? max(1, storedThreshold)
    }

    var body: some View {
        let focus = focus
        Group {
            if focus != nil, let trades = details.value, !trades.isEmpty {
                Form {
                    ForEach(trades) { trade in
                        sections(trade)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .opacity(details.isRefreshing ? 0.7 : 1)
            } else if focus == nil || details.value != nil {
                hint
            } else {
                Color.clear
            }
        }
        .analysisTask($details, id: "trades.detail", variant: focus) { analysis in
            focus.map { TradeDetail.details(analysis, focus: $0) } ?? []
        }
    }

    private var hint: some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: "square.stack.3d.up")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No Trade Selected").font(.headline)
            Text("Select a trade to see the purchase lots that were matched to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HelpTopicView(topic: .trade)
                .padding(.top, DS.Spacing.m)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func sections(_ trade: TradeDetail) -> some View {
        let row = trade.row
        let currency = trade.currency
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(row.security).font(.headline)
                Text("\(row.isOpen ? "Open" : "Closed")\(row.isShort ? " short" : "") trade · \(row.depot)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    GainText(money: Money(minor: row.gain, currency: currency)).font(.kontorHero)
                    if let value = row.returnFraction { GainText(percent: value).font(.kontorValue) }
                }
                .padding(.top, DS.Spacing.xxs)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        Section("Result") {
            KeyValueRow(row.isOpen ? "Unrealized Gain" : "Realized Gain") { GainText(money: Money(minor: row.gain, currency: currency)) }
            LabeledContent {
                if let value = row.annualized { GainText(percent: value) } else { Text(Fmt.missing) }
            } label: {
                HelpLabel("Return p.a. (IRR)", topic: .irr).foregroundStyle(.secondary)
            }
            if trade.lots.count > 1, let simple = trade.simpleAnnualized {
                LabeledContent {
                    GainText(percent: simple)
                } label: {
                    HelpLabel("Annualized, Simple", topic: .annualizedReturn).foregroundStyle(.secondary)
                }
            }
            KeyValueRow("Taxes", Fmt.money(minor: row.taxes, currency: currency))
            KeyValueRow("Gain After Taxes") { GainText(money: Money(minor: trade.gainAfterTaxes, currency: currency)) }
        }
        Section("Trade") {
            KeyValueRow("Opened", Fmt.day(row.opened, style: .medium))
            KeyValueRow(row.isOpen ? "Valued" : "Closed", Fmt.day(row.end, style: .medium))
            LabeledContent {
                HStack(spacing: DS.Spacing.xs) {
                    Text(Fmt.duration(days: row.holdingDays)).numeric()
                    termBadge(row.holdingDays)
                }
            } label: {
                HelpLabel("Held", topic: .holdingPeriod).foregroundStyle(.secondary)
            }
            KeyValueRow("Shares", Fmt.shares(row.shares))
            KeyValueRow(row.isOpen ? "Cost" : "Entry Value", Fmt.money(minor: row.entryValue, currency: currency))
            KeyValueRow(row.isOpen ? "Market Value" : "Exit Value", Fmt.money(minor: row.exitValue, currency: currency))
            KeyValueRow("Fees Included", Fmt.money(minor: row.fees, currency: currency))
        }
        Section {
            ForEach(trade.lots.prefix(Self.lotLimit)) { lot in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.day(lot.opened, style: .medium))
                        Spacer(minLength: DS.Spacing.s)
                        Text(Fmt.money(minor: lot.entryValue, currency: currency))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text("\(Fmt.shares(lot.shares)) \(lot.shares == Shares(1) ? "share" : "shares")")
                        if let price = lot.entryPrice {
                            Text("at \(Fmt.price(price, currency: currency))")
                        }
                        Spacer(minLength: DS.Spacing.s)
                        Text(Fmt.duration(days: lot.holdingDays, style: .compact))
                        termDot(lot.holdingDays)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .numeric()
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
            if trade.lots.count > Self.lotLimit {
                Text("…and \(Fmt.integer(trade.lots.count - Self.lotLimit)) more lots")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(row.isShort ? "Sale" : "Purchase") date and entry value incl. fees · ● held more than \(LongTermThreshold.title(days: thresholdDays)) (long-term)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                Text(trade.lots.count == 1 ? "Matched Lot" : "Matched Lots (\(Fmt.integer(trade.lots.count)))")
                HelpButton(.costMethod)
                Spacer()
                Text(store.file.settings.costMethod.shortTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            if let transaction = row.closingTransactionID {
                Button("Show Closing Transaction") { store.navigate(to: .transaction(transaction)) }
                Button("Edit Closing Transaction…") { store.present(.editTransaction(transaction)) }
            } else {
                Button(row.isShort ? "Cover Position…" : "Sell Position…") {
                    store.present(.newTransaction(TransactionPrefill(
                        kind: row.isShort ? .buy : .sell, date: store.today, securityID: row.securityID, depotID: row.id.depotID, shares: row.shares)))
                }
            }
            Button("Show Security") { store.navigate(to: .security(row.securityID)) }
        }
    }

    /// Lots listed per trade; a savings plan sold at once can consist of hundreds.
    private static let lotLimit = 120

    private func isLongTerm(_ days: Int) -> Bool { LongTermThreshold.isLongTerm(holdingDays: days, threshold: thresholdDays) }

    private func termBadge(_ days: Int) -> some View {
        Text(isLongTerm(days) ? "Long-term" : "Short-term")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Counted from the oldest lot; long-term means held more than \(LongTermThreshold.title(days: thresholdDays))")
    }

    private func termDot(_ days: Int) -> some View {
        Text(isLongTerm(days) ? "●" : "○")
            .font(.system(size: 7))
            .foregroundStyle(.secondary)
            .accessibilityLabel(isLongTerm(days) ? "long-term" : "short-term")
    }
}
