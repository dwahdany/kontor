import Foundation
import KontorInterchange
import KontorUI

// MARK: - Remembered mappings

/// What the wizard remembers about a CSV layout once an import succeeded, keyed by the file's
/// header signature — so the second file from the same broker is one click.
struct RememberedMapping: Codable, Hashable, Sendable {
    var target: CSVImportTarget
    var columns: [CSVField?]
    var typeAliases: [String: CSVTransactionType]
    var dialect: CSVDialect
    /// Defaults by name (ids differ between documents).
    var accountName: String?
    var depotName: String?
    var savedAt: Date
}

/// Persistence of `RememberedMapping`s in UserDefaults (one JSON blob, newest 40 layouts).
/// `ephemeral()` keeps them in memory only — for screenshots and tests, which must never read or
/// write the user's remembered layouts.
@MainActor
final class MappingMemory {
    static let defaultsKey = "import.csv.rememberedMappings"
    static let capacity = 40

    private let defaults: UserDefaults?
    private var volatile: [String: RememberedMapping] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    static func ephemeral() -> MappingMemory { MappingMemory(defaults: nil) }

    /// Identity of a column layout: the normalised titles in order. Files without a header row
    /// share one signature per column count.
    nonisolated static func signature(header: [String], hasHeader: Bool) -> String {
        guard hasHeader else { return "no-header:\(header.count)" }
        return header
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1F}")
    }

    func load() -> [String: RememberedMapping] {
        guard let defaults else { return volatile }
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RememberedMapping].self, from: data)) ?? [:]
    }

    func remember(_ mapping: RememberedMapping, for signature: String) {
        var all = load()
        all[signature] = mapping
        if all.count > Self.capacity {
            let oldest = all.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(all.count - Self.capacity)
            for entry in oldest { all[entry.key] = nil }
        }
        save(all)
    }

    func forget(_ signature: String) {
        var all = load()
        guard all.removeValue(forKey: signature) != nil else { return }
        save(all)
    }

    private func save(_ all: [String: RememberedMapping]) {
        guard let defaults else {
            volatile = all
            return
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - Pipeline

/// Everything the wizard's result depends on. A plain value, so the whole chain
/// (sniff → parse → map → propose → rows) runs off the main actor and can be re-run on any change.
struct CSVPipelineInput: Sendable {
    var data: Data
    /// nil = sniff (first run).
    var dialect: CSVDialect?
    /// The user's decision; nil = not decided yet (first run): a remembered layout, the hint or the
    /// column titles decide.
    var target: CSVImportTarget?
    /// What the entry point expects the file to be ("Transactions from a Broker or Bank ▸ Choose CSV…").
    /// A preference, not a decision: a remembered layout of the same kind still applies.
    var targetHint: CSVImportTarget?
    /// The user's mapping; only used while the header still has `mappingSignature`.
    var mapping: CSVColumnMapping?
    var mappingSignature: String?
    var typeAliases: [String: CSVTransactionType] = [:]
    var accountID: UUID?
    var depotID: UUID?
    var securityID: UUID?
    var createMissingAccounts = true
    var sourceTag = "csv-import"
    var file: PortfolioFile
    /// Remembered layouts; consulted on the first run only (`target == nil`), and only a layout whose
    /// content is what `targetHint` expects (if there is a hint).
    var memory: [String: RememberedMapping] = [:]
}

enum ReviewStatus: String, Sendable, Hashable, CaseIterable {
    case ok, warning, error, duplicate

    var title: String {
        switch self {
        case .ok: "Ready"
        case .warning: "Warning"
        case .error: "Error"
        case .duplicate: "Duplicate"
        }
    }

    var pluralTitle: String {
        switch self {
        case .ok: "Ready"
        case .warning: "Warnings"
        case .error: "Errors"
        case .duplicate: "Duplicates"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .duplicate: "doc.on.doc.fill"
        }
    }

    /// Sort rank: problems first.
    var rank: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .duplicate: 2
        case .ok: 3
        }
    }

    init(_ status: ImportProposal.Status) {
        switch status {
        case .ok: self = .ok
        case .warning: self = .warning
        case .error: self = .error
        case .duplicate: self = .duplicate
        }
    }
}

/// One row of the proposal, flattened for the review table and the live preview.
struct ReviewRow: Identifiable, Sendable, Hashable {
    /// Index into the CSV's data rows (`ImportProposal.Row.index`).
    var id: Int
    var line: Int
    var status: ReviewStatus
    var message: String
    var isImportable: Bool
    var day: Day?
    /// "Buy", "Dividend", "Quote", "Security".
    var kind: String
    var security: String
    var shares: Shares?
    var amount: Money?
    /// `.quotes` target: the price (in the security's currency).
    var price: Price?
    var account: String
    var note: String

    // Sort keys for the table.
    var statusRank: Int { status.rank }
    var dayValue: Int32 { day?.rawValue ?? .min }
    var sharesValue: Int64 { shares?.raw ?? 0 }
    var amountValue: Int64 { amount?.minor ?? price?.raw ?? 0 }
}

/// A distinct value of the type column and what it is read as.
struct TypeValue: Identifiable, Sendable, Hashable {
    var text: String
    var count: Int
    /// What the built-in vocabulary makes of it (nil = unknown).
    var automatic: CSVTransactionType?
    /// The user's (or a remembered) override.
    var alias: CSVTransactionType?
    var id: String { text }
    var resolved: CSVTransactionType? { alias ?? automatic }
}

struct CSVPipelineOutput: Sendable {
    var dialect: CSVDialect
    /// Set on the first run: what the sniffer found (the baseline for "Reset").
    var detected: CSVDialect?
    var isDateOrderAmbiguous = false
    var isDecimalSeparatorAmbiguous = false
    var header: [String]
    var signature: String
    var rowCount: Int
    /// The first rows as text, for the live preview.
    var sampleRows: [[String]]
    /// First non-empty cell per column.
    var columnSamples: [String]
    var target: CSVImportTarget
    var mapping: CSVColumnMapping
    var typeAliases: [String: CSVTransactionType]
    var accountID: UUID?
    var depotID: UUID?
    /// True when a remembered layout supplied target, mapping and synonyms (first run only).
    var usedMemory = false
    var proposal: ImportProposal
    var counts: ImportProposal.StatusCounts
    var rows: [ReviewRow]
    var typeValues: [TypeValue]
    /// Rows selected by default: ready and warning rows.
    var recommended: Set<Int>
    var quoteCurrency: CurrencyCode?
}

enum CSVPipeline {
    static let sampleRowCount = 60

    static func run(_ input: CSVPipelineInput) -> CSVPipelineOutput {
        // 1. Parse.
        var document: CSVDocument
        var detected: CSVDialect?
        var dateAmbiguous = false, decimalAmbiguous = false
        if let dialect = input.dialect {
            document = CSVDocument(data: input.data, dialect: dialect)
        } else {
            document = CSVDocument(data: input.data)
            detected = document.dialect
            dateAmbiguous = document.isDateOrderAmbiguous
            decimalAmbiguous = document.isDecimalSeparatorAmbiguous
        }
        var signature = MappingMemory.signature(header: document.header, hasHeader: document.dialect.headerRecord != nil)

        // 2. Target, mapping and synonyms: the user's, a remembered layout's, or automatic.
        var target = input.target
        var mapping: CSVColumnMapping?
        var aliases = input.typeAliases
        var accountID = input.accountID, depotID = input.depotID
        var usedMemory = false
        if target == nil, let remembered = input.memory[signature], remembered.columns.count == document.header.count,
           input.targetHint == nil || input.targetHint == remembered.target {
            usedMemory = true
            target = remembered.target
            mapping = CSVColumnMapping(columns: remembered.columns)
            aliases = remembered.typeAliases
            // The remembered number and date notation wins over sniffing (the user confirmed it last time).
            var dialect = document.dialect
            dialect.decimalSeparator = remembered.dialect.decimalSeparator
            dialect.dateOrder = remembered.dialect.dateOrder
            if dialect != document.dialect {
                document = CSVDocument(data: input.data, dialect: dialect)
                signature = MappingMemory.signature(header: document.header, hasHeader: dialect.headerRecord != nil)
            }
            // The defaults chosen last time win over the generic ones, if they still exist.
            if let name = remembered.accountName,
               let match = input.file.accounts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                accountID = match.id
            }
            if let name = remembered.depotName,
               let match = input.file.depots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                depotID = match.id
            }
        }
        let resolvedTarget = target ?? input.targetHint ?? guessTarget(header: document.header)
        if mapping == nil, let userMapping = input.mapping, input.mappingSignature == signature,
           userMapping.columns.count == document.header.count {
            mapping = userMapping
        }
        var resolvedMapping = mapping ?? CSVColumnMapping.automatic(header: document.header, target: resolvedTarget)
        // Fields the target does not know are dropped (after switching the target).
        let allowed = Set(resolvedTarget.fields)
        resolvedMapping.columns = resolvedMapping.columns.map { field in field.flatMap { allowed.contains($0) ? $0 : nil } }

        // 3. Propose.
        let options = CSVImportOptions(
            target: resolvedTarget, mapping: resolvedMapping, defaultAccountID: accountID, defaultDepotID: depotID,
            securityID: input.securityID, typeAliases: aliases, createMissingAccounts: input.createMissingAccounts,
            sourceTag: input.sourceTag)
        let proposal = CSVImporter.propose(document, options: options, file: input.file)

        // 4. Flatten for the UI.
        var securityNames = Dictionary(input.file.securities.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for security in proposal.newSecurities { securityNames[security.id] = security.name }
        var accountNames = Dictionary(input.file.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for account in proposal.newAccounts { accountNames[account.id] = account.name }
        var depotNames = Dictionary(input.file.depots.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for depot in proposal.newDepots { depotNames[depot.id] = depot.name }
        let newSecurities = Dictionary(proposal.newSecurities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let quoteSecurity = proposal.quoteSecurityID.flatMap { id in input.file.securities.first { $0.id == id } }

        var rows: [ReviewRow] = []
        rows.reserveCapacity(proposal.rows.count)
        var recommended = Set<Int>()
        for row in proposal.rows {
            var review = ReviewRow(
                id: row.index, line: row.lineNumber, status: ReviewStatus(row.status), message: row.messages.joined(separator: " "),
                isImportable: row.isImportable, day: nil, kind: "", security: "", shares: nil, amount: nil, price: nil, account: "", note: "")
            if let transaction = row.transaction {
                review.day = transaction.date
                review.kind = transaction.kind.title
                review.security = transaction.securityID.flatMap { securityNames[$0] } ?? ""
                review.shares = transaction.shares.isZero ? nil : transaction.shares
                review.amount = transaction.amount
                review.account = transaction.accountID.flatMap { accountNames[$0] } ?? transaction.depotID.flatMap { depotNames[$0] } ?? ""
                review.note = transaction.note
            } else if let quote = row.quote {
                review.day = quote.day
                review.kind = "Quote"
                review.security = quoteSecurity?.name ?? ""
                review.price = quote.price
            } else if let id = row.securityID, let security = newSecurities[id] {
                review.kind = "Security"
                review.security = security.name
                review.account = security.currency
                review.note = [security.isin, security.wkn, security.ticker].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            else if row.index < document.rows.count {
                // Rows without a result (errors, securities that exist): show what the file says, for context.
                let cells = document.rows[row.index]
                func cell(_ field: CSVField) -> String {
                    guard let column = resolvedMapping.column(for: field), column < cells.count else { return "" }
                    return cells[column].trimmingCharacters(in: .whitespaces)
                }
                let separator = document.dialect.decimalSeparator
                review.security = [cell(.securityName), cell(.isin), cell(.ticker)].first { !$0.isEmpty } ?? ""
                switch resolvedTarget {
                case .securities:
                    review.kind = "Security"
                    review.account = cell(.currency)
                case .quotes:
                    review.kind = "Quote"
                    review.day = CSVValueParser.date(cell(.date), order: document.dialect.dateOrder)?.day
                    review.price = CSVValueParser.decimal(cell(.quote), decimalSeparator: separator, digits: 8).map { Price(raw: $0) }
                case .transactions:
                    // Whatever of the row can be read, so that an error row is recognisable in the table.
                    review.kind = cell(.type)
                    review.day = CSVValueParser.date(cell(.date), order: document.dialect.dateOrder)?.day
                    if let raw = CSVValueParser.decimal(cell(.shares), decimalSeparator: separator, digits: 8), raw != 0 {
                        review.shares = Shares(raw: abs(raw))
                    }
                    if let minor = CSVValueParser.decimal(cell(.amount), decimalSeparator: separator, digits: 2) {
                        let code = cell(.currency).uppercased()
                        review.amount = Money(minor: abs(minor), currency: code.count == 3 ? code : input.file.settings.baseCurrency)
                    }
                    review.account = [cell(.account), cell(.depot)].first { !$0.isEmpty } ?? ""
                    review.note = cell(.note)
                }
            }
            if row.isRecommended { recommended.insert(row.index) }
            rows.append(review)
        }

        // 5. Distinct type values.
        var typeValues: [TypeValue] = []
        if resolvedTarget == .transactions, let column = resolvedMapping.column(for: .type) {
            var tally: [String: Int] = [:]
            var order: [String] = []
            for row in document.rows where column < row.count {
                let text = row[column].trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if tally[text] == nil {
                    guard order.count < 200 else { continue }
                    order.append(text)
                }
                tally[text, default: 0] += 1
            }
            let foldedAliases = Dictionary(aliases.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            typeValues = order.map { text in
                TypeValue(text: text, count: tally[text] ?? 0, automatic: CSVTransactionType.match(text), alias: foldedAliases[text.lowercased()])
            }
        }

        var samples = [String](repeating: "", count: document.header.count)
        for column in samples.indices {
            samples[column] = document.rows.lazy.prefix(200).compactMap { row -> String? in
                column < row.count && !row[column].isEmpty ? row[column] : nil
            }.first ?? ""
        }

        return CSVPipelineOutput(
            dialect: document.dialect, detected: detected, isDateOrderAmbiguous: dateAmbiguous,
            isDecimalSeparatorAmbiguous: decimalAmbiguous, header: document.header, signature: signature,
            rowCount: document.rows.count, sampleRows: Array(document.rows.prefix(sampleRowCount)), columnSamples: samples,
            target: resolvedTarget, mapping: resolvedMapping, typeAliases: aliases, accountID: accountID, depotID: depotID,
            usedMemory: usedMemory, proposal: proposal, counts: proposal.statusCounts, rows: rows, typeValues: typeValues,
            recommended: recommended, quoteCurrency: quoteSecurity?.currency)
    }

    /// What a file most likely contains, judged by its column titles.
    static func guessTarget(header: [String]) -> CSVImportTarget {
        let fields = Set(CSVColumnMapping.automatic(header: header, target: .transactions).columns.compactMap { $0 })
        let identity: Set<CSVField> = [.securityName, .isin, .wkn, .ticker]
        if fields.contains(.date) {
            let ledger: Set<CSVField> = [.type, .amount, .shares, .fees, .taxes, .account, .depot, .grossAmount]
            if fields.isDisjoint(with: ledger), fields.isDisjoint(with: identity) { return .quotes }
            return .transactions
        }
        if !fields.isDisjoint(with: identity) { return .securities }
        return header.count == 2 ? .quotes : .transactions
    }
}

extension CSVImportTarget {
    var title: String {
        switch self {
        case .transactions: "Transactions"
        case .quotes: "Quotes"
        case .securities: "Securities"
        }
    }

    var symbol: String {
        switch self {
        case .transactions: "list.bullet.rectangle"
        case .quotes: "chart.line.uptrend.xyaxis"
        case .securities: "building.columns"
        }
    }

    var explanation: String {
        switch self {
        case .transactions: "Purchases, sales, dividends, deposits, fees — one per row, cash and securities mixed."
        case .quotes: "Historical prices of one security: a date and a price per row."
        case .securities: "A list of securities (name, ISIN, ticker, currency) without transactions."
        }
    }

    func noun(_ count: Int) -> String {
        switch self {
        case .transactions: count == 1 ? "transaction" : "transactions"
        case .quotes: count == 1 ? "quote" : "quotes"
        case .securities: count == 1 ? "security" : "securities"
        }
    }

    var actionName: String {
        switch self {
        case .transactions: "Import CSV"
        case .quotes: "Import Quotes"
        case .securities: "Import Securities"
        }
    }
}
