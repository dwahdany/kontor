import SwiftUI
import KontorInterchange
import KontorUI

/// State of the CSV wizard: the user's choices, the latest pipeline result and the row selection.
/// Every change re-runs `CSVPipeline` off the main actor; the last good result stays visible meanwhile.
@MainActor @Observable
final class CSVWizard {
    enum Step: String, CaseIterable, Identifiable {
        case file, content, mapping, review, done

        var id: String { rawValue }

        /// The numbered steps shown in the header (`done` is the result page).
        static let numbered: [Step] = [.file, .content, .mapping, .review]

        var title: String {
            switch self {
            case .file: "File"
            case .content: "Content"
            case .mapping: "Columns"
            case .review: "Review"
            case .done: "Done"
            }
        }
    }

    struct Outcome: Equatable {
        var target: CSVImportTarget
        var imported: Int
        var newSecurities: Int
        var newAccounts: Int
        var newDepots: Int
        var skipped: Int
        /// Where "Show Imported" leads.
        var route: Route?
        var sourceTag: String
    }

    let store: PortfolioStore
    let data: Data
    let fileName: String
    let memory: MappingMemory

    var step = Step.file
    private(set) var output: CSVPipelineOutput?
    /// What the sniffer found on the first run.
    private(set) var detected: CSVDialect?
    private(set) var isDateOrderAmbiguous = false
    private(set) var isDecimalSeparatorAmbiguous = false
    private(set) var isComputing = false
    /// A remembered layout was applied to this file.
    private(set) var usedMemory = false
    private(set) var outcome: Outcome?
    private(set) var isImporting = false

    /// Rows (by CSV row index) that will be imported.
    var selection = Set<Int>()
    /// Status filter of the review step.
    var filter: ReviewStatus? {
        didSet { if filter != oldValue { updateVisibleRows() } }
    }
    /// The rows passing `filter`, in file order — kept ready so the review table never starts empty.
    private(set) var visibleRows: [ReviewRow] = []

    // The user's choices; nil = not decided yet (the pipeline decides on the first run).
    private var dialect: CSVDialect?
    private var target: CSVImportTarget?
    private var mapping: CSVColumnMapping?
    private var mappingSignature: String?
    private var typeAliases: [String: CSVTransactionType] = [:]
    private(set) var accountID: UUID?
    private(set) var depotID: UUID?
    private(set) var securityID: UUID?
    private(set) var createMissingAccounts = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ignoresMemory = false
    @ObservationIgnored private var launchStep: Step?
    /// Bumped whenever a new pipeline result is installed.
    private(set) var outputVersion = 0

    init(store: PortfolioStore, data: Data, fileName: String, memory: MappingMemory) {
        self.store = store
        self.data = data
        self.fileName = fileName
        self.memory = memory
    }

    var sourceTag: String { ImportTag(kind: .csv, day: store.today, fileName: fileName).source }

    // MARK: Derived

    var currentTarget: CSVImportTarget { output?.target ?? target ?? .transactions }
    var currentDialect: CSVDialect { output?.dialect ?? dialect ?? CSVDialect() }
    var isDialectOverridden: Bool { detected != nil && output?.dialect != detected }
    var missingFields: [CSVField] { output?.proposal.missingFields ?? [] }
    var unrecognizedTypeCount: Int { output?.typeValues.count { $0.resolved == nil } ?? 0 }

    /// Rows that will actually be imported: selected and importable.
    var importCount: Int {
        guard let output else { return 0 }
        if selection == output.recommended { return output.counts.recommended }
        return output.rows.count { $0.isImportable && selection.contains($0.id) }
    }

    /// Why the import cannot start yet (nil = it can).
    var blockingReason: String? {
        guard let output else { return "Reading the file…" }
        if !missingFields.isEmpty {
            return "Choose a column for " + missingFields.map(\.displayName).formatted(.list(type: .and)) + "."
        }
        if output.target == .quotes, securityID == nil { return "Choose the security these quotes belong to." }
        if importCount == 0 { return output.rowCount == 0 ? "The file has no data rows." : "No rows are selected." }
        return nil
    }

    private func updateVisibleRows() {
        guard let rows = output?.rows else {
            visibleRows = []
            return
        }
        visibleRows = filter.map { status in rows.filter { $0.status == status } } ?? rows
    }

    // MARK: Changes

    /// Screenshot support: the step (and review filter) to show once the file has been read.
    /// `done` performs the import (the screenshot mode's document lives in memory only).
    func launch(step: Step?, filter: ReviewStatus?) {
        launchStep = step
        self.filter = filter
    }

    func start(target hint: CSVImportTarget? = nil) {
        target = hint
        // Coming from a security (deep link or selection): quotes are most likely meant for it.
        if securityID == nil { securityID = store.route.securityID }
        // Sensible defaults for rows that name no account: the first active depot and its reference account.
        if accountID == nil, depotID == nil {
            let depot = store.file.depots.first { !$0.isRetired } ?? store.file.depots.first
            depotID = depot?.id
            accountID = depot?.referenceAccountID.flatMap { store.account($0)?.id }
                ?? (store.file.accounts.first { !$0.isRetired } ?? store.file.accounts.first)?.id
        }
        refresh()
    }

    func setDialect(_ change: (inout CSVDialect) -> Void) {
        var value = currentDialect
        change(&value)
        guard value != currentDialect else { return }
        dialect = value
        isDateOrderAmbiguous = false
        isDecimalSeparatorAmbiguous = false
        refresh()
    }

    func resetDialect() {
        guard let detected else { return }
        dialect = detected
        refresh()
    }

    /// Header row on/off. Without one, the first record is data and columns are numbered.
    func setHasHeader(_ hasHeader: Bool) {
        setDialect { dialect in
            if hasHeader {
                let header = detected?.headerRecord ?? max(dialect.firstDataRecord - 1, 0)
                dialect.headerRecord = header
                dialect.firstDataRecord = max(detected?.firstDataRecord ?? header + 1, header + 1)
            } else {
                dialect.firstDataRecord = dialect.headerRecord ?? dialect.firstDataRecord
                dialect.headerRecord = nil
            }
        }
    }

    func setTarget(_ value: CSVImportTarget) {
        guard value != currentTarget else { return }
        target = value
        // Another kind of content has other fields: start from the automatic mapping again.
        mapping = nil
        mappingSignature = nil
        refresh()
    }

    func setField(_ field: CSVField?, column: Int) {
        guard var value = output?.mapping, value.columns.indices.contains(column) else { return }
        if let field {
            value.set(field, column: column)
        } else {
            value.columns[column] = nil
        }
        mapping = value
        mappingSignature = output?.signature
        refresh()
    }

    func resetMapping() {
        mapping = nil
        mappingSignature = nil
        typeAliases = [:]
        ignoresMemory = true
        usedMemory = false
        refresh()
    }

    func setAlias(_ type: CSVTransactionType?, for text: String) {
        for key in typeAliases.keys where key.caseInsensitiveCompare(text) == .orderedSame { typeAliases[key] = nil }
        if let type { typeAliases[text] = type }
        refresh()
    }

    func setAccount(_ id: UUID?) {
        guard id != accountID else { return }
        accountID = id
        refresh()
    }

    func setDepot(_ id: UUID?) {
        guard id != depotID else { return }
        depotID = id
        refresh()
    }

    func setSecurity(_ id: UUID?) {
        guard id != securityID else { return }
        securityID = id
        refresh()
    }

    func setCreateMissingAccounts(_ value: Bool) {
        guard value != createMissingAccounts else { return }
        createMissingAccounts = value
        refresh()
    }

    // MARK: Selection

    func toggle(_ ids: Set<Int>) {
        guard let output else { return }
        let importable = Set(output.rows.lazy.filter { $0.isImportable && ids.contains($0.id) }.map(\.id))
        guard !importable.isEmpty else { return }
        if importable.isSubset(of: selection) {
            selection.subtract(importable)
        } else {
            selection.formUnion(importable)
        }
    }

    func selectShown(_ selected: Bool) {
        let ids = visibleRows.lazy.filter(\.isImportable).map(\.id)
        if selected {
            selection.formUnion(ids)
        } else {
            selection.subtract(ids)
        }
    }

    func selectRecommended() {
        selection = output?.recommended ?? []
    }

    // MARK: Pipeline

    private func refresh() {
        generation += 1
        let run = generation
        var input = CSVPipelineInput(data: data, file: store.file)
        input.dialect = dialect
        input.target = target
        input.mapping = mapping
        input.mappingSignature = mappingSignature
        input.typeAliases = typeAliases
        input.accountID = accountID
        input.depotID = depotID
        input.securityID = securityID
        input.createMissingAccounts = createMissingAccounts
        input.sourceTag = sourceTag
        if output == nil, !ignoresMemory { input.memory = memory.load() }
        isComputing = true
        let snapshot = input
        Task {
            let result = await store.whileBusy {
                await Background.run { CSVPipeline.run(snapshot) }
            }
            guard run == generation else { return }
            install(result)
        }
    }

    private func install(_ result: CSVPipelineOutput) {
        let isFirst = output == nil
        if let found = result.detected {
            detected = found
            isDateOrderAmbiguous = result.isDateOrderAmbiguous
            isDecimalSeparatorAmbiguous = result.isDecimalSeparatorAmbiguous
        }
        // From now on the choices are explicit, so later runs are deterministic.
        dialect = result.dialect
        target = result.target
        mapping = result.mapping
        mappingSignature = result.signature
        typeAliases = result.typeAliases
        accountID = result.accountID
        depotID = result.depotID
        if result.usedMemory { usedMemory = true }
        output = result
        updateVisibleRows()
        outputVersion += 1
        selection = result.recommended
        isComputing = false
        guard isFirst else { return }
        if result.usedMemory, result.proposal.missingFields.isEmpty {
            // Known layout: straight to the review — the second import is one click.
            step = .review
        }
        if let launchStep {
            self.launchStep = nil
            if launchStep == .done {
                Task { await performImport() }
            } else {
                step = launchStep
            }
        }
    }

    // MARK: Import

    func performImport() async {
        guard let output, blockingReason == nil, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let proposal = output.proposal
        let rows = selection
        let before = store.file
        let revision = store.revision
        let updated = await store.whileBusy {
            await Background.run { proposal.apply(to: before, selection: .rows(rows)) }
        }
        guard store.revision == revision else {
            store.toast("Import canceled", message: "The portfolio changed in the meantime. Please try again.", style: .warning)
            return
        }
        let changed = store.mutate(output.target.actionName) { $0 = updated }

        var result = Outcome(
            target: output.target, imported: 0, newSecurities: updated.securities.count - before.securities.count,
            newAccounts: updated.accounts.count - before.accounts.count, newDepots: updated.depots.count - before.depots.count,
            skipped: output.rowCount - importCount, route: nil, sourceTag: sourceTag)
        switch output.target {
        case .transactions:
            let imported = proposal.rows.compactMap { rows.contains($0.index) && $0.isImportable ? $0.transaction : nil }
            result.imported = imported.count
            result.route = imported.min(by: Transaction.chronological).map { .transaction($0.id) }
        case .quotes:
            result.imported = importCount
            result.route = proposal.quoteSecurityID.map { .security($0) }
        case .securities:
            result.imported = result.newSecurities
            result.route = updated.securities.dropFirst(before.securities.count).first.map { .security($0.id) }
        }
        if changed {
            memory.remember(
                RememberedMapping(
                    target: output.target, columns: output.mapping.columns, typeAliases: output.typeAliases, dialect: output.dialect,
                    accountName: store.account(accountID)?.name, depotName: store.depot(depotID)?.name, savedAt: Date()),
                for: output.signature)
            store.toast(
                "Imported \(Fmt.integer(result.imported)) \(output.target.noun(result.imported))",
                message: "From “\(fileName)”. Undo with ⌘Z.", style: .success)
        }
        outcome = result
        step = .done
    }
}
