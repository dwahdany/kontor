import SwiftUI
import KontorUI

/// Inspector of the Performance screen: the selected security's figures for the period, or — with
/// nothing selected — how to read the two return measures.
struct PerformanceInspector: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                if let id = store.route.securityID {
                    SecurityInspector(securityID: id).id(id)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text(store.scopeTitle).font(.headline)
                        KeyValueRow("Period", Fmt.interval(store.periodInterval))
                        KeyValueRow("Length", Fmt.duration(days: store.periodInterval.dayCount))
                        KeyValueRow("Currency", store.baseCurrency)
                        KeyValueRow("Cost Method", store.file.settings.costMethod.title)
                        KeyValueRow("Risk-Free Rate", Fmt.percent(store.file.settings.riskFreeRate))
                        Button("Portfolio Settings…") { store.present(.portfolioSettings) }
                            .buttonStyle(.link)
                    }
                    Divider()
                    HelpTopicView(topic: .ttwrorVersusIRR)
                    Text("Select a security in the Securities section to see its figures here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SecurityInspector: View {
    @Environment(PortfolioStore.self) private var store
    let securityID: UUID
    @State private var figures = Loadable<SecurityFigures>()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(figures.value?.name ?? store.security(securityID)?.name ?? "Security")
                .font(.headline)
            Text(Fmt.interval(store.periodInterval))
                .font(.callout)
                .numeric()
                .foregroundStyle(.secondary)
            if let value = figures.value {
                if value.levels.count > 1 {
                    Sparkline(value.levels)
                        .frame(height: 44)
                        .accessibilityLabel("Price performance in the period")
                }
                if let p = value.performance {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        KeyValueRow("TTWROR") { SignedPercent(value: p.ttwror) }
                        KeyValueRow(value.irrIsAnnualized ? "IRR per year" : "IRR, not annualized") {
                            SignedPercent(value: value.moneyWeightedReturn)
                        }
                        KeyValueRow("Gain") { SignedMoney(minor: p.absolutePerformance, currency: value.currency) }
                        Divider()
                        KeyValueRow("Value", Fmt.money(minor: p.marketValue, currency: value.currency))
                        KeyValueRow("Shares", Fmt.shares(p.shares))
                        KeyValueRow("Share of Portfolio", Fmt.percent(p.portfolioWeight, decimals: 1))
                        Divider()
                        KeyValueRow("Realized") { SignedMoney(minor: p.periodRealizedGain, currency: value.currency, dashForZero: true) }
                        KeyValueRow("Unrealized") { SignedMoney(minor: p.periodUnrealizedGain, currency: value.currency, dashForZero: true) }
                        KeyValueRow("Dividends", Fmt.money(minor: p.dividends, currency: value.currency))
                        KeyValueRow("Fees", Fmt.money(minor: p.fees, currency: value.currency))
                        KeyValueRow("Taxes", Fmt.money(minor: p.taxes, currency: value.currency))
                    }
                    .numeric()
                } else {
                    Text("Not held or traded in this period and scope.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Open Security") { store.navigate(to: .security(securityID)) }
                Button("New Transaction…") {
                    store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today, securityID: securityID)))
                }
            }
            .controlSize(.small)
        }
        .opacity(figures.isRefreshing ? 0.6 : 1)
        .analysisTask($figures, id: "performance.inspector", variant: securityID) { SecurityFigures($0, securityID: securityID) }
    }
}
