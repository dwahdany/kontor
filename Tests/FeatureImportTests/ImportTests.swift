import Foundation
import Testing
import KontorInterchange
import KontorUI
import KontorSampleData
@testable import FeatureImport

// Tests of the Import feature. This target is only part of the package while the feature is selected
// (KONTOR_FEATURES unset, or containing "Import"):
//
//     KONTOR_FEATURES=Import swift test --scratch-path .build-import --filter FeatureImportTests

private let today = Day(year: 2026, month: 6, day: 30)
private func demo() -> PortfolioFile { SampleData.demoPortfolio(today: today) }

/// A German broker export: two rows that already exist in the demo portfolio, an unknown type,
/// an impossible date, a row without a value and two securities the portfolio does not know.
private let brokerCSV = """
Buchungstag;Umsatzart;Bezeichnung;ISIN;Stück;Kurs;Betrag;Währung;Provision;Steuern;Bemerkung
08.06.2017;Kauf;Meridian Global Equity UCITS ETF (Acc);IEDEMO000116;106;56,36;5.989,10;EUR;14,94;;
10.07.2017;Dividende;Meridian Euro Government Bond UCITS ETF (Dist);IEDEMO000512;30;;17,67;EUR;;6,33;
02.03.2026;Kauf;Meridian Global Equity UCITS ETF (Acc);IEDEMO000116;12;141,20;1.699,30;EUR;4,90;;Sparplan
16.03.2026;Kauf;Nordlicht Clean Energy UCITS ETF;IE00NORD0017;40;23,85;958,90;EUR;4,90;;
01.04.2026;Wertpapierabrechnung;Halvard Europe Dividend UCITS ETF (Dist);IEDEMO000140;25;21,40;539,90;EUR;4,90;;Limit-Order
04.05.2026;Kauf;Alpenrose Pharma AG;CH0ALPEN0042;8;;1.240,00;EUR;9,90;;
11.05.2026;Einzahlung;;;;;2.500,00;EUR;;;Monatliche Einzahlung
29.05.2026;Kauf;Nordlicht Clean Energy UCITS ETF;IE00NORD0017;35;24,10;;EUR;4,90;;Betrag fehlt
31.06.2026;Kauf;Meridian Global Equity UCITS ETF (Acc);IEDEMO000116;5;142,00;714,90;EUR;4,90;;
"""

@MainActor private func pipelineInput(_ file: PortfolioFile) -> CSVPipelineInput {
    var input = CSVPipelineInput(data: Data(brokerCSV.utf8), file: file)
    input.accountID = file.accounts.first?.id
    input.depotID = file.depots.first?.id
    return input
}

@Suite @MainActor struct ImportFeatureTests {
    @Test func moduleRegistersItsScreen() {
        #expect(ImportFeature.module.screen == .`import`)
    }

    @Test func moduleClaimsImportAndExportSheetsOnly() {
        let registry = FeatureRegistry([ImportFeature.module])
        #expect(registry.sheet(for: .importFile(nil)) != nil)
        #expect(registry.sheet(for: .export) != nil)
        #expect(registry.sheet(for: .export(ExportRequest(.transactions()))) != nil)
        #expect(registry.sheet(for: .custom(id: ImportFeature.exportSheetID, payload: ["format": "holdings"])) != nil)
        #expect(registry.sheet(for: .newTransaction) == nil)
        #expect(registry.sheet(for: .custom(id: "allocation.rebalance")) == nil)
    }

    @Test func contributesPaletteCommands() {
        let store = PortfolioStore(file: demo(), today: today)
        let ids = Set(ImportFeature.module.screen == .`import` ? FeatureRegistry([ImportFeature.module]).commands(for: store).map(\.id) : [])
        #expect(ids.contains("import.portfolio-performance"))
        #expect(ids.contains("import.export-holdings"))
        // Nothing to export from an empty document.
        let empty = PortfolioStore(file: PortfolioFile(), today: today)
        #expect(!FeatureRegistry([ImportFeature.module]).commands(for: empty).contains { $0.id.hasPrefix("import.export") })
    }
}

@Suite struct ImportTagTests {
    @Test func roundTrips() {
        let tag = ImportTag(kind: .csv, day: today, fileName: "broker: q2.csv")
        #expect(tag.source == "csv-import:2026-06-30:broker: q2.csv")
        #expect(ImportTag(source: tag.source) == tag)
    }

    @Test func parsesPlainAndForeignTags() {
        #expect(ImportTag(source: "pp-import") == ImportTag(kind: .portfolioPerformance, day: nil, fileName: nil))
        #expect(ImportTag(source: "csv-import")?.source == "csv-import")
        #expect(ImportTag(source: "plan:1234") == nil)
        #expect(ImportTag(source: "") == nil)
    }

    @Test func recentImportsGroupBySourceNewestFirst() {
        var file = demo()
        let older = ImportTag(kind: .portfolioPerformance, day: Day(year: 2026, month: 5, day: 2), fileName: "depot.xml").source
        let newer = ImportTag(kind: .csv, day: today, fileName: "broker.csv").source
        for index in file.transactions.indices where file.transactions[index].source == nil {
            if index % 7 == 0 { file.transactions[index].source = older }
            if index % 11 == 1 { file.transactions[index].source = newer }
        }
        let imports = RecentImport.list(file.transactions)
        #expect(imports.map(\.source) == [newer, older])
        for entry in imports {
            let members = file.transactions.filter { $0.source == entry.source }
            #expect(entry.count == members.count)
            #expect(entry.firstDay == members.map(\.date).min())
            #expect(entry.lastDay == members.map(\.date).max())
            #expect(entry.firstTransactionID == members.min(by: Transaction.chronological)?.id)
        }
        // Plan executions and hand-made entries are not imports.
        #expect(RecentImport.list(demo().transactions).isEmpty)
    }
}

@Suite @MainActor struct CSVPipelineTests {
    @Test func proposesWithStatusesForTheDemoPortfolio() {
        let output = CSVPipeline.run(pipelineInput(demo()))
        #expect(output.target == .transactions)
        #expect(output.dialect.delimiter == ";")
        #expect(output.dialect.decimalSeparator == ",")
        #expect(output.dialect.dateOrder == .dayMonthYear)
        #expect(output.rowCount == 9)
        #expect(output.counts.duplicate == 2)
        #expect(output.counts.error == 2)           // unknown type + 31.06.
        #expect(output.counts.warning == 1)         // value derived from shares × quote
        #expect(output.counts.ok == 4)
        #expect(output.counts.ok + output.counts.warning + output.counts.error + output.counts.duplicate == output.rowCount)
        #expect(output.recommended.count == output.counts.recommended)
        #expect(output.proposal.newSecurities.map(\.isin).sorted() == ["CH0ALPEN0042", "IE00NORD0017"])
        // Rows are flattened with names and amounts.
        let first = output.rows[0]
        #expect(first.status == .duplicate)
        #expect(first.day == Day(year: 2017, month: 6, day: 8))
        #expect(first.amount == Money(minor: 598_910, currency: "EUR"))
        #expect(first.security == "Meridian Global Equity UCITS ETF (Acc)")
        // Error rows keep the file's own words for context.
        let unknown = output.rows[4]
        #expect(unknown.status == .error)
        #expect(unknown.kind == "Wertpapierabrechnung")
        #expect(!unknown.message.isEmpty)
        // The type column's values, with the unknown one flagged.
        #expect(output.typeValues.first { $0.text == "Kauf" }?.automatic == .buy)
        #expect(output.typeValues.first { $0.text == "Kauf" }?.count == 6)
        #expect(output.typeValues.first { $0.text == "Wertpapierabrechnung" }?.resolved == nil)
    }

    @Test func typeAliasTurnsTheUnknownRowIntoABooking() {
        var input = pipelineInput(demo())
        input.target = .transactions
        input.typeAliases = ["wertpapierabrechnung": .buy]
        let output = CSVPipeline.run(input)
        #expect(output.counts.error == 1)
        #expect(output.rows[4].kind == Transaction.Kind.buy.title)
        #expect(output.typeValues.first { $0.text == "Wertpapierabrechnung" }?.resolved == .buy)
    }

    @Test func guessesWhatAFileContains() {
        #expect(CSVPipeline.guessTarget(header: ["Date", "Open", "High", "Low", "Close", "Adj Close", "Volume"]) == .quotes)
        #expect(CSVPipeline.guessTarget(header: ["Datum", "Kurs"]) == .quotes)
        #expect(CSVPipeline.guessTarget(header: ["Name", "ISIN", "Ticker", "Currency"]) == .securities)
        #expect(CSVPipeline.guessTarget(header: ["Buchungstag", "Umsatzart", "Betrag"]) == .transactions)
        #expect(CSVPipeline.guessTarget(header: ["Date", "Type", "Security Name", "Shares", "Value"]) == .transactions)
    }

    @Test func userMappingSurvivesOnlyWhileTheHeaderIsTheSame() {
        let file = demo()
        var input = pipelineInput(file)
        let automatic = CSVPipeline.run(input)
        var mapping = automatic.mapping
        mapping.columns[10] = nil                       // ignore the note column
        input.target = .transactions
        input.mapping = mapping
        input.mappingSignature = automatic.signature
        #expect(CSVPipeline.run(input).mapping == mapping)
        // Reading the file without a header row changes the layout: the mapping is rebuilt.
        var dialect = automatic.dialect
        dialect.headerRecord = nil
        dialect.firstDataRecord = 0
        input.dialect = dialect
        let headerless = CSVPipeline.run(input)
        #expect(headerless.signature != automatic.signature)
        #expect(headerless.rowCount == automatic.rowCount + 1)
    }

    @Test func rememberedLayoutIsAppliedOnTheFirstRunOnly() {
        let file = demo()
        var input = pipelineInput(file)
        let automatic = CSVPipeline.run(input)
        var columns = automatic.mapping.columns
        columns[10] = nil
        let remembered = RememberedMapping(
            target: .transactions, columns: columns, typeAliases: ["Wertpapierabrechnung": .buy], dialect: automatic.dialect,
            accountName: file.accounts[1].name, depotName: file.depots[1].name, savedAt: Date(timeIntervalSince1970: 0))
        input.memory = [automatic.signature: remembered]
        let output = CSVPipeline.run(input)
        #expect(output.usedMemory)
        #expect(output.mapping.columns == columns)
        #expect(output.typeAliases == ["Wertpapierabrechnung": .buy])
        #expect(output.accountID == file.accounts[1].id)
        #expect(output.depotID == file.depots[1].id)
        #expect(output.counts.error == 1)
        // Once the user has decided (target set), memory no longer overrides.
        input.target = .transactions
        #expect(!CSVPipeline.run(input).usedMemory)
    }

    @Test func mappingMemoryKeepsTheNewestLayouts() {
        let memory = MappingMemory.ephemeral()
        #expect(memory.load().isEmpty)
        for index in 0..<(MappingMemory.capacity + 5) {
            memory.remember(
                RememberedMapping(
                    target: .quotes, columns: [.date, .quote], typeAliases: [:], dialect: CSVDialect(), accountName: nil, depotName: nil,
                    savedAt: Date(timeIntervalSince1970: Double(index))),
                for: "layout-\(index)")
        }
        let all = memory.load()
        #expect(all.count == MappingMemory.capacity)
        #expect(all["layout-0"] == nil)
        #expect(all["layout-\(MappingMemory.capacity + 4)"] != nil)
        memory.forget("layout-\(MappingMemory.capacity + 4)")
        #expect(memory.load().count == MappingMemory.capacity - 1)
        #expect(MappingMemory.signature(header: [" Datum", "KURS "], hasHeader: true) == MappingMemory.signature(header: ["datum", "kurs"], hasHeader: true))
        #expect(MappingMemory.signature(header: ["a", "b"], hasHeader: false) == "no-header:2")
    }
}

@Suite @MainActor struct CSVWizardTests {
    private func settle(_ wizard: CSVWizard) async {
        for _ in 0..<400 where wizard.output == nil || wizard.isComputing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func importsInOneStepAndRemembersTheLayout() async {
        let store = PortfolioStore(file: demo(), today: today)
        let memory = MappingMemory.ephemeral()
        let wizard = CSVWizard(store: store, data: Data(brokerCSV.utf8), fileName: "broker.csv", memory: memory)
        wizard.start()
        await settle(wizard)
        #expect(wizard.step == .file)
        #expect(!wizard.usedMemory)
        // Defaults: the first depot and its reference account.
        #expect(wizard.depotID == store.file.depots[0].id)
        #expect(wizard.accountID == store.file.depots[0].referenceAccountID)
        #expect(wizard.importCount == 5)
        #expect(wizard.blockingReason == nil)
        #expect(wizard.unrecognizedTypeCount == 1)

        // Teach the unknown type: one more row becomes importable and is selected.
        wizard.setAlias(.buy, for: "Wertpapierabrechnung")
        await settle(wizard)
        #expect(wizard.importCount == 6)
        #expect(wizard.unrecognizedTypeCount == 0)

        // Tick a duplicate, untick it again.
        let duplicate = wizard.output!.rows.first { $0.status == .duplicate }!
        wizard.toggle([duplicate.id])
        #expect(wizard.importCount == 7)
        wizard.toggle([duplicate.id])
        #expect(wizard.importCount == 6)
        // Errors cannot be selected.
        let error = wizard.output!.rows.first { $0.status == .error }!
        wizard.toggle([error.id])
        #expect(wizard.importCount == 6)

        let before = store.file
        let revision = store.revision
        await wizard.performImport()
        #expect(wizard.step == .done)
        #expect(store.revision == revision + 1)               // exactly one mutation = one undo step
        #expect(store.file.transactions.count == before.transactions.count + 6)
        #expect(store.file.securities.count == before.securities.count + 2)
        let imported = store.file.transactions.filter { $0.source == "csv-import:2026-06-30:broker.csv" }
        #expect(imported.count == 6)
        #expect(wizard.outcome?.imported == 6)
        #expect(wizard.outcome?.newSecurities == 2)
        #expect(wizard.outcome?.route == .transaction(imported.min(by: Transaction.chronological)!.id))
        #expect(RecentImport.list(store.file.transactions).first?.count == 6)

        // The same layout again: recognised, starts at the review, and everything is a duplicate now.
        let second = CSVWizard(store: store, data: Data(brokerCSV.utf8), fileName: "broker.csv", memory: memory)
        second.start()
        await settle(second)
        #expect(second.usedMemory)
        #expect(second.step == .review)
        #expect(second.unrecognizedTypeCount == 0)
        #expect(second.output?.counts.duplicate == 8)
        #expect(second.importCount == 0)
        #expect(second.blockingReason != nil)
    }

    @Test func quotesNeedASecurity() async {
        let store = PortfolioStore(file: demo(), today: today)
        let csv = "Date,Close\n2026-07-01,144.40\n2026-07-02,145.10\n"
        let wizard = CSVWizard(store: store, data: Data(csv.utf8), fileName: "quotes.csv", memory: .ephemeral())
        wizard.start()
        await settle(wizard)
        #expect(wizard.currentTarget == .quotes)
        #expect(wizard.blockingReason != nil)
        let security = store.file.securities[0]
        wizard.setSecurity(security.id)
        await settle(wizard)
        #expect(wizard.blockingReason == nil)
        #expect(wizard.importCount == 2)
        await wizard.performImport()
        let updated = store.security(security.id)!
        #expect(updated.prices.count == security.prices.count + 2)
        #expect(updated.prices.price(on: Day(year: 2026, month: 7, day: 2)) == Price(145.10))
        #expect(wizard.outcome?.route == .security(security.id))
    }

    @Test func changingTheDialectReparses() async {
        let store = PortfolioStore(file: demo(), today: today)
        let wizard = CSVWizard(store: store, data: Data(brokerCSV.utf8), fileName: "broker.csv", memory: .ephemeral())
        wizard.start()
        await settle(wizard)
        #expect(wizard.output?.header.count == 11)
        wizard.setDialect { $0.delimiter = "," }
        await settle(wizard)
        #expect(wizard.isDialectOverridden)
        #expect(wizard.output?.header.count != 11)
        wizard.resetDialect()
        await settle(wizard)
        #expect(!wizard.isDialectOverridden)
        #expect(wizard.output?.header.count == 11)
        wizard.setHasHeader(false)
        await settle(wizard)
        #expect(wizard.output?.rowCount == 10)
        #expect(wizard.output?.header.first == "Column 1")
        wizard.setHasHeader(true)
        await settle(wizard)
        #expect(wizard.output?.rowCount == 9)
    }
}

@Suite struct PortfolioMergeTests {
    @Test func mergingAFileIntoItselfChangesNothing() {
        let file = demo()
        let result = PortfolioMerge.merge(file, into: file)
        #expect(result.summary.changesNothing)
        #expect(result.summary.skippedTransactions == file.transactions.count)
        #expect(result.summary.matchedSecurities == file.securities.count)
        #expect(result.file == file)
    }

    @Test func mergingIntoAnEmptyFileAddsEverything() {
        let file = demo()
        let result = PortfolioMerge.merge(file, into: PortfolioFile())
        #expect(result.summary.addedTransactions == file.transactions.count)
        #expect(result.summary.addedSecurities == file.securities.count)
        #expect(result.file.transactions == file.transactions)
        #expect(result.file.securities == file.securities)
        #expect(result.file.taxonomies == file.taxonomies)
        #expect(result.file.plans == file.plans)
    }

    @Test func matchesEntitiesWithOtherIDsAndRepointsReferences() {
        let existing = demo()
        // The "same" portfolio as another tool would write it: new ids everywhere, plus one new booking and one new security.
        var incoming = existing
        var securityIDs: [UUID: UUID] = [:], accountIDs: [UUID: UUID] = [:], depotIDs: [UUID: UUID] = [:]
        for index in incoming.securities.indices {
            let id = UUID()
            securityIDs[incoming.securities[index].id] = id
            incoming.securities[index].id = id
        }
        for index in incoming.accounts.indices {
            let id = UUID()
            accountIDs[incoming.accounts[index].id] = id
            incoming.accounts[index].id = id
        }
        for index in incoming.depots.indices {
            let id = UUID()
            depotIDs[incoming.depots[index].id] = id
            incoming.depots[index].id = id
            incoming.depots[index].referenceAccountID = incoming.depots[index].referenceAccountID.flatMap { accountIDs[$0] }
        }
        for index in incoming.transactions.indices {
            incoming.transactions[index].id = UUID()
            incoming.transactions[index].securityID = incoming.transactions[index].securityID.flatMap { securityIDs[$0] }
            incoming.transactions[index].accountID = incoming.transactions[index].accountID.flatMap { accountIDs[$0] }
            incoming.transactions[index].counterAccountID = incoming.transactions[index].counterAccountID.flatMap { accountIDs[$0] }
            incoming.transactions[index].depotID = incoming.transactions[index].depotID.flatMap { depotIDs[$0] }
            incoming.transactions[index].counterDepotID = incoming.transactions[index].counterDepotID.flatMap { depotIDs[$0] }
        }
        let newSecurity = Security(name: "Nordlicht Clean Energy UCITS ETF", currency: "EUR", isin: "IE00NORD0017")
        incoming.securities.append(newSecurity)
        incoming.transactions.append(Transaction(
            kind: .buy, date: today, accountID: incoming.accounts[0].id, depotID: incoming.depots[0].id, securityID: newSecurity.id,
            shares: Shares(10), amount: Money(minor: 25_000, currency: "EUR")))
        incoming.transactions.append(Transaction(
            kind: .deposit, date: today, accountID: incoming.accounts[0].id, amount: Money(minor: 100_000, currency: "EUR")))
        incoming.taxonomies = []
        incoming.plans = []
        incoming.watchlists = []

        let result = PortfolioMerge.merge(incoming, into: existing)
        #expect(result.summary.addedSecurities == 1)
        #expect(result.summary.matchedSecurities == existing.securities.count)
        #expect(result.summary.addedAccounts == 0)
        #expect(result.summary.addedDepots == 0)
        #expect(result.summary.addedTransactions == 2)
        #expect(result.summary.skippedTransactions == existing.transactions.count)
        #expect(result.summary.addedPrices == 0)
        #expect(result.addedTransactionIDs.count == 2)
        // The new bookings point at the EXISTING account and depot.
        let added = result.file.transactions.suffix(2)
        #expect(added.allSatisfy { $0.accountID == existing.accounts[0].id })
        #expect(added.first?.depotID == existing.depots[0].id)
        #expect(added.first?.securityID == newSecurity.id)
        // Nothing that existed was touched.
        #expect(Array(result.file.transactions.prefix(existing.transactions.count)) == existing.transactions)
        #expect(Array(result.file.securities.prefix(existing.securities.count)) == existing.securities)
    }

    @Test func aDifferentISINNeverMatchesByName() {
        var existing = PortfolioFile()
        existing.securities = [Security(name: "ACME", currency: "EUR", isin: "DE0000000001", ticker: "ACM")]
        var incoming = PortfolioFile()
        incoming.securities = [Security(name: "ACME", currency: "EUR", isin: "US0000000002", ticker: "ACM")]
        #expect(PortfolioMerge.merge(incoming, into: existing).summary.addedSecurities == 1)
        incoming.securities[0].isin = ""
        #expect(PortfolioMerge.merge(incoming, into: existing).summary.matchedSecurities == 1)
    }

    @Test func mergedQuotesNeverOverwriteExistingDays() {
        var existing = PortfolioFile()
        var security = Security(name: "ACME", currency: "EUR", isin: "DE0000000001")
        security.prices = PriceSeries([PricePoint(day: today, price: Price(10))])
        existing.securities = [security]
        var incoming = existing
        incoming.securities[0].prices = PriceSeries([
            PricePoint(day: today, price: Price(99)), PricePoint(day: today.advanced(by: -1), price: Price(9)),
        ])
        let result = PortfolioMerge.merge(incoming, into: existing)
        #expect(result.summary.addedPrices == 1)
        #expect(result.file.securities[0].prices.price(on: today) == Price(10))
        #expect(result.file.securities[0].prices.count == 2)
    }
}

@Suite struct ImportLoaderTests {
    @Test func readsPortfolioPerformanceXMLAndTagsTheLedger() throws {
        let file = demo()
        let xml = PortfolioPerformanceExporter.export(file).data
        guard case .portfolioPerformance(let result) = ImportLoader.load(xml, fileName: "depot.xml", into: PortfolioFile(), today: today) else {
            Issue.record("expected a Portfolio Performance result")
            return
        }
        #expect(result.report.counts.transactions == file.transactions.count)
        #expect(result.report.counts.securities == file.securities.count)
        #expect(result.file.transactions.count == file.transactions.count)
        #expect(result.firstDay == file.transactions.map(\.date).min())
        #expect(result.lastDay == file.transactions.map(\.date).max())
        #expect(result.kinds.reduce(0) { $0 + $1.count } == file.transactions.count)
        #expect(result.kinds.first!.count >= result.kinds.last!.count)
        #expect(result.mergePreview == nil)                       // the target is empty
        // Plan executions keep their plan tag; everything else carries this import's tag.
        let planned = file.transactions.count { $0.source?.hasPrefix("plan:") == true }
        #expect(result.file.transactions.count { $0.source?.hasPrefix("plan:") == true } == planned)
        #expect(result.file.transactions.count { $0.source == "pp-import:2026-06-30:depot.xml" } == file.transactions.count - planned)

        // Into the same portfolio: the preview says nothing would be added.
        guard case .portfolioPerformance(let again) = ImportLoader.load(xml, fileName: "depot.xml", into: file, today: today) else {
            Issue.record("expected a Portfolio Performance result")
            return
        }
        #expect(again.mergePreview?.addedTransactions == 0)
        #expect(again.mergePreview?.skippedTransactions == file.transactions.count)
        #expect(again.mergePreview?.addedSecurities == 0)
    }

    @Test func classifiesOtherFiles() throws {
        let blank = PortfolioFile()
        if case .csv = ImportLoader.load(Data(brokerCSV.utf8), fileName: "broker.csv", into: blank, today: today) {} else {
            Issue.record("expected CSV")
        }
        if case .kontorDocument = ImportLoader.load(try demo().encoded(), fileName: "demo.kontor", into: blank, today: today) {} else {
            Issue.record("expected a Kontor document")
        }
        if case .unreadable(let format, _, let advice) = ImportLoader.load(Data("PORTFOLIO\u{1}\u{2}\u{3}secret".utf8), fileName: "x.portfolio", into: blank, today: today) {
            #expect(format == .portfolioPerformanceEncrypted)
            #expect(advice.contains("XML"))
        } else {
            Issue.record("expected an encrypted file")
        }
        if case .failed = ImportLoader.load(Data(), fileName: "empty.csv", into: blank, today: today) {} else {
            Issue.record("expected a failure for an empty file")
        }
        if case .failed = ImportLoader.load(URL(fileURLWithPath: "/nonexistent/kontor-test.csv"), into: blank, today: today) {} else {
            Issue.record("expected a failure for a missing file")
        }
    }
}

@Suite @MainActor struct ExportTests {
    @Test func transactionsCSVReimportsAsDuplicates() {
        let file = demo()
        for format in [CSVExportFormat.international, .german] {
            var options = ExportOptions()
            options.format = .transactions
            options.csv = format
            let result = ExportBuilder.build(options, file: file, holdings: nil)
            #expect(result.problem == nil)
            #expect(result.rowCount == file.transactions.count)
            #expect(result.previewLines.count == ExportBuilder.previewLineCount)
            var input = CSVPipelineInput(data: result.data!, file: file)
            input.accountID = file.accounts.first?.id
            input.depotID = file.depots.first?.id
            let output = CSVPipeline.run(input)
            #expect(output.rowCount == file.transactions.count)
            #expect(output.counts.error == 0)
            #expect(output.counts.duplicate == file.transactions.count)
        }
    }

    @Test func selectionRestrictsTheTransactionExport() {
        let file = demo()
        var options = ExportOptions()
        options.format = .transactions
        options.transactionIDs = Set(file.transactions.prefix(7).map(\.id))
        #expect(ExportBuilder.build(options, file: file, holdings: nil).rowCount == 7)
        options.onlySelection = false
        #expect(ExportBuilder.build(options, file: file, holdings: nil).rowCount == file.transactions.count)
    }

    @Test func holdingsExportAddsUpToTheEngineSnapshot() async throws {
        let store = PortfolioStore(file: demo(), today: today)
        let holdings = try await store.analyze("import.export.holdings") { analysis in HoldingsExport(analysis) }
        let snapshot = store.ledger.snapshot(on: today)
        #expect(holdings.day == today)
        #expect(holdings.total == snapshot.totalValue)
        #expect(holdings.positions.count == snapshot.positions.count)
        // Rows add up exactly to the engine's total (positions + cash), and shares of the whole to 100 %.
        let sum = holdings.positions.reduce(0) { $0 + $1.value.minor } + holdings.cash.reduce(0) { $0 + $1.value.minor }
        #expect(sum == snapshot.totalValue.minor)
        let shares = holdings.positions.compactMap(\.share).reduce(0, +) + holdings.cash.compactMap(\.share).reduce(0, +)
        #expect(abs(shares - 1) < 1e-9)
        for position in holdings.positions {
            #expect(position.gain.minor == position.value.minor - position.costBasis.minor)
        }

        var options = ExportOptions()
        options.format = .holdings
        let result = ExportBuilder.build(options, file: store.file, holdings: holdings)
        #expect(result.rowCount == holdings.positions.count + holdings.cash.count)
        let text = String(decoding: result.data!, as: UTF8.self)
        #expect(text.hasPrefix("Type,Name,ISIN,WKN,Ticker Symbol,Shares,Quote,Quote Date,Currency,Market Value,Market Value (EUR)"))
        // Percentages are written once as percent numbers: the first position's share.
        let firstShare = holdings.positions[0].share!
        let cells = text.split(whereSeparator: \.isNewline)[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(abs(Double(cells.last!)! - firstShare * 100) < 0.006)
        // German notation: semicolons, decimal commas, German titles.
        options.csv = .german
        let german = String(decoding: ExportBuilder.build(options, file: store.file, holdings: holdings).data!, as: UTF8.self)
        #expect(german.hasPrefix("Art;Name;ISIN;WKN;Ticker-Symbol;Stück;Kurs;Kursdatum"))
    }

    @Test func wholePortfolioFormatsRoundTrip() throws {
        let file = demo()
        var options = ExportOptions()
        options.format = .json
        let json = ExportBuilder.build(options, file: file, holdings: nil)
        #expect(try PortfolioFile(data: json.data!) == file)
        #expect(json.previewLines.first == "{")
        options.format = .portfolioPerformance
        let xml = ExportBuilder.build(options, file: file, holdings: nil)
        #expect(try PortfolioPerformanceImporter.read(xml.data!, name: file.name).file.transactions.count == file.transactions.count)
        #expect(FileFormat.detect(data: xml.data!, filename: "x.xml") == .portfolioPerformanceXML)
    }

    @Test func quotesNeedASecurityAndFileNamesAreDescriptive() {
        let file = demo()
        var options = ExportOptions()
        options.format = .quotes
        #expect(ExportBuilder.build(options, file: file, holdings: nil).problem != nil)
        options.securityID = file.securities[0].id
        #expect(ExportBuilder.build(options, file: file, holdings: nil).rowCount == file.securities[0].prices.count)
        #expect(ExportBuilder.fileName(options, file: file, today: today).hasSuffix(".csv"))
        options.format = .holdings
        #expect(ExportBuilder.fileName(options, file: file, today: today) == "\(file.name) Holdings 2026-06-30.csv")
        options.format = .portfolioPerformance
        #expect(ExportBuilder.fileName(options, file: PortfolioFile(), today: today) == "Portfolio (Portfolio Performance).xml")
        #expect(CSVPreset(.german) == .german)
        #expect(CSVPreset(.international) == .international)
        var custom = CSVExportFormat.german
        custom.delimiter = "\t"
        #expect(CSVPreset(custom) == .custom)
        #expect(ExportFormat(.transactions(only: nil)) == .transactions)
        #expect(ExportFormat(.portfolio) == .json)
        #expect(!ExportBuilder.isHeavy(file))
    }
}

// MARK: - Regression tests for the review findings

private func starter() -> PortfolioFile { SampleData.starterPortfolio(name: "My Portfolio", baseCurrency: "EUR") }

private func assignmentCount(_ classifications: [Classification]) -> Int {
    classifications.reduce(0) { $0 + $1.assignments.count + assignmentCount($1.children) }
}

/// The demo portfolio as a Portfolio Performance file, loaded for import into `current`.
private func demoAsPortfolioPerformance(into current: PortfolioFile) -> PortfolioPerformanceResult? {
    let xml = PortfolioPerformanceExporter.export(demo()).data
    guard case .portfolioPerformance(let result) = ImportLoader.load(xml, fileName: "demo-pp.xml", into: current, today: today) else {
        Issue.record("expected a Portfolio Performance result")
        return nil
    }
    return result
}

@Suite struct UntouchedPortfolioTests {
    @Test func aNewPortfolioIsUntouchedUntilSomethingIsRecorded() {
        #expect(PortfolioFile().isUntouched)
        #expect(starter().isUntouched)                    // what "New Portfolio" creates
        #expect(!starter().isBlank)
        #expect(!demo().isUntouched)

        var file = starter()
        file.transactions = [Transaction(kind: .deposit, date: today, accountID: file.accounts[0].id, amount: Money(minor: 100, currency: "EUR"))]
        #expect(!file.isUntouched)
        file = starter()
        file.securities = [Security(name: "ACME", currency: "EUR")]
        #expect(!file.isUntouched)
        file = starter()
        file.accounts.append(Account(name: "Second", currency: "USD"))    // a hand-made setup is merged into, not replaced
        #expect(!file.isUntouched)
        file = starter()
        file.taxonomies[0].root[0].assignments = [Classification.Assignment(accountID: file.accounts[0].id)]
        #expect(!file.isUntouched)
    }

    @Test func importIntoANewPortfolioReplacesTheTemplate() throws {
        let target = starter()
        let result = try #require(demoAsPortfolioPerformance(into: target))
        // The main migration path: no merge, the file becomes the content.
        #expect(result.mergePreview == nil)
        let file = PortfolioReplace.apply(result.file, to: target)
        #expect(file.name == "My Portfolio")
        #expect(file.accounts.map(\.name) == demo().accounts.map(\.name))          // no "Cash Account" stub left behind
        #expect(file.depots.map(\.name) == demo().depots.map(\.name))
        #expect(file.settings.baseCurrency == result.file.settings.baseCurrency)
        #expect(file.transactions.count == demo().transactions.count)
        // Every taxonomy of the file arrives with its assignments.
        #expect(file.taxonomies.map(\.name) == result.file.taxonomies.map(\.name))
        #expect(file.taxonomies.allSatisfy { assignmentCount($0.root) > 0 })
        // The portfolio keeps its dashboard, now pointing at the imported taxonomy of the same name.
        #expect(file.dashboards.count == target.dashboards.count)
        let widget = try #require(file.dashboards.first?.widgets.first { $0.kind == "allocation" })
        let imported = try #require(file.taxonomies.first { $0.name == target.taxonomies[0].name })
        #expect(widget.config["taxonomy"] == imported.id.uuidString)
    }

    @Test func aFileWithoutTaxonomiesKeepsTheTemplates() {
        var imported = PortfolioFile(name: "From PP")
        imported.securities = [Security(name: "ACME", currency: "EUR")]
        let target = starter()
        let file = PortfolioReplace.apply(imported, to: target)
        #expect(file.taxonomies == target.taxonomies)
        #expect(file.dashboards == target.dashboards)
        #expect(file.securities == imported.securities)
        #expect(PortfolioReplace.apply(imported, to: PortfolioFile()).name == "From PP")
    }
}

@Suite struct PortfolioMergeRegressionTests {
    /// A new portfolio that is no longer untouched (one deposit), so that an import merges.
    private func usedStarter() -> PortfolioFile {
        var file = starter()
        file.transactions = [Transaction(kind: .deposit, date: today, accountID: file.accounts[0].id, amount: Money(minor: 100, currency: "EUR"))]
        return file
    }

    @Test func sameNamedTaxonomiesReceiveTheAssignments() throws {
        let target = usedStarter()
        let result = try #require(demoAsPortfolioPerformance(into: target))
        let preview = try #require(result.mergePreview)
        let merged = PortfolioMerge.merge(result.file, into: target, recordAs: result.tag.source)
        // "Asset Classes" and "Regions" exist in both; before the fix both ended up with 0 assignments.
        #expect(merged.file.taxonomies.count == 3)
        for taxonomy in merged.file.taxonomies {
            let incoming = try #require(result.file.taxonomies.first { $0.name == taxonomy.name })
            #expect(assignmentCount(taxonomy.root) == assignmentCount(incoming.root), "\(taxonomy.name)")
        }
        #expect(merged.summary.addedTaxonomies == 1)
        #expect(merged.summary.mergedTaxonomies == 2)
        #expect(merged.summary.skippedTaxonomies == 0)
        #expect(merged.summary.addedAssignments > 0)
        #expect(preview.mergedTaxonomies == 2)
        // The summary says so.
        let text = PortfolioPerformanceSummary.describe(merged.summary)
        #expect(text.contains("1 taxonomy"))
        #expect(text.contains("in 2 existing taxonomies"))
        // No classification is duplicated: the template's nodes were matched by name.
        let names = merged.file.taxonomies[0].root.map(\.name)
        #expect(Set(names).count == names.count)
        // Merging the same file again changes nothing.
        let again = PortfolioMerge.merge(result.file, into: merged.file, recordAs: result.tag.source)
        #expect(again.summary.changesNothing)
        #expect(again.summary.skippedTaxonomies == 3)
        #expect(again.file == merged.file)
        #expect(PortfolioPerformanceSummary.describe(again.summary).contains("3 taxonomies already have everything"))
    }

    @Test func existingClassificationsWinAndNewNodesAreAdded() {
        let a = Security(name: "A", currency: "EUR", isin: "DE000000000A"), b = Security(name: "B", currency: "EUR", isin: "DE000000000B")
        var existing = PortfolioFile()
        existing.securities = [a]
        existing.taxonomies = [Taxonomy(name: "Asset Classes", root: [
            Classification(name: "Equity", assignments: [.init(securityID: a.id)]),
            Classification(name: "Bonds"),
        ])]
        var incoming = PortfolioFile()
        incoming.securities = [a, b]
        incoming.taxonomies = [Taxonomy(name: "asset classes ", root: [
            Classification(name: "Bonds", assignments: [.init(securityID: a.id)]),          // the user already classified A: ignored
            Classification(name: "EQUITY", children: [Classification(name: "Europe", assignments: [.init(securityID: b.id, weight: 6_000)])]),
            Classification(name: "Commodities", assignments: [.init(securityID: b.id, weight: 4_000)]),
        ])]
        let result = PortfolioMerge.merge(incoming, into: existing)
        let root = result.file.taxonomies[0].root
        #expect(result.file.taxonomies.count == 1)
        #expect(root.map(\.name) == ["Equity", "Bonds", "Commodities"])
        #expect(root[0].assignments == [.init(securityID: a.id)])
        #expect(root[0].children.map(\.name) == ["Europe"])
        #expect(root[0].children[0].assignments == [.init(securityID: b.id, weight: 6_000)])
        #expect(root[1].assignments.isEmpty)
        #expect(root[2].assignments == [.init(securityID: b.id, weight: 4_000)])
        #expect(result.summary.mergedTaxonomies == 1)
        #expect(result.summary.addedAssignments == 1)             // one security, split over two classifications
        #expect(!result.summary.changesNothing)
    }

    @Test func aListingInAnotherCurrencyIsAnotherSecurity() {
        // Existing EUR listing with a quote; the file brings the USD listing of the same ISIN.
        var existing = PortfolioFile()
        var eur = Security(name: "ACME", currency: "EUR", isin: "US0000000001", ticker: "ACM")
        eur.prices = PriceSeries([PricePoint(day: today.advanced(by: -1), price: Price(90))])
        existing.securities = [eur]
        existing.accounts = [Account(name: "Cash", currency: "USD")]
        existing.depots = [Depot(name: "Depot")]
        var incoming = PortfolioFile()
        var usd = Security(name: "ACME", currency: "USD", isin: "US0000000001", ticker: "ACM")
        usd.prices = PriceSeries([PricePoint(day: today, price: Price(100))])
        incoming.securities = [usd]
        incoming.accounts = existing.accounts
        incoming.depots = existing.depots
        incoming.transactions = [Transaction(
            kind: .buy, date: today, accountID: existing.accounts[0].id, depotID: existing.depots[0].id, securityID: usd.id,
            shares: Shares(5), amount: Money(minor: 50_000, currency: "USD"))]
        let result = PortfolioMerge.merge(incoming, into: existing)
        #expect(result.summary.addedSecurities == 1)
        #expect(result.summary.matchedSecurities == 0)
        #expect(result.summary.securityMatches.isEmpty)
        // The EUR price series stays a EUR price series, and the USD shares are booked on the USD listing.
        #expect(result.file.securities.map(\.currency) == ["EUR", "USD"])
        #expect(result.file.securities[0].prices.count == 1)
        #expect(result.file.securities[1].prices.price(on: today) == Price(100))
        #expect(result.file.transactions[0].securityID == result.file.securities[1].id)
    }

    @Test func twoListingsOfOneISINInTheFileStaySeparate() {
        var incoming = PortfolioFile()
        let xetra = Security(name: "ACME (Xetra)", currency: "EUR", isin: "US0000000001")
        let nyse = Security(name: "ACME (NYSE)", currency: "USD", isin: "US0000000001")
        let frankfurt = Security(name: "ACME (Frankfurt)", currency: "EUR", isin: "US0000000001")
        incoming.securities = [xetra, nyse, frankfurt]
        incoming.transactions = [xetra, nyse, frankfurt].map {
            Transaction(kind: .deliveryIn, date: today, securityID: $0.id, shares: Shares(1), amount: Money(minor: 100, currency: $0.currency))
        }
        // Into a new portfolio: nothing collapses (before the fix the USD buy landed on the EUR listing).
        var result = PortfolioMerge.merge(incoming, into: starter())
        #expect(result.summary.addedSecurities == 3)
        #expect(Set(result.file.transactions.compactMap(\.securityID)).count == 3)
        // Into a portfolio that has one EUR listing: exactly one incoming security is matched to it.
        var existing = PortfolioFile()
        existing.securities = [Security(name: "ACME", currency: "EUR", isin: "US0000000001")]
        result = PortfolioMerge.merge(incoming, into: existing)
        #expect(result.summary.matchedSecurities == 1)
        #expect(result.summary.addedSecurities == 2)
        #expect(result.summary.securityMatches.map(\.incomingName) == ["ACME (Xetra)"])
        #expect(result.summary.securityMatches.first?.rule == .isin)
        #expect(Set(result.file.transactions.compactMap(\.securityID)).count == 3)
    }

    @Test func matchesSayHowTheyWereFoundWeakestFirst() {
        var existing = PortfolioFile()
        existing.securities = [
            Security(name: "Alpha", currency: "EUR", isin: "DE0000000001"),
            Security(name: "Beta", currency: "EUR", ticker: "BET"),
            Security(name: "Gamma", currency: "EUR"),
            Security(name: "Delta", currency: "USD", ticker: "DLT"),
        ]
        var incoming = PortfolioFile()
        incoming.securities = [
            Security(name: "Alpha AG", currency: "EUR", isin: "DE0000000001"),
            Security(name: "Beta Corp", currency: "EUR", isin: "US00000000B2", ticker: "bet"),
            Security(name: "gamma", currency: "EUR"),
            Security(name: "Delta", currency: "EUR", ticker: "DLT"),            // ticker and name agree, the currency does not
        ]
        let summary = PortfolioMerge.merge(incoming, into: existing).summary
        #expect(summary.securityMatches.map(\.rule) == [.name, .ticker, .isin])
        #expect(summary.securityMatches.map(\.existingName) == ["Gamma", "Beta", "Alpha"])
        #expect(summary.securityMatches[1].identifier == "bet")
        #expect(summary.addedSecurities == 1)
    }

    @Test func recentImportsCoverThePlanExecutionsOfAnImport() throws {
        let file = demo()
        let planned = file.transactions.count { $0.source?.hasPrefix("plan:") == true }
        #expect(planned > 0)

        // 1. Import into a new portfolio (the file becomes the content).
        let result = try #require(demoAsPortfolioPerformance(into: starter()))
        let imported = PortfolioReplace.apply(result.file, to: starter())
        var list = RecentImport.list(imported.transactions, preferences: imported.settings.preferences)
        #expect(list.map(\.source) == [result.tag.source])
        #expect(list.first?.count == file.transactions.count)                    // was 432 of 649
        #expect(list.first?.firstDay == file.transactions.map(\.date).min())
        // Without the document's settings only the tagged entries are known.
        #expect(RecentImport.list(imported.transactions).first?.count == file.transactions.count - planned)
        // Plans still find their executions: the tags themselves are untouched.
        #expect(imported.transactions.count { $0.source?.hasPrefix("plan:") == true } == planned)

        // Taking the import back removes all of it — and nothing else.
        var after = imported
        let own = Transaction(kind: .deposit, date: today, accountID: after.accounts[0].id, amount: Money(minor: 100, currency: "EUR"))
        // A later execution booked in Kontor for one of the imported plans is not part of the import.
        let later = Transaction(
            kind: .deposit, date: today.advanced(by: 40), accountID: after.accounts[0].id, amount: Money(minor: 100, currency: "EUR"),
            source: imported.transactions.first { $0.source?.hasPrefix("plan:") == true }?.source)
        after.transactions += [own, later]
        #expect(RecentImport.list(after.transactions, preferences: after.settings.preferences).first?.count == file.transactions.count)
        #expect(RecentImport.remove(result.tag.source, from: &after) == file.transactions.count)
        #expect(after.transactions == [own, later])
        #expect(after.settings.preferences.keys.allSatisfy { !$0.hasPrefix(ImportRecord.keyPrefix) })
        #expect(RecentImport.list(after.transactions, preferences: after.settings.preferences).isEmpty)

        // 2. Merged into a portfolio in use: the same holds.
        let target = usedStarter()
        let merged = PortfolioMerge.merge(result.file, into: target, recordAs: result.tag.source).file
        list = RecentImport.list(merged.transactions, preferences: merged.settings.preferences)
        #expect(list.first?.count == file.transactions.count)
        var undone = merged
        RecentImport.remove(result.tag.source, from: &undone)
        #expect(undone.transactions == target.transactions)
    }

    @Test func executionsFollowAPlanThatAlreadyExists() {
        let security = Security(name: "ACME", currency: "EUR", isin: "DE0000000001")
        let account = Account(name: "Cash", currency: "EUR"), depot = Depot(name: "Depot")
        var existing = PortfolioFile()
        existing.securities = [security]; existing.accounts = [account]; existing.depots = [depot]
        let plan = InvestmentPlan(
            name: "Monthly", kind: .purchase, securityID: security.id, depotID: depot.id, accountID: account.id,
            amount: Money(minor: 10_000, currency: "EUR"), start: today.advanced(by: -90))
        existing.plans = [plan]
        var incoming = existing
        var theirs = plan
        theirs.id = UUID()                                   // the same plan as another tool wrote it
        incoming.plans = [theirs]
        incoming.transactions = [Transaction(
            kind: .buy, date: today, accountID: account.id, depotID: depot.id, securityID: security.id, shares: Shares(1),
            amount: Money(minor: 10_000, currency: "EUR"), source: "plan:\(theirs.id.uuidString)")]
        let result = PortfolioMerge.merge(incoming, into: existing, recordAs: "pp-import:2026-06-30:x.xml")
        #expect(result.summary.addedPlans == 0)
        #expect(result.file.plans == [plan])
        #expect(result.file.transactions.first?.source == "plan:\(plan.id.uuidString)")
        let record = ImportRecord.all(in: result.file.settings.preferences)["pp-import:2026-06-30:x.xml"]
        #expect(record == ImportRecord(planIDs: [plan.id], through: today))
        // A plan of the same name for another security is a different plan.
        var other = incoming
        other.securities.append(Security(name: "Other", currency: "EUR", isin: "DE0000000002"))
        other.plans[0].securityID = other.securities[1].id
        #expect(PortfolioMerge.merge(other, into: existing).summary.addedPlans == 1)
    }

    @Test func importRecordRoundTrips() {
        let record = ImportRecord(planIDs: [UUID(), UUID()], through: today)
        #expect(ImportRecord(value: record.value) == record)
        #expect(ImportRecord(value: "") == nil)
        #expect(ImportRecord(value: "2026-06-30|") == nil)
        #expect(ImportRecord(value: "nonsense|\(UUID().uuidString)") == nil)
        var preferences: [String: String] = ["pp.bookmarks": "[]"]
        record.write(for: "pp-import:2026-06-30:a.xml", to: &preferences)
        let more = ImportRecord(planIDs: [UUID()], through: today.advanced(by: 3))
        more.write(for: "pp-import:2026-06-30:a.xml", to: &preferences)
        let stored = ImportRecord.all(in: preferences)
        #expect(stored.count == 1)
        #expect(stored["pp-import:2026-06-30:a.xml"]?.planIDs.count == 3)
        #expect(stored["pp-import:2026-06-30:a.xml"]?.through == today.advanced(by: 3))
        #expect(ImportRecord(planExecutionsIn: demo().transactions.filter { $0.source == nil }) == nil)
    }
}

@Suite @MainActor struct CSVRegressionTests {
    private func settle(_ wizard: CSVWizard) async {
        for _ in 0..<400 where wizard.output == nil || wizard.isComputing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aHintOfTheSameKindStillUsesTheRememberedLayout() {
        let file = demo()
        var input = pipelineInput(file)
        let automatic = CSVPipeline.run(input)
        var columns = automatic.mapping.columns
        columns[10] = nil
        input.memory = [automatic.signature: RememberedMapping(
            target: .transactions, columns: columns, typeAliases: ["Wertpapierabrechnung": .buy], dialect: automatic.dialect,
            accountName: file.accounts[1].name, depotName: nil, savedAt: Date(timeIntervalSince1970: 0))]
        // "Transactions from a Broker or Bank ▸ Choose CSV…": the main entry point for broker files.
        input.targetHint = .transactions
        let hinted = CSVPipeline.run(input)
        #expect(hinted.usedMemory)
        #expect(hinted.mapping.columns == columns)
        #expect(hinted.typeAliases == ["Wertpapierabrechnung": .buy])
        #expect(hinted.accountID == file.accounts[1].id)
        // A hint of another kind wins over the memory (the user asked for quotes).
        input.targetHint = .quotes
        let other = CSVPipeline.run(input)
        #expect(!other.usedMemory)
        #expect(other.target == .quotes)
        // Without memory the hint decides the content.
        input.memory = [:]
        input.targetHint = .securities
        #expect(CSVPipeline.run(input).target == .securities)
    }

    @Test func theWizardAppliesARememberedLayoutWhenStartedWithAHint() async {
        let store = PortfolioStore(file: demo(), today: today)
        let memory = MappingMemory.ephemeral()
        let first = CSVWizard(store: store, data: Data(brokerCSV.utf8), fileName: "broker.csv", memory: memory)
        first.start(target: .transactions)
        await settle(first)
        #expect(first.currentTarget == .transactions)
        first.setAlias(.buy, for: "Wertpapierabrechnung")
        await settle(first)
        await first.performImport()
        let second = CSVWizard(store: store, data: Data(brokerCSV.utf8), fileName: "broker.csv", memory: memory)
        second.start(target: .transactions)
        await settle(second)
        #expect(second.usedMemory)
        #expect(second.step == .review)
        #expect(second.unrecognizedTypeCount == 0)
    }

    @Test func twoQuickChangesBothCount() async {
        let csv = "A;B;C\n2026-06-01;1,5;x\n2026-06-02;2,5;y\n"
        let store = PortfolioStore(file: demo(), today: today)
        let wizard = CSVWizard(store: store, data: Data(csv.utf8), fileName: "x.csv", memory: .ephemeral())
        wizard.start(target: .transactions)
        await settle(wizard)
        #expect(wizard.output?.mapping.columns == [nil, nil, nil])
        // Two assignments without waiting for the first run to finish.
        wizard.setField(.note, column: 2)
        #expect(wizard.isComputing)
        #expect(wizard.field(forColumn: 2) == .note)              // the picker shows the pending choice
        wizard.setField(.shares, column: 1)
        wizard.setField(.date, column: 0)
        await settle(wizard)
        #expect(wizard.output?.mapping.columns == [.date, .shares, .note])

        // The same for the format: delimiter, then decimal separator.
        wizard.setDialect { $0.decimalSeparator = "." }
        #expect(wizard.currentDialect.decimalSeparator == ".")
        wizard.setDialect { $0.dateOrder = .dayMonthYear }
        await settle(wizard)
        #expect(wizard.output?.dialect.decimalSeparator == ".")
        #expect(wizard.output?.dialect.dateOrder == .dayMonthYear)

        // And for the type synonyms.
        wizard.setField(.type, column: 2)
        await settle(wizard)
        wizard.setAlias(.buy, for: "x")
        #expect(wizard.alias(for: "X") == .buy)
        wizard.setAlias(.sell, for: "y")
        await settle(wizard)
        #expect(wizard.output?.typeAliases == ["x": .buy, "y": .sell])

        // While the automatic mapping is recomputed there is nothing to build an edit on.
        wizard.resetMapping()
        #expect(wizard.isMappingPending)
        wizard.setField(.note, column: 0)
        await settle(wizard)
        #expect(!wizard.isMappingPending)
        #expect(wizard.output?.mapping.columns == [nil, nil, nil])
    }

    @Test func blockingReasonsNameTheStepThatResolvesThem() async {
        let store = PortfolioStore(file: demo(), today: today)
        // A header-only quotes file: "no data rows", not "choose the security".
        let empty = CSVWizard(store: store, data: Data("Date,Close\n".utf8), fileName: "empty.csv", memory: .ephemeral())
        empty.start(target: .quotes)
        await settle(empty)
        #expect(empty.blockingReason == "The file has no data rows.")
        #expect(empty.blockingStep == .file)
        #expect(!empty.needsQuoteSecurity)

        let quotes = CSVWizard(store: store, data: Data("Date,Close\n2026-07-01,2.00\n".utf8), fileName: "q.csv", memory: .ephemeral())
        quotes.start(target: .quotes)
        await settle(quotes)
        #expect(quotes.needsQuoteSecurity)
        #expect(quotes.blockingStep == .content)
        quotes.setSecurity(store.file.securities[0].id)
        await settle(quotes)
        #expect(quotes.blockingReason == nil)
        #expect(quotes.blockingStep == nil)

        let unmapped = CSVWizard(store: store, data: Data("A;B\nx;y\n".utf8), fileName: "u.csv", memory: .ephemeral())
        unmapped.start(target: .transactions)
        await settle(unmapped)
        #expect(unmapped.blockingStep == .mapping)
    }

    @Test func errorRowsShowWhatTheFileSays() {
        let output = CSVPipeline.run(pipelineInput(demo()))
        // Line 6: an unknown type, but a perfectly readable date, share count and value.
        let unknown = output.rows[4]
        #expect(unknown.status == .error)
        #expect(unknown.day == Day(year: 2026, month: 4, day: 1))
        #expect(unknown.shares == Shares(25))
        #expect(unknown.amount == Money(minor: 53_990, currency: "EUR"))
        #expect(unknown.note == "Limit-Order")
        // Line 10: 31.06. is not a date — the rest is still shown.
        let impossible = output.rows[8]
        #expect(impossible.status == .error)
        #expect(impossible.day == nil)
        #expect(impossible.amount == Money(minor: 71_490, currency: "EUR"))
        #expect(!impossible.isImportable)
    }

    @Test func aReplacedQuoteIsMarkedInTheReview() {
        // What the Quotes card and step 2 now say: a day whose quote differs is replaced, and marked.
        let file = demo()
        let last = file.securities[0].prices[file.securities[0].prices.count - 1]
        let csv = "Date,Close\n\(last.day.iso),1.00\n\(last.day.advanced(by: 1).iso),2.00\n"
        var input = CSVPipelineInput(data: Data(csv.utf8), file: file)
        input.securityID = file.securities[0].id
        let output = CSVPipeline.run(input)
        #expect(output.rows.map(\.status) == [.warning, .ok])
        #expect(output.rows[0].message.contains("Replaces the existing quote"))
    }

    @Test func theExpectedContentTravelsWithTheRequest() {
        let url = URL(fileURLWithPath: "/tmp/broker statement.csv")
        #expect(ImportFeature.importRequest(url, target: nil) == .importFile(url))
        #expect(ImportFeature.importRequest(url, target: .quotes)
            == .custom(id: ImportFeature.importSheetID, payload: ["path": "/tmp/broker statement.csv", "target": "quotes"]))
        let registry = FeatureRegistry([ImportFeature.module])
        #expect(registry.sheet(for: ImportFeature.importRequest(url, target: .transactions)) != nil)
    }

    @Test func monthRangesCollapse() {
        #expect(ImportText.months(Day(year: 2026, month: 6, day: 2), Day(year: 2026, month: 6, day: 29)) == Fmt.day(today, style: .shortMonthYear))
        let range = ImportText.months(Day(year: 2019, month: 3, day: 1), today)
        #expect(range == "\(Fmt.day(Day(year: 2019, month: 3, day: 1), style: .shortMonthYear)) – \(Fmt.day(today, style: .shortMonthYear))")
        #expect(ImportText.count(1, "detail", "details") == "1 detail")
        #expect(ImportText.count(2, "detail", "details") == "2 details")
    }
}

@Suite @MainActor struct ExportRegressionTests {
    @Test func aBuildIsOnlyWrittenForTheOptionsItWasMadeFor() {
        let file = demo()
        var options = ExportOptions()
        options.format = .transactions
        let key = ExportKey(options: options, revision: 7, today: today)
        let snapshot = ExportSnapshot(key: key, result: ExportBuilder.build(options, file: file, holdings: nil))
        #expect(snapshot.data(for: key) != nil)
        // Another format, another option, another revision, another day: build again.
        var other = key
        other.options.format = .portfolioPerformance
        #expect(snapshot.data(for: other) == nil)
        #expect(!snapshot.isCurrent(for: other))
        other = key
        other.options.onlySelection = false
        #expect(snapshot.data(for: other) == nil)
        other = key
        other.options.prettyJSON = false
        #expect(snapshot.data(for: other) == nil)
        other = key
        other.revision = 8
        #expect(snapshot.data(for: other) == nil)
        other = key
        other.today = today.advanced(by: 1)
        #expect(snapshot.data(for: other) == nil)
    }

    @Test func unvaluedHoldingsAreEmptyNotZero() async throws {
        // EUR portfolio, USD account and security, no exchange rates.
        var file = PortfolioFile(name: "x", settings: Settings(baseCurrency: "EUR"))
        let account = Account(name: "USD Cash", currency: "USD"), euro = Account(name: "EUR Cash", currency: "EUR")
        let depot = Depot(name: "D", referenceAccountID: account.id)
        var security = Security(name: "NoRate Inc", currency: "USD")
        security.prices = PriceSeries([PricePoint(day: today, price: Price(100))])
        file.accounts = [account, euro]; file.depots = [depot]; file.securities = [security]
        file.transactions = [
            Transaction(kind: .deposit, date: today.advanced(by: -5), accountID: account.id, amount: Money(minor: 100_000, currency: "USD")),
            Transaction(kind: .deposit, date: today.advanced(by: -5), accountID: euro.id, amount: Money(minor: 30_000, currency: "EUR")),
            Transaction(kind: .buy, date: today.advanced(by: -4), accountID: account.id, depotID: depot.id, securityID: security.id,
                        shares: Shares(5), amount: Money(minor: 50_000, currency: "USD")),
        ]
        let ledger = Ledger(file)
        let holdings = HoldingsExport(ledger.snapshot(on: today), ledger: ledger)
        #expect(holdings.positions.map(\.isValued) == [false])
        #expect(holdings.cash.map(\.isValued) == [false, true])

        var options = ExportOptions()
        options.format = .holdings
        let result = ExportBuilder.build(options, file: file, holdings: holdings)
        let lines = String(decoding: result.data!, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        // Value in the security's currency is known; value, cost and gain in EUR are not: empty, not 0.00.
        #expect(lines[1] == "Security,NoRate Inc,,,,5,100.00,2026-06-30,USD,500.00,,,,,")
        #expect(lines[2] == "Cash,USD Cash,,,,,,2026-06-30,USD,500.00,,,,,")
        #expect(lines[3].hasPrefix("Cash,EUR Cash,,,,,,2026-06-30,EUR,300.00,300.00,,,,"))
        #expect(!lines.dropFirst().contains { $0.contains(",0.00") })
        let notice = try #require(result.notice)
        #expect(notice.contains("2 rows have no value in EUR"))
        #expect(notice.contains("USD/EUR"))
        // A fully valued portfolio has no notice.
        let store = PortfolioStore(file: demo(), today: today)
        let valued = HoldingsExport(store.ledger.snapshot(on: today), ledger: store.ledger)
        #expect(valued.valuationNotice == nil)
        #expect(ExportBuilder.build(options, file: store.file, holdings: valued).notice == nil)
    }

    @Test func holdingsFileNameStatesTheDayAndScopeOfItsContent() {
        let file = demo()
        var options = ExportOptions()
        options.format = .holdings
        #expect(ExportBuilder.fileName(options, file: file, today: today) == "\(file.name) Holdings 2026-06-30.csv")
        // A statement for 31 Dec 2024 is named for that day, whatever today is.
        options.holdingsDay = Day(year: 2024, month: 12, day: 31)
        #expect(ExportBuilder.fileName(options, file: file, today: today) == "\(file.name) Holdings 2024-12-31.csv")
        #expect(ExportKey(options: options, revision: 0, today: today).holdingsDay == Day(year: 2024, month: 12, day: 31))
        #expect(ExportBuilder.fileName(options, file: file, today: today, scopeTitle: "Asset Classes ▸ Equity/Europe")
            == "\(file.name) Holdings Asset Classes - Equity-Europe 2024-12-31.csv")
        // The snapshot behind it is the one of that day and scope.
        let ledger = Ledger(file)
        let depot = file.depots[1]
        let scoped = HoldingsExport(ledger.snapshot(on: options.holdingsDay!, scope: .depot(depot.id)), ledger: ledger)
        #expect(scoped.day == options.holdingsDay)
        #expect(scoped.total == ledger.snapshot(on: options.holdingsDay!, scope: .depot(depot.id)).totalValue)
        #expect(ExportOptions().holdingsScope == .portfolio)
        #expect(ExportSheet.sizeText(rows: 1, bytes: 1_500) == "1 row · 2 KB")
    }
}
