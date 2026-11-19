import SwiftUI
import AppKit
import KontorUI
import KontorMarketData

/// Access to KontorMarketData's providers. The shell installs a `QuoteUpdater` on the store when
/// the network may be used; in the screenshot mode and in tests there is none, and then nothing
/// in this feature issues a request (the descriptors for the feed form come from a registry
/// backed by an in-memory stub).
@MainActor
enum MarketAccess {
    private static let offlineRegistry = ProviderRegistry.standard(http: StubHTTPClient())

    static func isOnline(_ store: PortfolioStore) -> Bool { store.quoteUpdater != nil }

    static func registry(_ store: PortfolioStore) -> ProviderRegistry {
        store.quoteUpdater?.registry ?? offlineRegistry
    }

    /// Provider id → display name ("yahoo" → "Yahoo Finance").
    static func providerNames(_ store: PortfolioStore) -> [String: String] {
        Dictionary(registry(store).descriptors.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    static func automaticProviders(_ store: PortfolioStore) -> Set<String> {
        Set(registry(store).descriptors.filter(\.isAutomatic).map(\.id))
    }

    static let offlineHint = "Not available offline."
}

extension PortfolioStore {
    func isBenchmark(_ id: UUID) -> Bool { file.settings.benchmarkSecurityIDs.contains(id) }

    /// Adds the security to, or removes it from, the benchmarks offered in performance charts.
    func toggleBenchmark(_ id: UUID) {
        let isOn = isBenchmark(id)
        updateSettings(isOn ? "Remove Benchmark" : "Use as Benchmark") { settings in
            if isOn { settings.benchmarkSecurityIDs.removeAll { $0 == id } } else { settings.benchmarkSecurityIDs.append(id) }
        }
    }

    func setRetired(_ ids: Set<UUID>, _ retired: Bool) {
        let name = retired ? "Retire" : "Reactivate"
        mutate("\(name) \(ids.count == 1 ? "Security" : "Securities")") { file in
            for index in file.securities.indices where ids.contains(file.securities[index].id) {
                file.securities[index].isRetired = retired
            }
        }
    }

    /// A copy with master data, feed and quotes — but no transactions. Returns the new id.
    @discardableResult
    func duplicateSecurity(_ id: UUID) -> UUID? {
        guard var copy = security(id) else { return nil }
        copy.id = UUID()
        copy.name += " Copy"
        copy.events = copy.events.map { SecurityEvent(day: $0.day, kind: $0.kind, detail: $0.detail) }
        mutate("Duplicate Security") { file in
            let index = file.securities.firstIndex { $0.id == id }.map { $0 + 1 } ?? file.securities.endIndex
            file.securities.insert(copy, at: index)
        }
        return copy.id
    }

    func addSecurities(_ ids: some Sequence<UUID>, toWatchlist watchlistID: UUID) {
        guard var list = file.watchlists.first(where: { $0.id == watchlistID }) else { return }
        var seen = Set(list.securityIDs)
        let new = ids.filter { security($0) != nil && seen.insert($0).inserted }
        guard !new.isEmpty else { return }
        list.securityIDs.append(contentsOf: new)
        mutate("Add to “\(list.name)”") { file in
            if let index = file.watchlists.firstIndex(where: { $0.id == watchlistID }) { file.watchlists[index] = list }
        }
    }

    func removeSecurities(_ ids: Set<UUID>, fromWatchlist watchlistID: UUID) {
        mutate("Remove from Watchlist") { file in
            if let index = file.watchlists.firstIndex(where: { $0.id == watchlistID }) {
                file.watchlists[index].securityIDs.removeAll { ids.contains($0) }
            }
        }
    }

    /// The depot a new booking for the security most likely belongs to: where it is held (or was
    /// last booked), else the only depot of the file.
    func preferredDepot(forSecurity id: UUID) -> UUID? {
        transactions(forSecurity: id).last(where: { $0.depotID != nil })?.depotID ?? (file.depots.count == 1 ? file.depots.first?.id : nil)
    }

    func presentNewTransaction(_ kind: Transaction.Kind, securityID: UUID, date: Day? = nil) {
        present(.newTransaction(TransactionPrefill(
            kind: kind, date: date ?? today, securityID: securityID, depotID: preferredDepot(forSecurity: securityID))))
    }

    /// Tab-separated master data of the given securities (in file order), for ⌘C.
    func securitiesTSV(_ ids: Set<UUID>) -> String {
        TSV.string(
            header: ["Name", "Ticker", "ISIN", "WKN", "Currency", "Latest Price", "Latest Quote", "Feed"],
            rows: file.securities.filter { ids.contains($0.id) }.map { s in
                [s.name, s.ticker, s.isin, s.wkn, s.currency,
                 s.prices.latest.map { TSV.number($0.price.decimalValue) } ?? "", s.prices.lastDay?.iso ?? "",
                 s.feed?.provider ?? ""]
            })
    }
}

/// A small pill used for states such as "Retired" or "Benchmark".
struct StatusBadge: View {
    let title: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A labelled figure: caption (optionally with a help topic) above a value.
struct Figure<Value: View>: View {
    let label: String
    var topic: HelpTopic?
    var footnote: String?
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label).font(.kontorCaption).foregroundStyle(.secondary).lineLimit(1)
                if let topic { HelpButton(topic) }
            }
            value.font(.kontorValue).lineLimit(1).minimumScaleFactor(0.8)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).numeric().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
