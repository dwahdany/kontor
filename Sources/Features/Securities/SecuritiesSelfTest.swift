import Foundation
import KontorModel
import KontorUI

/// Hooks for the app's headless self-test (`Kontor --selftest`): the security editor's save path,
/// without a view.
public enum SecuritiesSelfTest {
    /// "New Security" → manual entry → Add. `feed` is what the editor's data-source section stores.
    @MainActor @discardableResult
    public static func addSecurity(
        name: String, currency: CurrencyCode, isin: String = "", ticker: String = "", feed: QuoteFeed? = nil, in store: PortfolioStore
    ) throws -> UUID {
        var draft = Security(name: name, currency: currency)
        draft.isin = isin
        draft.ticker = ticker
        draft.feed = feed
        // Offline, as in the self-test: nothing may start a download behind the test's back.
        SecurityEditor.commit(draft, isNew: true, isBenchmark: false, isOnline: false, in: store)
        guard store.security(draft.id) != nil else { throw SelfTestFailure("the security “\(name)” was not added") }
        return draft.id
    }

    /// Edit Security → change the note and the benchmark flag → Save (master data only).
    @MainActor
    public static func edit(_ id: UUID, note: String, isBenchmark: Bool, in store: PortfolioStore) throws {
        guard var security = store.security(id) else { throw SelfTestFailure("security \(id) does not exist") }
        let prices = security.prices
        security.note = note
        SecurityEditor.commit(security, isNew: false, isBenchmark: isBenchmark, isOnline: false, in: store)
        guard let saved = store.security(id), saved.note == note, saved.prices == prices,
              store.file.settings.benchmarkSecurityIDs.contains(id) == isBenchmark else {
            throw SelfTestFailure("editing the security did not store the note and the benchmark flag")
        }
    }
}
