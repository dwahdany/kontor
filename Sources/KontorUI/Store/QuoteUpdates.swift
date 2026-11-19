import Foundation
import KontorModel
import KontorMarketData

/// What a quote update did — shown in the toolbar popover and summarised in a toast.
public struct QuoteUpdateReport: Equatable, Sendable {
    /// One security (or the exchange rates) that could not be updated.
    public struct Failure: Identifiable, Equatable, Sendable {
        public var id: String
        /// nil for the exchange-rate download.
        public var securityID: UUID?
        public var name: String
        /// User-presentable reason, e.g. "The symbol was not found."
        public var message: String

        public init(securityID: UUID?, name: String, message: String) {
            id = securityID?.uuidString ?? "exchange-rates"
            self.securityID = securityID
            self.name = name
            self.message = message
        }
    }

    public var finishedAt: Date
    /// Securities and rate downloads that were part of the run.
    public var targetCount: Int
    /// Prices added or corrected.
    public var newPrices: Int
    /// Exchange rates added.
    public var newRates: Int
    /// Securities whose data changed.
    public var changedSecurities: Int
    public var failures: [Failure]
    /// Currencies without a rate source (e.g. crypto tickers used as currencies).
    public var unsupportedCurrencies: [CurrencyCode]
    public var wasCancelled: Bool

    public init(
        finishedAt: Date = Date(), targetCount: Int = 0, newPrices: Int = 0, newRates: Int = 0, changedSecurities: Int = 0,
        failures: [Failure] = [], unsupportedCurrencies: [CurrencyCode] = [], wasCancelled: Bool = false
    ) {
        self.finishedAt = finishedAt
        self.targetCount = targetCount
        self.newPrices = newPrices
        self.newRates = newRates
        self.changedSecurities = changedSecurities
        self.failures = failures
        self.unsupportedCurrencies = unsupportedCurrencies
        self.wasCancelled = wasCancelled
    }

    public var hasFailures: Bool { !failures.isEmpty }
    public var hasNewData: Bool { newPrices > 0 || newRates > 0 }

    /// "124 new prices, 6 new exchange rates" / "Everything is up to date".
    public var summary: String {
        var parts: [String] = []
        if newPrices > 0 { parts.append("\(Fmt.integer(newPrices)) new price\(newPrices == 1 ? "" : "s")") }
        if newRates > 0 { parts.append("\(Fmt.integer(newRates)) new exchange rate\(newRates == 1 ? "" : "s")") }
        if parts.isEmpty { return failures.isEmpty && !wasCancelled ? "Everything is up to date" : "No new data" }
        return parts.joined(separator: ", ")
    }
}

/// A weak reference that may cross actors; the store itself is only touched on the main actor.
private struct WeakStore: @unchecked Sendable {
    weak var store: PortfolioStore?
}

extension PortfolioStore {
    /// True if at least one active security has a feed the installed updater can download.
    public var hasAutomaticQuoteFeeds: Bool {
        guard let quoteUpdater else { return false }
        return file.securities.contains { !$0.isRetired && quoteUpdater.registry.isAutomatic($0.feed) }
    }

    /// True if the file uses more than one currency and an updater is installed: exchange rates
    /// are worth downloading even when no security has an automatic quote feed (a freshly imported
    /// multi-currency portfolio would otherwise value everything foreign at zero).
    public var needsExchangeRates: Bool {
        quoteUpdater != nil && file.currencies.count > 1
    }

    /// Downloads new quotes and exchange rates. A user-initiated (`interactive`) update is applied
    /// as **one undoable step** ("Undo Update Quotes"); an automatic one marks the document as
    /// edited without touching the undo and redo stacks. A run that finds nothing new leaves the
    /// document untouched. Progress is published as the store's background activity; the outcome
    /// ends up in ``lastQuoteUpdate``.
    ///
    /// Does nothing while an update is already running. Securities without a feed, with a `manual`
    /// feed and retired ones are never requested; without ``quoteUpdater`` (tests, screenshot mode)
    /// nothing touches the network at all.
    ///
    /// - Parameters:
    ///   - ids: Restrict the update to these securities ("Update Selected"); nil = all.
    ///   - reloadHistory: Request the full history again instead of only new days (after a split,
    ///     or to correct stored prices). Use together with `ids`.
    ///   - interactive: `true` for user-initiated updates: explains when there is nothing to
    ///     update and opens the results popover if something failed. Automatic updates stay quiet
    ///     and only leave a toast.
    /// - Returns: The running update (await `.value` for its report), or nil if none was started.
    @discardableResult
    public func updateQuotes(only ids: Set<UUID>? = nil, reloadHistory: Bool = false, interactive: Bool = true) -> Task<QuoteUpdateReport?, Never>? {
        guard !isUpdatingQuotes else { return nil }
        guard var updater = quoteUpdater else {
            if interactive { toast("Quote updates are not available", message: "This window has no connection to market data.", style: .warning) }
            return nil
        }
        if reloadHistory { updater.options.reloadsFullHistory = true }
        let file = file, today = today
        let plan = updater.plan(for: file, today: today, only: ids)
        guard plan.hasWork else {
            if interactive {
                let anyFeed = file.securities.contains { !$0.isRetired && updater.registry.isAutomatic($0.feed) }
                if anyFeed {
                    toast("Quotes are up to date", style: .success)
                } else {
                    toast("Nothing to update", message: "No security has an automatic quote feed yet. Choose one in the security's settings.", style: .info)
                }
            }
            return nil
        }

        isUpdatingQuotes = true
        isQuoteReportPresented = false
        beginActivity("Updating quotes", total: plan.targetCount)
        let names = Dictionary(file.securities.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let reference = WeakStore(store: self)
        let updateTask = Task { () -> QuoteUpdateReport? in
            let result = await updater.run(plan, file: file) { progress in
                guard progress.status.isFinal else { return }
                Task { @MainActor in
                    guard let store = reference.store, store.isUpdatingQuotes, let activity = store.activity else { return }
                    // Progress callbacks hop actors independently and may arrive out of order.
                    store.updateActivity(completed: max(activity.completed, progress.completed), total: progress.total)
                }
            }
            return reference.store?.finishQuoteUpdate(result, targetCount: plan.targetCount, names: names, interactive: interactive)
        }
        quoteUpdateTask = updateTask
        return updateTask
    }

    /// Cancels the running quote update. What was downloaded so far is still applied.
    public func cancelQuoteUpdate() {
        quoteUpdateTask?.cancel()
    }

    private func finishQuoteUpdate(_ result: UpdateResult, targetCount: Int, names: [UUID: String], interactive: Bool) -> QuoteUpdateReport {
        // Applied to a copy first: a run that brought nothing new only stamps "last checked" times,
        // which must neither mark the document as edited nor become an undo step.
        var updated = file
        let summary = result.apply(to: &updated)
        let broughtData = summary.prices > 0 || summary.rates > 0 || summary.derivedRates > 0 || summary.events > 0
        if broughtData {
            // The user's own update is one undo step. An automatic one must not take over ⌘Z or wipe
            // the redo stack behind the user's back: it only marks the document as edited.
            mutate("Update Quotes", undoable: interactive) { $0 = updated }
        }
        var failures = result.failures.map { target, message -> QuoteUpdateReport.Failure in
            switch target {
            case .security(let id):
                QuoteUpdateReport.Failure(securityID: id, name: security(id)?.name ?? names[id] ?? "Unknown security", message: message)
            case .exchangeRates:
                QuoteUpdateReport.Failure(securityID: nil, name: "Exchange rates", message: message)
            }
        }
        failures.sort { ($0.securityID == nil ? 0 : 1, $0.name) < ($1.securityID == nil ? 0 : 1, $1.name) }
        let report = QuoteUpdateReport(
            finishedAt: result.finishedAt, targetCount: targetCount, newPrices: summary.prices, newRates: summary.rates + summary.derivedRates,
            changedSecurities: summary.changedSecurities.count, failures: failures,
            unsupportedCurrencies: result.unsupportedCurrencies, wasCancelled: result.wasCancelled)
        lastQuoteUpdate = report
        isUpdatingQuotes = false
        quoteUpdateTask = nil
        endActivity()

        if report.hasFailures {
            let count = report.failures.count
            toast(
                count == 1 ? "1 quote feed could not be updated" : "\(count) quote feeds could not be updated",
                message: report.hasNewData ? report.summary : nil, style: .warning)
            if interactive { isQuoteReportPresented = true }
        } else if report.wasCancelled {
            toast("Quote update canceled", message: report.hasNewData ? report.summary : nil, style: .info)
        } else if interactive || report.hasNewData {
            toast(report.hasNewData ? "Quotes updated" : "Quotes are up to date", message: report.hasNewData ? report.summary : nil, style: .success)
        }
        return report
    }

    /// Shows a report in the results popover (used by the screenshot mode and by tests).
    public func presentQuoteReport(_ report: QuoteUpdateReport) {
        lastQuoteUpdate = report
        isQuoteReportPresented = true
    }
}
