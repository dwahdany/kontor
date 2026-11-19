import Foundation
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureTransactions

// Tests of the Transactions feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Transactions"):
//
//     KONTOR_FEATURES=Transactions swift test --scratch-path .build-transactions --filter FeatureTransactionsTests

typealias Txn = KontorModel.Transaction

/// A small two-currency portfolio with known quotes and exchange rates.
enum Fixture {
    static let today = Day(year: 2026, month: 6, day: 30)
    static let giro = Account(name: "Giro", currency: "EUR")
    static let savings = Account(name: "Savings", currency: "EUR")
    static let dollars = Account(name: "Dollar Cash", currency: "USD")
    static let depot = Depot(name: "Main Depot", referenceAccountID: giro.id)
    static let second = Depot(name: "Second Depot", referenceAccountID: savings.id)
    /// EUR security quoted at 50.00 on Jun 26 and 52.00 on Jun 29.
    static let acme = Security(name: "ACME", currency: "EUR", prices: PriceSeries([
        PricePoint(day: Day(year: 2026, month: 6, day: 26), price: Price(50)),
        PricePoint(day: Day(year: 2026, month: 6, day: 29), price: Price(52)),
    ]))
    /// USD security quoted at 200.00.
    static let quill = Security(name: "Quill Inc.", currency: "USD", prices: PriceSeries([
        PricePoint(day: Day(year: 2026, month: 6, day: 1), price: Price(200)),
    ]))
    static let unquoted = Security(name: "Unlisted", currency: "EUR")

    static func file(_ transactions: [Txn] = []) -> PortfolioFile {
        var rates = ExchangeRateSeries(base: "USD", quote: "EUR")
        rates.merge([(day: Day(year: 2026, month: 1, day: 1), rate: 0.9), (day: Day(year: 2026, month: 6, day: 15), rate: 0.8)])
        return PortfolioFile(
            name: "Fixture", settings: Settings(baseCurrency: "EUR"), securities: [acme, quill, unquoted],
            accounts: [giro, savings, dollars], depots: [depot, second], transactions: transactions, exchangeRates: [rates])
    }

    static var ledger: Ledger { Ledger(file()) }

    static func newDraft(_ kind: Txn.Kind, security: Security? = nil, ledger: Ledger = Fixture.ledger) -> TransactionDraft {
        TransactionDraft(prefill: TransactionPrefill(kind: kind, securityID: security?.id), ledger: ledger, today: today)
    }
}

@Suite @MainActor struct TransactionsFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(TransactionsFeature.module.screen == .transactions)
    }

    @Test func moduleProvidesTheTransactionSheets() {
        let registry = FeatureRegistry([TransactionsFeature.module])
        #expect(registry.sheet(for: .newTransaction) != nil)
        #expect(registry.sheet(for: .editTransaction(UUID())) != nil)
        #expect(registry.sheet(for: .custom(id: "transactions.change-date", payload: [:])) != nil)
        #expect(registry.sheet(for: .newSecurity) == nil)
        #expect(registry.sheet(for: .custom(id: "allocation.rebalance", payload: [:])) == nil)
    }
}

@Suite struct ArithmeticTests {
    private let english = KontorFormatter(locale: Locale(identifier: "en_US"))
    private let german = KontorFormatter(locale: Locale(identifier: "de_DE"))

    @Test func plainNumbersInEitherLocale() {
        #expect(Arithmetic.evaluate("1,234.56", scaleDigits: 2, formatter: english) == 123_456)
        #expect(Arithmetic.evaluate("1.234,56 €", scaleDigits: 2, formatter: german) == 123_456)
        #expect(Arithmetic.evaluate("0,5", scaleDigits: 8, formatter: german) == 50_000_000)
        #expect(Arithmetic.evaluate("-12.50", scaleDigits: 2, formatter: english) == 1_250)
    }

    @Test func simpleCalculations() {
        #expect(Arithmetic.evaluate("3*120.5", scaleDigits: 2, formatter: english) == 36_150)
        #expect(Arithmetic.evaluate("3 × 120,5", scaleDigits: 2, formatter: german) == 36_150)
        #expect(Arithmetic.evaluate("1.200,50 + 9,90", scaleDigits: 2, formatter: german) == 121_040)
        #expect(Arithmetic.evaluate("(250 - 12.5) / 4", scaleDigits: 2, formatter: english) == 5_938)
        #expect(Arithmetic.evaluate("2+3*4", scaleDigits: 2, formatter: english) == 1_400)
        #expect(Arithmetic.evaluate("100/3", scaleDigits: 8, formatter: english) == 3_333_333_333)
    }

    @Test func rejectsNonsense() {
        #expect(Arithmetic.evaluate("", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("abc", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("3*", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("10/0", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("(2+3", scaleDigits: 2, formatter: english) == nil)
        #expect(Arithmetic.evaluate("2-5", scaleDigits: 2, formatter: english) == nil)   // negative results are not amounts
    }
}

@Suite struct DraftCalculationTests {
    @Test func newBuyStartsWithSmartDefaults() {
        let draft = Fixture.newDraft(.buy, security: Fixture.acme)
        #expect(draft.date == Fixture.today)
        #expect(draft.depotID == Fixture.depot.id)
        #expect(draft.accountID == Fixture.giro.id)                 // the depot's reference account
        #expect(draft.currency == "EUR")
        #expect(draft.price == Price(52).raw)                       // latest quote on or before the day
        #expect(draft.priceIsQuote)
        #expect(draft.quoteDay == Day(year: 2026, month: 6, day: 29))
        #expect(draft.total == 0)
    }

    @Test func sharesTimesPricePlusChargesIsTotal() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        #expect(draft.gross == 52_000)
        #expect(draft.total == 52_000)
        #expect(draft.calculated == .amount)
        draft.edit(.fees, 990)
        draft.edit(.taxes, 10)
        #expect(draft.gross == 52_000)
        #expect(draft.total == 53_000)
    }

    @Test func sellDeductsCharges() {
        var draft = Fixture.newDraft(.sell, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.edit(.fees, 990)
        draft.edit(.taxes, 2_010)
        #expect(draft.gross == 52_000)
        #expect(draft.total == 49_000)
    }

    @Test func theFieldEditedLastIsRespected() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        // Typing the total keeps shares (typed before) and recalculates the price.
        draft.edit(.total, 51_000)
        #expect(draft.calculated == .price)
        #expect(draft.price == Price(51).raw)
        #expect(draft.shares == Shares(10).raw)
        #expect(!draft.priceIsQuote)
        // Typing the price now keeps the shares — a typed share count is never recalculated — and
        // the amount follows.
        draft.edit(.price, Price(25.5).raw)
        #expect(draft.calculated == .amount)
        #expect(draft.shares == Shares(10).raw)
        #expect(draft.total == 25_500)
        // Typing shares again recalculates the amount from the price typed last.
        draft.edit(.shares, Shares(4).raw)
        #expect(draft.calculated == .amount)
        #expect(draft.total == 10_200)
        // Emptying the share field hands it back to the calculation: amount ÷ price.
        draft.edit(.shares, 0)
        draft.edit(.total, 51_000)
        #expect(draft.calculated == .shares)
        #expect(draft.shares == Shares(20).raw)
    }

    @Test func amountFirstCalculatesTheShares() {
        // "I invested 100 € at the day's price" — the savings-plan case.
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.total, 10_400)
        #expect(draft.calculated == .shares)
        #expect(draft.shares == Shares(2).raw)
        #expect(draft.price == Price(52).raw)
    }

    @Test func aPinnedTotalSurvivesFees() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.edit(.total, 53_000)          // what the statement says was paid
        draft.edit(.fees, 1_000)            // … of which 10.00 were fees
        #expect(draft.total == 53_000)
        #expect(draft.gross == 52_000)
        #expect(draft.price == Price(52).raw)
        #expect(draft.shares == Shares(10).raw)
    }

    @Test func clearingAFieldDoesNotWipeTheOthers() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.edit(.price, 0)
        #expect(draft.total == 52_000)
        #expect(draft.shares == Shares(10).raw)
    }

    @Test func aMissingPriceIsFilledInFromTheAmount() {
        var draft = Fixture.newDraft(.buy, security: Fixture.unquoted)
        #expect(draft.price == 0)
        draft.edit(.shares, Shares(8).raw)
        #expect(draft.total == 0)
        draft.edit(.total, 20_000)
        #expect(draft.price == Price(25).raw)
    }

    @Test func theQuoteFollowsTheDateUntilAPriceIsTyped() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.date = Day(year: 2026, month: 6, day: 27)
        draft.resolve(Fixture.ledger, changed: [.date])
        #expect(draft.price == Price(50).raw)
        #expect(draft.total == 50_000)
        draft.edit(.price, Price(49).raw)
        draft.date = Fixture.today
        draft.resolve(Fixture.ledger, changed: [.date])
        #expect(draft.price == Price(49).raw)
        #expect(draft.total == 49_000)
    }

    @Test func foreignSecurityUsesTheRateOfTheDay() {
        var draft = Fixture.newDraft(.buy, security: Fixture.quill)
        #expect(draft.isForeign)
        #expect(draft.securityCurrency == "USD")
        #expect(draft.currency == "EUR")
        #expect(draft.rate == 0.8)
        draft.edit(.shares, Shares(5).raw)
        #expect(draft.securityGross == 100_000)      // 5 × 200.00 USD
        #expect(draft.gross == 80_000)               // × 0.8
        draft.edit(.fees, 500)
        #expect(draft.total == 80_500)

        // The statement shows what was really paid: the rate follows, shares and price stay.
        draft.edit(.total, 82_500)
        #expect(draft.gross == 82_000)
        #expect(abs(draft.rate - 0.82) < 1e-12)
        #expect(draft.ratePinned)
        #expect(draft.securityGross == 100_000)
        #expect(draft.shares == Shares(5).raw)

        let transaction = draft.makeTransaction()
        #expect(transaction.amount == Money(minor: 82_500, currency: "EUR"))
        #expect(transaction.securityGross == Money(minor: 100_000, currency: "USD"))
        #expect(transaction.fees == 500)
    }

    @Test func editingTheRateOrTheForeignValue() {
        var draft = Fixture.newDraft(.buy, security: Fixture.quill)
        draft.edit(.shares, Shares(5).raw)
        draft.editRate(0.9)
        #expect(draft.gross == 90_000)
        #expect(draft.total == 90_000)
        draft.edit(.securityGross, 110_000)
        #expect(draft.price == Price(220).raw)       // shares typed, price calculated
        #expect(draft.gross == 99_000)
    }

    @Test func foreignSecurityWithAnAccountInItsOwnCurrencyNeedsNoRate() {
        var draft = Fixture.newDraft(.buy, security: Fixture.quill)
        draft.edit(.shares, Shares(5).raw)
        draft.accountID = Fixture.dollars.id
        draft.resolve(Fixture.ledger, changed: [.account])
        #expect(!draft.isForeign)
        #expect(draft.currency == "USD")
        #expect(draft.total == 100_000)
        #expect(draft.makeTransaction().securityGross == nil)
        // … and back: the value in USD is what stays, converted again.
        draft.accountID = Fixture.giro.id
        draft.resolve(Fixture.ledger, changed: [.account])
        #expect(draft.isForeign)
        #expect(draft.securityGross == 100_000)
        #expect(draft.total == 80_000)
    }

    @Test func aMissingExchangeRateIsReported() {
        var file = Fixture.file()
        file.exchangeRates = []
        var draft = Fixture.newDraft(.buy, security: Fixture.quill, ledger: Ledger(file))
        #expect(draft.rateMissing)
        draft.edit(.shares, Shares(5).raw)
        // Without a rate the value in the account's currency is unknown: that blocks saving.
        #expect(draft.issues(context: PositionContext(), today: Fixture.today).contains { $0.severity == .error && $0.message.contains("exchange rate") })
        draft.edit(.total, 80_000)
        #expect(abs(draft.rate - 0.8) < 1e-12)
        #expect(!draft.issues(context: PositionContext(), today: Fixture.today).contains { $0.message.contains("exchange rate") })
    }

    @Test func convertingBetweenBuyAndDeliveryKeepsEverything() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        draft.edit(.fees, 990)
        draft.note = "gift"
        draft.setKind(.deliveryIn)
        draft.resolve(Fixture.ledger, changed: [.kind])
        #expect(draft.shares == Shares(10).raw)
        #expect(draft.price == Price(52).raw)
        #expect(draft.total == 52_990)
        let delivery = draft.makeTransaction()
        #expect(delivery.kind == .deliveryIn)
        #expect(delivery.accountID == nil)
        #expect(delivery.depotID == Fixture.depot.id)
        #expect(delivery.fees == 990)
        #expect(delivery.note == "gift")

        draft.setKind(.buy)
        draft.resolve(Fixture.ledger, changed: [.kind])
        #expect(draft.accountID == Fixture.giro.id)
        #expect(draft.makeTransaction().amount.minor == 52_990)

        // Sell ↔ outbound delivery flips nothing either; charges are deducted in both.
        draft.setKind(.sell)
        draft.resolve(Fixture.ledger, changed: [.kind])
        #expect(draft.total == 52_000 - 990)
        draft.setKind(.deliveryOut)
        draft.resolve(Fixture.ledger, changed: [.kind])
        #expect(draft.total == 52_000 - 990)
        #expect(draft.shares == Shares(10).raw)
    }

    @Test func dividendNetOfTaxes() {
        var draft = Fixture.newDraft(.dividend, security: Fixture.acme)
        draft.edit(.gross, 10_000)
        draft.edit(.taxes, 2_637)
        #expect(draft.total == 7_363)
        // Typing the net amount afterwards keeps the taxes and corrects the gross.
        draft.edit(.total, 7_400)
        #expect(draft.gross == 10_037)
        let transaction = draft.makeTransaction()
        #expect(transaction.kind == .dividend)
        #expect(transaction.amount.minor == 7_400)
        #expect(transaction.taxes == 2_637)
        #expect(transaction.grossMinor == 10_037)
        #expect(transaction.depotID == nil)
    }

    @Test func cashTransferBetweenCurrencies() {
        var prefill = TransactionPrefill(kind: .cashTransfer, accountID: Fixture.dollars.id)
        prefill.counterAccountID = Fixture.giro.id
        var draft = TransactionDraft(prefill: prefill, ledger: Fixture.ledger, today: Fixture.today)
        #expect(draft.isCrossCurrencyTransfer)
        #expect(draft.counterRate == 0.8)
        draft.edit(.total, 100_000)
        #expect(draft.counterAmount == 80_000)
        draft.edit(.counterAmount, 79_500)                  // what really arrived
        #expect(abs(draft.counterRate - 0.795) < 1e-12)
        draft.edit(.total, 200_000)                          // the implied rate is kept
        #expect(draft.counterAmount == 159_000)
        let transaction = draft.makeTransaction()
        #expect(transaction.amount == Money(minor: 200_000, currency: "USD"))
        #expect(transaction.counterAmount == Money(minor: 159_000, currency: "EUR"))
        #expect(transaction.counterAccountID == Fixture.giro.id)

        // Same currency: no counter amount is stored.
        draft.counterAccountID = Fixture.savings.id
        draft.accountID = Fixture.giro.id
        draft.resolve(Fixture.ledger, changed: [.account, .counterAccount])
        #expect(!draft.isCrossCurrencyTransfer)
        #expect(draft.makeTransaction().counterAmount == nil)
    }

    @Test func everyPrefillFieldIsHonoured() {
        let day = Day(year: 2026, month: 3, day: 2)
        let prefill = TransactionPrefill(
            kind: .sell, date: day, securityID: Fixture.acme.id, accountID: Fixture.savings.id, depotID: Fixture.second.id,
            shares: Shares(4), amount: Money(minor: 19_000, currency: "EUR"), fees: 600, taxes: 400, note: "rebalance", source: "plan:x")
        let draft = TransactionDraft(prefill: prefill, ledger: Fixture.ledger, today: Fixture.today)
        let transaction = draft.makeTransaction()
        #expect(transaction.kind == .sell)
        #expect(transaction.date == day)
        #expect(transaction.securityID == Fixture.acme.id)
        #expect(transaction.accountID == Fixture.savings.id)
        #expect(transaction.depotID == Fixture.second.id)
        #expect(transaction.shares == Shares(4))
        #expect(transaction.amount == Money(minor: 19_000, currency: "EUR"))
        #expect(transaction.fees == 600)
        #expect(transaction.taxes == 400)
        #expect(transaction.note == "rebalance")
        #expect(transaction.source == "plan:x")
        // gross 200.00 for 4 shares → the price is implied, not the quote
        #expect(draft.price == Price(50).raw)

        var transfer = TransactionPrefill(kind: .securityTransfer, securityID: Fixture.acme.id, depotID: Fixture.depot.id, shares: Shares(3))
        transfer.counterDepotID = Fixture.second.id
        let moved = TransactionDraft(prefill: transfer, ledger: Fixture.ledger, today: Fixture.today).makeTransaction()
        #expect(moved.counterDepotID == Fixture.second.id)
        #expect(moved.depotID == Fixture.depot.id)
        #expect(moved.accountID == nil)
        #expect(moved.amount.minor == 15_600)                 // 3 × 52.00, informational

        // Shares only ("sell everything"): the quote prices it.
        let all = TransactionDraft(prefill: TransactionPrefill(kind: .sell, securityID: Fixture.acme.id, shares: Shares(2)), ledger: Fixture.ledger, today: Fixture.today)
        #expect(all.total == 10_400)
    }

    @Test func duplicatingKeepsTheNumbers() {
        let original = Txn(kind: .buy, date: Day(year: 2025, month: 5, day: 5), accountID: Fixture.giro.id, depotID: Fixture.depot.id,
                           securityID: Fixture.acme.id, shares: Shares(3), amount: Money(minor: 12_990, currency: "EUR"), fees: 990, note: "monthly")
        let draft = TransactionDraft(prefill: TransactionPrefill(copying: original, date: Fixture.today), ledger: Fixture.ledger, today: Fixture.today)
        let copy = draft.makeTransaction()
        #expect(copy.id != original.id)
        #expect(copy.date == Fixture.today)
        #expect(copy.shares == original.shares)
        #expect(copy.amount == original.amount)
        #expect(copy.fees == 990)
        #expect(copy.note == "monthly")
        #expect(draft.price == Price(40).raw)
    }

    @Test func saveAndNewKeepsTheContext() {
        var draft = Fixture.newDraft(.dividend, security: Fixture.acme)
        draft.date = Day(year: 2026, month: 5, day: 20)
        draft.accountID = Fixture.savings.id
        draft.edit(.gross, 5_000)
        draft.note = "Q1"
        let next = draft.next(ledger: Fixture.ledger)
        #expect(next.kind == .dividend)
        #expect(next.date == draft.date)
        #expect(next.accountID == Fixture.savings.id)
        #expect(next.securityID == nil)
        #expect(next.total == 0)
        #expect(next.note.isEmpty)
        #expect(next.isNew)
    }
}

@Suite struct DraftValidationTests {
    private func messages(_ draft: TransactionDraft, _ context: PositionContext = PositionContext(), severity: EditorIssue.Severity) -> [String] {
        draft.issues(context: context, today: Fixture.today).filter { $0.severity == severity }.map(\.message)
    }

    @Test func aCompleteBuyHasNoFindings() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        #expect(draft.issues(context: PositionContext(sharesHeld: 0, cashBalance: 1_000_000), today: Fixture.today).isEmpty)
    }

    @Test func missingFieldsAreErrors() {
        let empty = Fixture.newDraft(.buy)
        let errors = messages(empty, severity: .error)
        #expect(errors.contains("Choose a security."))
        #expect(errors.contains("Enter the number of shares."))
        #expect(errors.contains("Enter a price or the total amount."))

        var transfer = Fixture.newDraft(.cashTransfer)
        transfer.edit(.total, 1_000)
        #expect(messages(transfer, severity: .error) == ["Choose the account the money goes to."])
        transfer.counterAccountID = transfer.accountID
        #expect(messages(transfer, severity: .error) == ["The money cannot go to the account it comes from."])

        #expect(messages(Fixture.newDraft(.deposit), severity: .error) == ["Enter an amount."])
    }

    @Test func chargesAboveTheTotalAreAnError() {
        var draft = Fixture.newDraft(.dividend, security: Fixture.acme)
        draft.edit(.total, 1_000)
        #expect(messages(draft, severity: .error).isEmpty)
        var sale = Fixture.newDraft(.sell, security: Fixture.acme)
        sale.edit(.shares, Shares(1).raw)
        sale.edit(.fees, 9_000)
        #expect(messages(sale, severity: .error) == ["Fees and taxes are higher than the gross amount."])
        var buy = Fixture.newDraft(.buy, security: Fixture.acme)
        buy.edit(.shares, Shares(1).raw)
        buy.edit(.total, 5_000)
        buy.edit(.fees, 9_000)
        #expect(messages(buy, severity: .error) == ["Fees and taxes are higher than the total."])
    }

    @Test func sellingMoreThanHeldIsAWarning() {
        var draft = Fixture.newDraft(.sell, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        let warnings = messages(draft, PositionContext(sharesHeld: Shares(4).raw, cashBalance: 0), severity: .warning)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("only 4 shares"))
        #expect(messages(draft, PositionContext(sharesHeld: Shares(4).raw), severity: .error).isEmpty)       // warnings never block saving
        #expect(messages(draft, PositionContext(sharesHeld: 0), severity: .warning)[0].contains("no shares"))
        #expect(messages(draft, PositionContext(sharesHeld: Shares(10).raw), severity: .warning).isEmpty)
    }

    @Test func overdrawingAnAccountIsAWarning() {
        var draft = Fixture.newDraft(.withdrawal)
        draft.edit(.total, 50_000)
        #expect(messages(draft, PositionContext(cashBalance: 20_000), severity: .warning).count == 1)
        #expect(messages(draft, PositionContext(cashBalance: 50_000), severity: .warning).isEmpty)
        var deposit = Fixture.newDraft(.deposit)
        deposit.edit(.total, 50_000)
        #expect(messages(deposit, PositionContext(cashBalance: -10_000), severity: .warning).isEmpty)
    }

    @Test func futureDatesAndOddPricesAreWarnings() {
        var draft = Fixture.newDraft(.buy, security: Fixture.acme)
        draft.edit(.shares, Shares(1).raw)
        draft.date = Fixture.today.advanced(by: 3)
        #expect(messages(draft, severity: .warning) == ["This date is in the future."])
        draft.date = Fixture.today
        draft.edit(.price, Price(80).raw)
        #expect(messages(draft, severity: .warning).contains { $0.contains("above the quote") })
    }

    @Test func aDeliveryWithoutPriceIsOnlyAWarning() {
        var draft = Fixture.newDraft(.deliveryIn, security: Fixture.unquoted)
        draft.edit(.shares, Shares(5).raw)
        #expect(messages(draft, severity: .error).isEmpty)
        #expect(messages(draft, severity: .warning).contains { $0.contains("value of zero") })
    }

    @Test func outcomePreview() {
        var draft = Fixture.newDraft(.sell, security: Fixture.acme)
        draft.edit(.shares, Shares(10).raw)
        let outcome = draft.outcome(context: PositionContext(sharesHeld: Shares(52.5).raw, cashBalance: 100_000))
        #expect(outcome.shares == Shares(42.5).raw)
        #expect(outcome.cash == 152_000)
    }
}

@Suite @MainActor struct DemoPortfolioTests {
    private let today = Day(year: 2026, month: 6, day: 30)

    /// Opening any stored entry in the editor and saving it without touching anything must not change it.
    @Test func editingWithoutChangesIsTheIdentity() {
        let file = SampleData.demoPortfolio(today: today)
        let ledger = Ledger(file)
        #expect(Set(file.transactions.map(\.kind)).count >= 8)
        for transaction in file.transactions {
            let draft = TransactionDraft(editing: transaction, ledger: ledger)
            var expected = transaction
            expected.note = transaction.note.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(draft.makeTransaction() == expected, "\(transaction.kind) \(transaction.date)")
            #expect(draft.issues(context: PositionContext(), today: today).filter { $0.severity == .error }.isEmpty)
        }
    }

    @Test func positionContextComesFromTheEngineWithoutTheEditedEntry() throws {
        let file = SampleData.demoPortfolio(today: today)
        let ledger = Ledger(file)
        let buy = try #require(file.transactions.last { $0.kind == .buy })
        let context = PositionContext(
            ledger: ledger, day: buy.date, securityID: buy.securityID, depotID: buy.depotID, counterDepotID: nil,
            accountID: buy.accountID, counterAccountID: nil, excluding: buy)
        let draft = TransactionDraft(editing: buy, ledger: ledger)
        let outcome = draft.outcome(context: context)
        let snapshot = ledger.snapshot(on: buy.date)
        let held = snapshot.position(buy.securityID!)?.holdings.first { $0.depotID == buy.depotID }?.shares.raw
        #expect(outcome.shares == held)
        #expect(outcome.cash == snapshot.cash(buy.accountID!)?.balance.minor)
        #expect(context.sharesHeld == held.map { $0 - buy.shares.raw })
    }

    @Test func ledgerRowsFilterSortAndSum() async throws {
        let file = SampleData.demoPortfolio(today: today)
        let store = PortfolioStore(file: file, today: today)
        let today = today
        let base = try await store.compute(LedgerBaseKey(today: today)) { ledger in LedgerBase(ledger, today: today) }
        #expect(base.rows.count == file.transactions.count)
        #expect(base.rows.map(\.order) == Array(0..<Int32(file.transactions.count)))

        // Default: everything, newest first.
        let all = LedgerContent(base: base, query: LedgerQuery())
        #expect(all.rows.count == file.transactions.count)
        #expect(all.rows.first?.date == file.transactions.map(\.date).max())
        #expect(all.totals.currency == "EUR")
        #expect(all.totals.inflows > 0 && all.totals.outflows < 0)

        // Kind groups.
        var query = LedgerQuery()
        query.groups = [.income]
        let income = LedgerContent(base: base, query: query)
        #expect(income.rows.count == file.transactions.count { $0.kind == .dividend || $0.kind == .interest })
        #expect(income.totals.outflows == 0)

        // One account: the running balance ends at the engine's balance, and in + out add up to it.
        let account = try #require(file.accounts.first)
        query = LedgerQuery()
        query.accountID = account.id
        let single = LedgerContent(base: base, query: query)
        let balance = try #require(Ledger(file).snapshot(on: today).cash(account.id)?.balance.minor)
        #expect(single.rows.first?.balance == balance)
        #expect(single.totals.inflows + single.totals.outflows == balance)
        #expect(single.totals.currency == account.currency)
        #expect(single.rows.count == store.transactions(forAccount: account.id).count)

        // The balance is not affected by other filters.
        query.groups = [.trades]
        let trades = LedgerContent(base: base, query: query)
        let firstTrade = try #require(trades.rows.first)
        #expect(firstTrade.balance == single.rows.first { $0.id == firstTrade.id }?.balance)

        // Search matches names case-insensitively; sorting by amount works.
        query = LedgerQuery()
        query.text = "meridian BUY"
        query.sortOrder = [KeyPathComparator(\LedgerRow.cash, order: .forward)]
        let search = LedgerContent(base: base, query: query)
        #expect(!search.rows.isEmpty)
        #expect(search.rows.allSatisfy { $0.kind == .buy && $0.security.contains("Meridian") })
        #expect(search.rows.map(\.cash) == search.rows.map(\.cash).sorted())

        // Date range.
        query = LedgerQuery()
        query.interval = DayInterval(start: Day(year: 2025, month: 12, day: 31), end: today)
        let year = LedgerContent(base: base, query: query)
        #expect(year.rows.count == file.transactions.count { $0.date.year == 2026 })
    }

    @Test func tsvHasOneLinePerRow() async throws {
        let file = SampleData.demoPortfolio(today: today)
        let base = LedgerBase(Ledger(file), today: today)
        let text = LedgerExport.tsv(Array(base.rows.prefix(5)))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines[0].split(separator: "\t").count == LedgerExport.header.count)
    }
}

/// "Duplicate" and "Repeat Last Transaction" go through `TransactionPrefill(copying:)`: what the
/// original booking fixed must come along instead of being derived again from today's rates.
@Suite struct PrefillCopyTests {
    @Test func duplicateKeepsTheForeignValueAndRate() {
        let day = Day(year: 2026, month: 2, day: 3)
        // 10 Quill at 210 USD, booked at a rate of 0.85 — not the stored 0.9 of that day.
        let original = Txn(
            kind: .buy, date: day, minuteOfDay: 615, accountID: Fixture.giro.id, depotID: Fixture.depot.id, securityID: Fixture.quill.id,
            shares: Shares(10), amount: Money(minor: 178_500, currency: "EUR"), securityGross: Money(minor: 210_000, currency: "USD"))
        let ledger = Ledger(Fixture.file([original]))
        let draft = TransactionDraft(prefill: TransactionPrefill(copying: original), ledger: ledger, today: Fixture.today)
        var copy = draft.makeTransaction(id: original.id)
        #expect(copy.securityGross == original.securityGross)
        #expect(copy.amount == original.amount && copy.minuteOfDay == 615)
        copy.note = original.note
        #expect(copy == original)

        // Dated today, the time of day and the ex-date stay behind; the values do not.
        let today = TransactionDraft(prefill: TransactionPrefill(copying: original, date: Fixture.today), ledger: ledger, today: Fixture.today).makeTransaction()
        #expect(today.date == Fixture.today && today.minuteOfDay == nil)
        #expect(today.securityGross == original.securityGross && today.amount == original.amount)
    }

    @Test func duplicateKeepsTheArrivedAmountOfACrossCurrencyTransfer() {
        let original = Txn(
            kind: .cashTransfer, date: Day(year: 2026, month: 3, day: 2), accountID: Fixture.giro.id, counterAccountID: Fixture.dollars.id,
            amount: Money(minor: 100_000, currency: "EUR"), counterAmount: Money(minor: 104_321, currency: "USD"))
        let ledger = Ledger(Fixture.file([original]))
        let copy = TransactionDraft(prefill: TransactionPrefill(copying: original, date: Fixture.today), ledger: ledger, today: Fixture.today).makeTransaction()
        #expect(copy.counterAmount == original.counterAmount && copy.amount == original.amount)
    }
}
