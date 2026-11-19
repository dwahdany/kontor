import SwiftUI
import KontorUI

/// Inspector of the Trades screen: the selected trade with the lots that were matched to it and
/// deep links to the closing transaction, the purchases and the security.
///
/// Follows `store.route.focus`: `.transaction(id)` → the trade closed by that transaction,
/// `.security(id)` → the open trades of that security. An open trade is one security in one depot,
/// which the route focus cannot express, so the screen also shares the selected row
/// (`TradesSelectionCenter`); a deep link that names only the security lists every depot.
struct TradesInspector: View {
    @Environment(PortfolioStore.self) private var store
    @AppStorage(LongTermThreshold.storageKey) private var storedThreshold = LongTermThreshold.defaultDays
    @State private var details = Loadable<[TradeDetail]>()

    private struct Request: Hashable, Sendable {
        var focus: TradeFocus?
        var thresholdDays: Int
    }

    private var focus: TradeFocus? {
        TradeFocus.resolve(store.route.focus, selectedRow: TradesSelectionCenter.shared.row(for: store))
    }

    private var thresholdDays: Int {
        store.launchValue("threshold").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? max(1, storedThreshold)
    }

    var body: some View {
        let request = Request(focus: focus, thresholdDays: thresholdDays)
        Group {
            if request.focus != nil, let trades = details.value, !trades.isEmpty {
                Form {
                    ForEach(trades) { trade in
                        sections(trade)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .opacity(details.isRefreshing ? 0.7 : 1)
            } else if request.focus == nil || details.value != nil {
                hint
            } else {
                Color.clear
            }
        }
        .analysisTask($details, id: "trades.detail", variant: request) { analysis in
            request.focus.map { TradeDetail.details(analysis, focus: $0, thresholdDays: request.thresholdDays) } ?? []
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
                if row.isValued {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        GainText(money: Money(minor: row.gain, currency: currency)).font(.kontorHero)
                        if let value = row.returnFraction { GainText(percent: value).font(.kontorValue) }
                    }
                    .padding(.top, DS.Spacing.xxs)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                } else {
                    Text("Not valued").font(.kontorValue).foregroundStyle(.secondary).padding(.top, DS.Spacing.xxs)
                }
                if let explanation = row.valuation.explanation(reportingCurrency: currency) {
                    Label(explanation, systemImage: row.isValued ? "info.circle" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(row.isValued ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Colors.warning))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section {
            KeyValueRow(row.isOpen ? "Unrealized Gain" : "Realized Gain") { gain(row.gain, row, currency) }
            LabeledContent {
                if let value = row.annualized { GainText(percent: value) } else { Text(Fmt.missing) }
            } label: {
                HelpLabel("Return per Year (IRR)", topic: .irr).foregroundStyle(.secondary)
            }
            if trade.lots.count > 1, let simple = trade.simpleAnnualized {
                LabeledContent {
                    GainText(percent: simple)
                } label: {
                    HelpLabel("Annualized, Simple", topic: .annualizedReturn).foregroundStyle(.secondary)
                }
            }
            if row.term == .mixed {
                KeyValueRow("Long-Term Part") { gain(row.longTermGain, row, currency) }
                KeyValueRow("Short-Term Part") { gain(row.gain - row.longTermGain, row, currency) }
            }
            KeyValueRow("Taxes", Fmt.money(minor: row.taxes, currency: currency))
            KeyValueRow("Gain After Taxes") { gain(trade.gainAfterTaxes, row, currency) }
        } header: {
            Text("Result")
        } footer: {
            Text("Price gain after fees. Dividends received while holding are not included — see Earnings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Trade") {
            KeyValueRow("Opened", Fmt.day(row.opened, style: .medium))
            KeyValueRow(row.isOpen ? "Valued" : "Closed", Fmt.day(row.end, style: .medium))
            LabeledContent {
                Text(Fmt.duration(days: row.holdingDays)).numeric()
            } label: {
                HelpLabel(row.lotCount > 1 ? "Held, Average" : "Held", topic: .holdingPeriod).foregroundStyle(.secondary)
            }
            if row.lotCount > 1 {
                KeyValueRow("Oldest Lot Held", Fmt.duration(days: row.oldestDays))
            }
            KeyValueRow("Holding Period") { termBadge(row) }
            if row.weight == ScopeWeights.full {
                KeyValueRow("Shares", Fmt.shares(row.shares))
            } else {
                KeyValueRow("Shares Counted", "\(Fmt.shares(row.countedShares, maxDecimals: 4)) of \(Fmt.shares(row.shares, maxDecimals: 4))")
                KeyValueRow("Weight in \(store.scopeTitle)", Fmt.percent(basisPoints: row.weight))
            }
            KeyValueRow(row.isShort ? "Short-Sale Proceeds" : row.isOpen ? "Cost" : "Entry Value", Fmt.money(minor: row.entryValue, currency: currency))
            KeyValueRow(row.isShort ? "Cost to Cover" : row.isOpen ? "Market Value" : "Exit Value",
                        row.isValued ? Fmt.money(minor: row.exitValue, currency: currency) : Fmt.missing)
            KeyValueRow("Fees Included", Fmt.money(minor: row.fees, currency: currency))
        }
        Section {
            ForEach(trade.lots.prefix(Self.lotLimit)) { lot in
                lotRow(lot, currency: currency, isShort: row.isShort)
            }
            if trade.lots.count > Self.lotLimit {
                Text("…and \(Fmt.integer(trade.lots.count - Self.lotLimit)) more lots")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(row.isShort ? "Sale" : "Purchase") date and entry value incl. fees · ● held more than \(LongTermThreshold.title(days: thresholdDays)) (long-term)\(row.weight == ScopeWeights.full ? "" : " · shares and amounts at \(Fmt.percent(basisPoints: row.weight)) weight")")
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
                // Open trades are listed as of the end of the period; a sale starts from today's holding.
                let close = TradeActions.close(store.ledger, securityID: row.securityID, depotID: row.id.depotID, today: store.today)
                Button(close.isCover ? "Cover Position…" : "Sell Position…") {
                    if let prefill = TradeActions.closePrefill(close, securityID: row.securityID, depotID: row.id.depotID, today: store.today) {
                        store.present(.newTransaction(prefill))
                    }
                }
                .disabled(close == .nothingHeld)
                .help(close == .nothingHeld ? "This position is no longer held today" : "")
            }
            Button("Show Security") { store.navigate(to: .security(row.securityID)) }
        }
    }

    @ViewBuilder private func gain(_ minor: Int64, _ row: TradeRow, _ currency: CurrencyCode) -> some View {
        if row.isValued {
            GainText(money: Money(minor: minor, currency: currency))
        } else {
            Text(Fmt.missing)
        }
    }

    @ViewBuilder private func lotRow(_ lot: TradeDetail.Lot, currency: CurrencyCode, isShort: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.day(lot.opened, style: .medium))
                Spacer(minLength: DS.Spacing.s)
                Text(Fmt.money(minor: lot.entryValue, currency: currency))
                if lot.transactionID != nil {
                    Image(systemName: "chevron.forward").imageScale(.small).foregroundStyle(.tertiary)
                }
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
        .contentShape(Rectangle())
        if let transaction = lot.transactionID {
            Button {
                store.navigate(to: .transaction(transaction))
            } label: {
                content
            }
            .buttonStyle(.plain)
            .help("Show the \(isShort ? "sale" : "purchase") in Transactions")
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the transaction")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    /// Lots listed per trade; a savings plan sold at once can consist of hundreds.
    private static let lotLimit = 120

    private func isLongTerm(_ days: Int) -> Bool { LongTermThreshold.isLongTerm(holdingDays: days, threshold: thresholdDays) }

    /// Long-term is decided lot by lot; a trade whose lots straddle the threshold is partly long-term.
    private func termBadge(_ row: TradeRow) -> some View {
        let title = switch row.term {
        case .longTerm: "Long-term"
        case .shortTerm: "Short-term"
        case .mixed: "\(Fmt.percent(row.longTermShare, decimals: 0)) long-term"
        }
        let threshold = LongTermThreshold.title(days: thresholdDays)
        let help = switch row.term {
        case .longTerm: row.lotCount > 1 ? "All \(Fmt.integer(row.lotCount)) lots were held more than \(threshold)" : "Held more than \(threshold)"
        case .shortTerm: row.lotCount > 1 ? "None of the \(Fmt.integer(row.lotCount)) lots was held more than \(threshold)" : "Held \(threshold) or less"
        case .mixed: "\(Fmt.integer(row.longTermLots)) of \(Fmt.integer(row.lotCount)) lots (\(Fmt.percent(row.longTermShare, decimals: 0)) of the shares) were held more than \(threshold)"
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help(help)
    }

    private func termDot(_ days: Int) -> some View {
        Text(isLongTerm(days) ? "●" : "○")
            .font(.system(size: 7))
            .foregroundStyle(.secondary)
            .accessibilityLabel(isLongTerm(days) ? "long-term" : "short-term")
    }
}
