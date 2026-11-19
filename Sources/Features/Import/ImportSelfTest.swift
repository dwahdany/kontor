import Foundation
import KontorModel
import KontorEngine
import KontorInterchange
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): the import sheet's loader, the
/// Portfolio Performance summary's actions and the CSV wizard, without a view.
public enum ImportSelfTest {
    public struct Outcome: Sendable {
        public var transactions: Int
        public var securities: Int
        public var warnings: Int
        public var detail: String
    }

    /// Drop a Portfolio Performance file → summary sheet → "Import into This Portfolio" (untouched
    /// document) or "Merge into This Portfolio".
    @MainActor
    public static func importPortfolioPerformance(_ data: Data, fileName: String, in store: PortfolioStore) async throws -> Outcome {
        let current = store.file, today = store.today
        let loaded = await Background.run { ImportLoader.load(data, fileName: fileName, into: current, today: today) }
        guard case .portfolioPerformance(let result) = loaded else {
            throw SelfTestFailure("“\(fileName)” was not recognised as a Portfolio Performance file: \(loaded)")
        }
        let before = store.file
        if store.file.isUntouched {
            guard PortfolioPerformanceSummary.importHere(result, in: store) else { throw SelfTestFailure("importing “\(fileName)” changed nothing") }
            return Outcome(
                transactions: store.file.transactions.count, securities: store.file.securities.count, warnings: result.warnings.count,
                detail: "became the document")
        }
        let source = result.tag.source
        let merged = await Background.run { PortfolioMerge.merge(result.file, into: current, recordAs: source) }
        guard store.mutate("Merge Portfolio Performance File", { $0 = merged.file }) else { throw SelfTestFailure("merging “\(fileName)” changed nothing") }
        // Merging the same file again must not add anything.
        let again = PortfolioMerge.merge(result.file, into: store.file, recordAs: source)
        guard again.file.transactions.count == store.file.transactions.count, again.file.securities.count == store.file.securities.count else {
            throw SelfTestFailure("merging “\(fileName)” a second time would add entries again")
        }
        return Outcome(
            transactions: store.file.transactions.count - before.transactions.count,
            securities: store.file.securities.count - before.securities.count, warnings: result.warnings.count,
            detail: "merged: " + PortfolioPerformanceSummary.describe(merged.summary))
    }

    /// Drop a CSV → wizard with its automatic dialect, target and mapping → Import.
    @MainActor
    public static func importCSV(_ data: Data, fileName: String, in store: PortfolioStore) async throws -> Outcome {
        let before = store.file
        let wizard = CSVWizard(store: store, data: data, fileName: fileName, memory: .ephemeral())
        wizard.start()
        try await wait("the CSV pipeline") { wizard.output != nil && !wizard.isComputing }
        if let reason = wizard.blockingReason { throw SelfTestFailure("the CSV wizard cannot import “\(fileName)”: \(reason)") }
        await wizard.performImport()
        guard wizard.step == .done else { throw SelfTestFailure("the CSV wizard did not finish importing “\(fileName)”") }
        // Importing the same file again must flag every row as a duplicate.
        let second = CSVWizard(store: store, data: data, fileName: fileName, memory: .ephemeral())
        second.start()
        try await wait("the second CSV pipeline run") { second.output != nil && !second.isComputing }
        let recommended = second.output?.recommended.count ?? -1
        guard recommended == 0 else { throw SelfTestFailure("re-importing “\(fileName)” would add \(recommended) rows again") }
        return Outcome(
            transactions: store.file.transactions.count - before.transactions.count,
            securities: store.file.securities.count - before.securities.count, warnings: 0,
            detail: "target \(wizard.currentTarget)")
    }

    /// Export ▸ transactions as CSV, then read that CSV back into an empty portfolio: the round
    /// trip the export promises. Reports how the result differs from the original ledger.
    public static func csvRoundTrip(_ file: PortfolioFile) -> (exported: Int, imported: Int, differing: Int, firstDifference: String?) {
        let data = CSVExporter.data(CSVExporter.transactions(file))
        var empty = PortfolioFile()
        empty.settings.baseCurrency = file.settings.baseCurrency
        let proposal = CSVImporter.propose(CSVDocument(data: data), options: CSVImportOptions(target: .transactions, createMissingAccounts: true), file: empty)
        let imported = proposal.apply(to: empty, selection: .recommended)

        /// A transaction without ids: names instead, so the two files can be compared.
        func signature(_ t: Transaction, in file: PortfolioFile) -> String {
            func account(_ id: UUID?) -> String { id.flatMap { id in file.accounts.first { $0.id == id }?.name } ?? "-" }
            func depot(_ id: UUID?) -> String { id.flatMap { id in file.depots.first { $0.id == id }?.name } ?? "-" }
            let security = t.securityID.flatMap { id in file.securities.first { $0.id == id }?.name } ?? "-"
            return [
                t.kind.rawValue, t.date.iso, security, account(t.accountID), depot(t.depotID), account(t.counterAccountID),
                depot(t.counterDepotID), String(t.shares.raw), String(t.amount.minor), t.amount.currency, String(t.fees), String(t.taxes),
            ].joined(separator: "|")
        }
        var remaining = [String: Int]()
        for t in imported.transactions { remaining[signature(t, in: imported), default: 0] += 1 }
        var differing = 0
        var first: String?
        for t in file.transactions {
            let key = signature(t, in: file)
            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1
            } else {
                differing += 1
                if first == nil { first = key }
            }
        }
        return (file.transactions.count, imported.transactions.count, differing, first)
    }

    @MainActor
    private static func wait(_ what: String, timeout: Double = 30, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SelfTestFailure("\(what) did not finish within \(Int(timeout)) s") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
