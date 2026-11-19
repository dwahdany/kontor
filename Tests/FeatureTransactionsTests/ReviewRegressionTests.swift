import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureTransactions

/// Regression tests for the findings of the independent review of the Transactions feature.
@Suite struct ReviewDraftTests {
    private func day(_ d: Int) -> Day { Day(year: 2026, month: 6, day: d) }

    /// USD security bought through the EUR account, no stored security-currency value.
    private func foreignBuy() -> Txn {
        Txn(kind: .buy, date: day(10), accountID: Fixture.giro.id, depotID: Fixture.depot.id, securityID: Fixture.quill.id,
            shares: Shares(5), amount: Money(minor: 90_500, currency: "EUR"), fees: 500)
    }

    @Test func changingTheDateOfAForeignEntryKeepsItsAmount() {
        let original = foreignBuy()
        let ledger = Ledger(Fixture.file([original]))
        var draft = TransactionDraft(editing: original, ledger: ledger)
        #expect(draft.total == 90_500)
        #expect(draft.rate == 0.9)
        draft.date = day(20)                                   // the rate of that day is 0.8
        draft.resolve(ledger, changed: [.date])
        #expect(draft.total == 90_500)
        var expected = original
        expected.date = day(20)
        #expect(draft.makeTransaction() == expected)           // only the date changed
    }

    @Test func changingTheDateKeepsATypedForeignTotal() {
        var draft = Fixture.newDraft(.buy, security: Fixture.quill)
        draft.edit(.total, 80_000)                             // amount first: shares follow from the quote
        #expect(draft.shares == Shares(5).raw)
        draft.date = day(10)
        draft.resolve(Fixture.ledger, changed: [.date])
        #expect(draft.total == 80_000)
        #expect(draft.rate == 0.9)
    }

    @Test func typedSharesAreNeverRecalculated() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.edit(.price, Price(100).raw)
        draft.edit(.fees, 500)
        #expect(draft.total == 100_500)
        draft.edit(.total, 100_490)                            // the statement figure
        #expect(draft.shares == Shares(10).raw)
        #expect(draft.price == Price(99.99).raw)
        #expect(draft.total == 100_490)
        #expect(draft.calculated == .price)
    }

    @Test func aForeignBuyWithoutRateCannotBeSavedWithFeesOnly() {
        var file = Fixture.file()
        file.exchangeRates = []
        var draft = Fixture.newDraft(.buy, security: Fixture.quill, ledger: Ledger(file))
        draft.edit(.shares, Shares(5).raw)
        draft.edit(.fees, 990)
        #expect(draft.gross == 0)
        #expect(draft.issues(context: PositionContext(), today: Fixture.today).contains { $0.severity == .error })
    }

    @Test func aNewDividendKeepsItsDepot() {
        let prefill = TransactionPrefill(kind: .dividend, securityID: Fixture.acme.id, depotID: Fixture.second.id)
        var draft = TransactionDraft(prefill: prefill, ledger: Fixture.ledger, today: Fixture.today)
        draft.edit(.gross, 5_000)
        #expect(draft.makeTransaction().depotID == Fixture.second.id)

        let stored = Txn(kind: .dividend, date: day(12), accountID: Fixture.giro.id, depotID: Fixture.second.id, securityID: Fixture.acme.id,
                         shares: Shares(10), amount: Money(minor: 7_000, currency: "EUR"), taxes: 3_000)
        let copy = TransactionDraft(prefill: TransactionPrefill(copying: stored, date: Fixture.today), ledger: Fixture.ledger, today: Fixture.today).makeTransaction()
        #expect(copy.depotID == Fixture.second.id)
    }
}

@Suite struct ReviewDepotTests {
    private func day(_ d: Int) -> Day { Day(year: 2026, month: 6, day: d) }
    private func buy(_ shares: Double, depot: Depot, on d: Int) -> Txn {
        Txn(kind: .buy, date: day(d), accountID: Fixture.giro.id, depotID: depot.id, securityID: Fixture.acme.id, shares: Shares(shares),
            amount: Money(minor: Int64(shares * 5_000), currency: "EUR"))
    }

    private func context(_ ledger: Ledger, depot: UUID?, excluding: Txn? = nil) -> PositionContext {
        PositionContext(ledger: ledger, day: day(20), securityID: Fixture.acme.id, depotID: depot, counterDepotID: nil,
                        accountID: Fixture.giro.id, counterAccountID: nil, excluding: excluding)
    }

    @Test func aNewDividendProposesTheDepotThatHoldsTheSecurity() {
        // 30 shares in the second depot, 10 in the main one.
        let ledger = Ledger(Fixture.file([buy(10, depot: Fixture.depot, on: 2), buy(30, depot: Fixture.second, on: 3)]))
        var draft = Fixture.newDraft(.dividend, security: Fixture.acme, ledger: ledger)
        #expect(draft.depotID == nil)
        let whole = context(ledger, depot: nil)
        #expect(whole.holdings == [Fixture.depot.id: Shares(10).raw, Fixture.second.id: Shares(30).raw])
        #expect(whole.sharesHeld == Shares(40).raw)
        // Unassigned and held twice: a warning, because it would count for both depots.
        #expect(draft.issues(context: whole, today: Fixture.today).contains { $0.field == .depot && $0.severity == .warning })

        draft.adopt(whole, choosesDepot: true)
        #expect(draft.depotID == Fixture.second.id)                       // the larger holding
        #expect(draft.shares == Shares(30).raw)                           // … and its share count, not both depots together
        draft.edit(.gross, 3_000)
        #expect(draft.makeTransaction().depotID == Fixture.second.id)
        #expect(draft.issues(context: context(ledger, depot: Fixture.second.id), today: Fixture.today).isEmpty)

        // A depot chosen deliberately (or the habit) is kept as long as it holds the security.
        var chosen = Fixture.newDraft(.dividend, security: Fixture.acme, ledger: ledger)
        chosen.depotID = Fixture.depot.id
        chosen.adopt(whole, choosesDepot: true)
        #expect(chosen.depotID == Fixture.depot.id)
        #expect(chosen.shares == Shares(10).raw)
        chosen.edit(.shares, Shares(7).raw)                               // typed shares are kept
        chosen.adopt(whole, choosesDepot: true)
        #expect(chosen.shares == Shares(7).raw)

        // An existing entry is never re-assigned.
        let stored = Txn(kind: .dividend, date: day(12), accountID: Fixture.giro.id, securityID: Fixture.acme.id, shares: Shares(40),
                         amount: Money(minor: 4_000, currency: "EUR"))
        var editing = TransactionDraft(editing: stored, ledger: ledger)
        editing.adopt(whole, choosesDepot: true)
        #expect(editing.makeTransaction() == stored)
    }

    @Test func feesOnASecurityCarryADepotAndPlainOnesDoNot() {
        var fee = Fixture.newDraft(.fee, security: Fixture.acme)
        fee.depotID = Fixture.second.id
        fee.edit(.total, 500)
        #expect(fee.showsOptionalDepot)
        #expect(fee.makeTransaction().depotID == Fixture.second.id)
        fee.securityID = nil
        #expect(!fee.showsOptionalDepot)
        #expect(fee.makeTransaction().depotID == nil)
        // Switching a new dividend to a buy falls back to the usual depot.
        var draft = Fixture.newDraft(.dividend, security: Fixture.acme)
        #expect(draft.depotID == nil)
        draft.setKind(.buy)
        #expect(draft.depotID == Fixture.depot.id)
    }

    @Test func theEditedEntryIsTakenOutOfTheHoldings() {
        let purchase = buy(10, depot: Fixture.depot, on: 2)
        let ledger = Ledger(Fixture.file([purchase, buy(5, depot: Fixture.depot, on: 3)]))
        #expect(context(ledger, depot: Fixture.depot.id, excluding: purchase).sharesHeld == Shares(5).raw)
        #expect(context(ledger, depot: nil, excluding: purchase).sharesHeld == Shares(5).raw)
        #expect(context(ledger, depot: Fixture.second.id).sharesHeld == 0)
    }
}

@Suite struct ReviewArithmeticTests {
    private let english = KontorFormatter(locale: Locale(identifier: "en_US"))
    private let german = KontorFormatter(locale: Locale(identifier: "de_DE"))

    @Test func aLeadingZeroIsNeverAGroupedThousand() {
        #expect(Arithmetic.evaluate("0.125", scaleDigits: 8, formatter: german) == 12_500_000)
        #expect(Arithmetic.evaluate("0,125", scaleDigits: 8, formatter: english) == 12_500_000)
        #expect(Arithmetic.evaluate(".125", scaleDigits: 8, formatter: german) == 12_500_000)
        #expect(Arithmetic.evaluate("3 * 0.125", scaleDigits: 8, formatter: german) == 37_500_000)
        // Real grouping still works.
        #expect(Arithmetic.evaluate("1.250", scaleDigits: 2, formatter: german) == 125_000)
        #expect(Arithmetic.evaluate("1,250", scaleDigits: 2, formatter: english) == 125_000)
    }

    @Test func lettersInsideANumberAreRejected() {
        #expect(Arithmetic.evaluate("1e5", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("12a3", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("100 USD", scaleDigits: 2, formatter: english) == 10_000)
        #expect(Arithmetic.evaluate("EUR 100", scaleDigits: 2, formatter: english) == 10_000)
        #expect(Arithmetic.evaluate("1.234,56 €", scaleDigits: 2, formatter: german) == 123_456)
    }
}

@Suite struct ReviewLedgerTests {
    private func day(_ d: Int) -> Day { Day(year: 2026, month: 6, day: d) }

    @Test func standaloneFeesAndTaxesCountInTheFooter() {
        let giro = Fixture.giro.id
        let file = Fixture.file([
            Txn(kind: .deposit, date: day(1), accountID: giro, amount: Money(minor: 100_000, currency: "EUR")),
            Txn(kind: .fee, date: day(2), accountID: giro, amount: Money(minor: 1_200, currency: "EUR")),
            Txn(kind: .feeRefund, date: day(3), accountID: giro, amount: Money(minor: 200, currency: "EUR")),
            Txn(kind: .tax, date: day(4), accountID: giro, amount: Money(minor: 5_000, currency: "EUR")),
            Txn(kind: .taxRefund, date: day(5), accountID: giro, amount: Money(minor: 1_500, currency: "EUR")),
            Txn(kind: .buy, date: day(6), accountID: giro, depotID: Fixture.depot.id, securityID: Fixture.acme.id, shares: Shares(1),
                amount: Money(minor: 5_100, currency: "EUR"), fees: 100),
        ])
        let base = LedgerBase(Ledger(file), today: Fixture.today)
        let all = LedgerContent(base: base, query: LedgerQuery())
        #expect(all.totals.fees == 1_200 - 200 + 100)
        #expect(all.totals.taxes == 5_000 - 1_500)
        var query = LedgerQuery()
        query.groups = [.costs]
        let costs = LedgerContent(base: base, query: query)
        #expect(costs.totals.fees == 1_000)
        #expect(costs.totals.taxes == 3_500)
        query.accountID = giro
        #expect(LedgerContent(base: base, query: query).totals.fees == 1_000)
    }
}

extension ReviewLedgerTests {
    @Test func aDepotFilterShowsTransfersFromThatDepotsSide() {
        let file = Fixture.file([
            Txn(kind: .deliveryIn, date: day(1), depotID: Fixture.depot.id, securityID: Fixture.acme.id, shares: Shares(100), amount: Money(minor: 500_000, currency: "EUR")),
            Txn(kind: .securityTransfer, date: day(2), depotID: Fixture.depot.id, counterDepotID: Fixture.second.id, securityID: Fixture.acme.id,
                shares: Shares(40), amount: Money(minor: 200_000, currency: "EUR")),
        ])
        let ledger = Ledger(file)
        let base = LedgerBase(ledger, today: Fixture.today)
        #expect(LedgerContent(base: base, query: LedgerQuery()).rows.first?.shares == -Shares(40).raw)   // whole portfolio: from the source
        for depot in [Fixture.depot, Fixture.second] {
            var query = LedgerQuery()
            query.depotID = depot.id
            let rows = LedgerContent(base: base, query: query).rows
            let held = ledger.snapshot(on: Fixture.today).position(Fixture.acme.id)?.holdings.first { $0.depotID == depot.id }?.shares.raw
            #expect(rows.reduce(0) { $0 + $1.shares } == held)            // the Shares column adds up to the depot's position
        }
        var query = LedgerQuery()
        query.depotID = Fixture.second.id
        #expect(LedgerContent(base: base, query: query).rows.map(\.shares) == [Shares(40).raw])
    }

    @Test func amountsWithoutAnExchangeRateAreReportedNotZeroed() {
        var file = Fixture.file([
            Txn(kind: .deposit, date: day(1), accountID: Fixture.dollars.id, amount: Money(minor: 100_000, currency: "USD")),
            Txn(kind: .buy, date: day(2), accountID: Fixture.dollars.id, depotID: Fixture.depot.id, securityID: Fixture.quill.id, shares: Shares(2),
                amount: Money(minor: 41_000, currency: "USD"), fees: 1_000),
            Txn(kind: .deposit, date: day(3), accountID: Fixture.giro.id, amount: Money(minor: 50_000, currency: "EUR")),
        ])
        file.exchangeRates = []
        let base = LedgerBase(Ledger(file), today: Fixture.today)
        let all = LedgerContent(base: base, query: LedgerQuery())
        #expect(all.totals.inflows == 50_000)
        #expect(all.totals.unconverted == 2)
        // One account: its own currency, nothing to convert.
        var query = LedgerQuery()
        query.accountID = Fixture.dollars.id
        let dollars = LedgerContent(base: base, query: query)
        #expect(dollars.totals.unconverted == 0)
        #expect(dollars.totals.inflows == 100_000 && dollars.totals.outflows == -41_000 && dollars.totals.fees == 1_000)
        // With rates on file nothing is missing.
        let complete = LedgerContent(base: LedgerBase(Ledger(Fixture.file(file.transactions)), today: Fixture.today), query: LedgerQuery())
        #expect(complete.totals.unconverted == 0)
        #expect(complete.totals.fees == 900)                              // 10.00 USD at 0.9
    }

    @Test func searchFindsAmountsAndDisplayedDates() {
        let file = Fixture.file([
            Txn(kind: .deposit, date: day(5), accountID: Fixture.giro.id, amount: Money(minor: 147_147, currency: "EUR")),
            Txn(kind: .deposit, date: day(6), accountID: Fixture.giro.id, amount: Money(minor: 20_005, currency: "EUR")),
        ])
        let base = LedgerBase(Ledger(file), today: Fixture.today, formatter: KontorFormatter(locale: Locale(identifier: "de_DE")))
        func found(_ text: String) -> [Int64] {
            var query = LedgerQuery()
            query.text = text
            return LedgerContent(base: base, query: query).rows.map(\.amount)
        }
        #expect(found("1471,47") == [147_147])
        #expect(found("1.471,47") == [147_147])
        #expect(found("1471.47") == [147_147])
        #expect(found("200,05") == [20_005])
        #expect(found("05.06.2026") == [147_147])
        #expect(found("2026-06-06") == [20_005])
        #expect(found("9999,99").isEmpty)
    }

    @Test func theSelectionHasItsOwnSums() {
        let giro = Fixture.giro.id
        let file = Fixture.file([
            Txn(kind: .deposit, date: day(1), accountID: giro, amount: Money(minor: 100_000, currency: "EUR")),
            Txn(kind: .withdrawal, date: day(2), accountID: giro, amount: Money(minor: 30_000, currency: "EUR")),
            Txn(kind: .fee, date: day(3), accountID: giro, amount: Money(minor: 1_200, currency: "EUR")),
        ])
        let content = LedgerContent(base: LedgerBase(Ledger(file), today: Fixture.today), query: LedgerQuery())
        let picked = Set(content.rows.filter { $0.kind != .deposit }.map(\.id))
        let sums = content.totals(of: picked)
        #expect(sums.inflows == 0 && sums.outflows == -31_200 && sums.fees == 1_200)
        #expect(content.totals(of: Set(content.rows.map(\.id))) == content.totals)
    }
}
