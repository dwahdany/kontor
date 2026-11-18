import Foundation
import KontorModel

/// Generators for demo, starter and stress-test portfolios.
public enum SampleData {
    /// Length of the demo history in years.
    public static let demoHistoryYears = 9

    /// The fixed last day of every stress portfolio (keeps `stressPortfolio` independent of the clock).
    public static let stressEndDay = Day(year: 2025, month: 12, day: 31)

    /// A rich, realistic demo portfolio ending at `today`. Same seed + today ⇒ identical output (incl. all UUIDs).
    ///
    /// All instruments are fictional. Entity ids (securities, accounts, depots, taxonomies, plans …)
    /// depend on `seed` only, so they stay stable when `today` moves on. Prices and the ledger depend
    /// on both: the history is laid out relative to `today`, so another day yields another history.
    ///
    /// Quotes, exchange rates and transactions only fall on trading days (weekdays without New
    /// Year's Day, Good Friday, Easter Monday, 25/26 December); the crypto asset is quoted daily.
    public static func demoPortfolio(today: Day = .today, seed: UInt64 = 42) -> PortfolioFile {
        DemoBuilder.build(today: today, seed: seed)
    }

    /// A minimal starter file for "New Portfolio": one cash account + one depot in the given currency, default
    /// taxonomies (asset classes, regions) without assignments, a default dashboard.
    ///
    /// Unlike the other generators this one uses fresh random UUIDs, so two new files never share ids.
    public static func starterPortfolio(name: String, baseCurrency: CurrencyCode) -> PortfolioFile {
        let account = Account(name: "Cash Account", currency: baseCurrency)
        let depot = Depot(name: "Depot", referenceAccountID: account.id)
        let assetClasses = Templates.taxonomy(
            name: Templates.assetClassesName, nodes: Templates.assetClasses, targets: false, nextID: { UUID() })
        let regions = Templates.taxonomy(
            name: Templates.regionsName, nodes: Templates.regions, targets: false, nextID: { UUID() })
        return PortfolioFile(
            name: name, settings: Settings(baseCurrency: baseCurrency), accounts: [account], depots: [depot],
            taxonomies: [assetClasses, regions],
            dashboards: [Templates.dashboard(allocationTaxonomy: assetClasses.id, nextID: { UUID() })]
        )
    }

    /// A large synthetic file for performance testing: `securities` instruments with `years` of daily
    /// prices ending at `stressEndDay` and exactly `transactions` ledger entries. Deterministic per seed
    /// and consistent (no negative balances or positions).
    ///
    /// The file ends at the fixed `stressEndDay`, so benchmarks are reproducible whatever the clock
    /// says. Use `stressPortfolio(securities:years:transactions:seed:endingOn:)` for a file that
    /// reaches up to today (e.g. to exercise "year to date" reports in the running app).
    public static func stressPortfolio(securities: Int, years: Int, transactions: Int, seed: UInt64 = 1) -> PortfolioFile {
        StressBuilder.build(securities: securities, years: years, transactions: transactions, seed: seed, end: stressEndDay)
    }

    /// Like `stressPortfolio(securities:years:transactions:seed:)`, but with prices and transactions
    /// ending on `end` instead of `stressEndDay`. Same arguments ⇒ identical output.
    public static func stressPortfolio(
        securities: Int, years: Int, transactions: Int, seed: UInt64 = 1, endingOn end: Day
    ) -> PortfolioFile {
        StressBuilder.build(securities: securities, years: years, transactions: transactions, seed: seed, end: end)
    }
}
