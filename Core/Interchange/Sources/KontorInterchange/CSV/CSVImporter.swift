import Foundation
import KontorModel

/// Caller choices for turning a `CSVDocument` into an `ImportProposal`.
public struct CSVImportOptions: Hashable, Sendable {
    public var target: CSVImportTarget
    /// Column assignment; nil uses `CSVColumnMapping.automatic(header:target:)`.
    public var mapping: CSVColumnMapping?
    /// Cash account for rows that name none.
    public var defaultAccountID: UUID?
    /// Securities account for rows that name none.
    public var defaultDepotID: UUID?
    /// Currency for rows without a currency column; nil uses the account's currency, then the file's base currency.
    public var defaultCurrency: CurrencyCode?
    /// `.quotes` target: the security the quotes belong to.
    public var securityID: UUID?
    /// Extra spellings of transaction types found in the file (`"Wertpapierabrechnung": .buy`), compared case-insensitively.
    public var typeAliases: [String: CSVTransactionType]
    /// Create accounts/depots that are named in the file but do not exist yet (otherwise such rows are errors).
    public var createMissingAccounts: Bool
    /// Stored in `Transaction.source` of imported entries.
    public var sourceTag: String

    public init(
        target: CSVImportTarget = .transactions, mapping: CSVColumnMapping? = nil, defaultAccountID: UUID? = nil, defaultDepotID: UUID? = nil,
        defaultCurrency: CurrencyCode? = nil, securityID: UUID? = nil, typeAliases: [String: CSVTransactionType] = [:],
        createMissingAccounts: Bool = true, sourceTag: String = "csv-import"
    ) {
        self.target = target
        self.mapping = mapping
        self.defaultAccountID = defaultAccountID
        self.defaultDepotID = defaultDepotID
        self.defaultCurrency = defaultCurrency
        self.securityID = securityID
        self.typeAliases = typeAliases
        self.createMissingAccounts = createMissingAccounts
        self.sourceTag = sourceTag
    }
}

/// What an import would do — computed without touching the document, so a wizard can preview it,
/// let the user fix the mapping and pick rows before anything is applied.
public struct ImportProposal: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Ready to import.
        case ok
        /// Importable, but something was guessed or adjusted — see `messages`.
        case warning
        /// Cannot be imported — see `messages`.
        case error
        /// Already present: an existing transaction with the same kind, date, security, shares and amount in
        /// the same account (or the same quote / security). Not imported unless explicitly selected.
        case duplicate(of: UUID?)
    }

    public struct Row: Hashable, Sendable, Identifiable {
        /// Index into `CSVDocument.rows`.
        public var index: Int
        /// 1-based line in the file.
        public var lineNumber: Int
        public var status: Status
        /// Explanations for warnings and errors (empty for `.ok`).
        public var messages: [String]
        /// `.transactions`: the entry that would be added.
        public var transaction: Transaction?
        /// `.quotes`: the price that would be merged.
        public var quote: PricePoint?
        /// `.securities`: id of the security (in `newSecurities`) that would be added.
        public var securityID: UUID?

        public var id: Int { index }
        /// Whether the row can be applied at all (duplicates can, if the user insists; errors cannot).
        public var isImportable: Bool { status != .error && (transaction != nil || quote != nil || securityID != nil) }
        /// Whether the row is imported by `ImportSelection.recommended`.
        public var isRecommended: Bool { isImportable && (status == .ok || status == .warning) }
    }

    public var target: CSVImportTarget
    /// The column mapping the proposal was computed with.
    public var mapping: CSVColumnMapping
    public var rows: [Row]
    /// Securities that do not exist yet and are referenced by rows (added on apply if a selected row uses them).
    public var newSecurities: [Security]
    public var newAccounts: [Account]
    public var newDepots: [Depot]
    /// `.quotes`: the security receiving the quotes. May be set after the fact.
    public var quoteSecurityID: UUID?
    /// Type cells that could not be interpreted (offer them for `CSVImportOptions.typeAliases`).
    public var unrecognizedTypes: [String]
    /// Required fields that no column is mapped to; non-empty means every row is an error.
    public var missingFields: [CSVField]

    /// Number of rows per status.
    public struct StatusCounts: Hashable, Sendable {
        public var ok = 0
        public var warning = 0
        public var error = 0
        public var duplicate = 0
        /// Rows `ImportSelection.recommended` would import.
        public var recommended: Int { ok + warning }
    }

    /// All four status counts in one pass over `rows` — prefer this over the individual counters
    /// when showing several of them (each of those walks all rows again).
    public var statusCounts: StatusCounts {
        var counts = StatusCounts()
        for row in rows {
            switch row.status {
            case .ok: counts.ok += 1
            case .warning: counts.warning += 1
            case .error: counts.error += 1
            case .duplicate: counts.duplicate += 1
            }
        }
        return counts
    }

    public var okCount: Int { statusCounts.ok }
    public var warningCount: Int { statusCounts.warning }
    public var errorCount: Int { statusCounts.error }
    public var duplicateCount: Int { statusCounts.duplicate }

    /// Applies the proposal. See `CSVImporter.apply`.
    public func apply(to file: PortfolioFile, selection: ImportSelection = .recommended) -> PortfolioFile {
        CSVImporter.apply(self, to: file, selection: selection)
    }
}

/// Which rows of a proposal to import.
public enum ImportSelection: Hashable, Sendable {
    /// All rows with status `.ok` or `.warning` (duplicates and errors are left out).
    case recommended
    /// Exactly these rows (by `Row.index`); rows that are errors are still skipped.
    case rows(Set<Int>)
}

/// CSV import engine: `CSVDocument` + options + existing file → `ImportProposal` → new `PortfolioFile`.
///
/// ```swift
/// let document = CSVDocument(data: data)
/// var options = CSVImportOptions(target: .transactions, defaultAccountID: account.id, defaultDepotID: depot.id)
/// options.mapping = CSVColumnMapping.automatic(header: document.header)      // show, let the user adjust
/// let proposal = CSVImporter.propose(document, options: options, file: file) // preview rows + statuses
/// let updated = proposal.apply(to: file)                                     // pure
/// ```
public enum CSVImporter {
    /// Parses every row and resolves securities, accounts and duplicates against `file`. Pure; `file` is not modified.
    public static func propose(_ document: CSVDocument, options: CSVImportOptions = .init(), file: PortfolioFile) -> ImportProposal {
        var builder = ProposalBuilder(document: document, options: options, file: file)
        return builder.build()
    }

    /// Returns a copy of `file` with the selected rows of `proposal` added: transactions are appended
    /// (together with the new securities, accounts and depots they reference), quotes are merged into
    /// `proposal.quoteSecurityID`, securities are appended. Pure function.
    public static func apply(_ proposal: ImportProposal, to file: PortfolioFile, selection: ImportSelection = .recommended) -> PortfolioFile {
        var result = file
        let rows = proposal.rows.filter { row in
            guard row.isImportable else { return false }
            switch selection {
            case .recommended: return row.isRecommended
            case .rows(let indexes): return indexes.contains(row.index)
            }
        }
        switch proposal.target {
        case .transactions:
            var usedSecurities: Set<UUID> = [], usedAccounts: Set<UUID> = [], usedDepots: Set<UUID> = []
            var transactions: [Transaction] = []
            for row in rows {
                guard let transaction = row.transaction else { continue }
                transactions.append(transaction)
                if let id = transaction.securityID { usedSecurities.insert(id) }
                if let id = transaction.accountID { usedAccounts.insert(id) }
                if let id = transaction.counterAccountID { usedAccounts.insert(id) }
                if let id = transaction.depotID { usedDepots.insert(id) }
                if let id = transaction.counterDepotID { usedDepots.insert(id) }
            }
            let depots = proposal.newDepots.filter { usedDepots.contains($0.id) }
            for depot in depots { if let reference = depot.referenceAccountID { usedAccounts.insert(reference) } }
            let existingAccounts = Set(file.accounts.map(\.id)), existingDepots = Set(file.depots.map(\.id)), existingSecurities = Set(file.securities.map(\.id))
            result.securities.append(contentsOf: proposal.newSecurities.filter { usedSecurities.contains($0.id) && !existingSecurities.contains($0.id) })
            result.accounts.append(contentsOf: proposal.newAccounts.filter { usedAccounts.contains($0.id) && !existingAccounts.contains($0.id) })
            result.depots.append(contentsOf: depots.filter { !existingDepots.contains($0.id) })
            result.transactions.append(contentsOf: transactions)
        case .quotes:
            guard let securityID = proposal.quoteSecurityID, let index = result.securities.firstIndex(where: { $0.id == securityID }) else { return result }
            result.securities[index].prices.merge(rows.compactMap(\.quote))
        case .securities:
            let selected = Set(rows.compactMap(\.securityID))
            let existing = Set(file.securities.map(\.id))
            result.securities.append(contentsOf: proposal.newSecurities.filter { selected.contains($0.id) && !existing.contains($0.id) })
        }
        return result
    }
}

// MARK: - Proposal construction

private struct DuplicateKey: Hashable {
    var kind: Transaction.Kind
    var day: Day
    var security: UUID?
    var shares: Int64
    var amount: Int64
    /// The securities account for kinds that move shares, otherwise the cash account: the same
    /// booking in another account (two savings plans, two salary accounts) is not a duplicate.
    var owner: UUID?

    init(_ transaction: Transaction) {
        kind = transaction.kind
        day = transaction.date
        security = transaction.securityID
        shares = transaction.shares.raw
        amount = transaction.amount.minor
        owner = transaction.kind.requiresDepot ? transaction.depotID : transaction.accountID
    }
}

private struct ProposalBuilder {
    let document: CSVDocument
    let options: CSVImportOptions
    let file: PortfolioFile
    let mapping: CSVColumnMapping
    let columnOf: [CSVField: Int]
    let decimalSeparator: Character
    let aliases: [String: CSVTransactionType]

    // Existing entities, indexed once.
    var securityByISIN: [String: UUID] = [:]
    var securityByTicker: [String: UUID] = [:]
    var securityByWKN: [String: UUID] = [:]
    var securityByName: [String: UUID] = [:]
    var securityCurrency: [UUID: String] = [:]
    var securityISIN: [UUID: String] = [:]
    /// Whether the amount column distinguishes money in from money out by sign (computed on first use).
    var amountsAreSigned: Bool?
    var accountByName: [String: UUID] = [:]
    var accountCurrency: [UUID: String] = [:]
    var depotByName: [String: UUID] = [:]
    var depotReference: [UUID: UUID] = [:]
    var existingKeys: [DuplicateKey: UUID] = [:]

    var newSecurities: [Security] = []
    var newAccounts: [Account] = []
    var newDepots: [Depot] = []
    var unrecognizedTypes: [String] = []
    var seenUnrecognized: Set<String> = []

    init(document: CSVDocument, options: CSVImportOptions, file: PortfolioFile) {
        self.document = document
        self.options = options
        self.file = file
        var mapping = options.mapping ?? CSVColumnMapping.automatic(header: document.header, target: options.target)
        if mapping.columns.count < document.header.count {
            mapping.columns.append(contentsOf: [CSVField?](repeating: nil, count: document.header.count - mapping.columns.count))
        }
        let allowed = Set(options.target.fields)
        var columnOf: [CSVField: Int] = [:]
        for (index, field) in mapping.columns.enumerated() {
            guard let field, allowed.contains(field), columnOf[field] == nil, index < document.header.count else { continue }
            columnOf[field] = index
        }
        self.mapping = mapping
        self.columnOf = columnOf
        decimalSeparator = document.dialect.decimalSeparator
        var aliases: [String: CSVTransactionType] = [:]
        for (key, value) in options.typeAliases { aliases[key.trimmingCharacters(in: .whitespaces).lowercased()] = value }
        self.aliases = aliases

        for security in file.securities.reversed() { // reversed: the first security wins on ambiguous keys
            register(security)
        }
        for account in file.accounts.reversed() {
            accountByName[ProposalBuilder.key(account.name)] = account.id
            accountCurrency[account.id] = account.currency
        }
        for depot in file.depots.reversed() {
            depotByName[ProposalBuilder.key(depot.name)] = depot.id
            if let reference = depot.referenceAccountID { depotReference[depot.id] = reference }
        }
        if options.target == .transactions {
            existingKeys.reserveCapacity(file.transactions.count)
            for transaction in file.transactions { existingKeys[DuplicateKey(transaction)] = transaction.id }
        }
    }

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    mutating func register(_ security: Security) {
        if !security.isin.isEmpty {
            securityByISIN[security.isin.uppercased()] = security.id
            securityISIN[security.id] = security.isin.uppercased()
        }
        if !security.ticker.isEmpty { securityByTicker[security.ticker.uppercased()] = security.id }
        if !security.wkn.isEmpty { securityByWKN[security.wkn.uppercased()] = security.id }
        if !security.name.isEmpty { securityByName[ProposalBuilder.key(security.name)] = security.id }
        securityCurrency[security.id] = security.currency
    }

    func cell(_ row: [String], _ field: CSVField) -> String {
        guard let column = columnOf[field], column < row.count else { return "" }
        return row[column]
    }

    mutating func build() -> ImportProposal {
        let missing = options.target.requiredFields.filter { columnOf[$0] == nil }
        var rows: [ImportProposal.Row] = []
        rows.reserveCapacity(document.rows.count)
        for (index, cells) in document.rows.enumerated() {
            var row = ImportProposal.Row(index: index, lineNumber: index < document.lineNumbers.count ? document.lineNumbers[index] : index + 1, status: .ok, messages: [])
            if let field = missing.first {
                row.status = .error
                row.messages = ["No column is mapped to \"\(field.displayName)\"."]
            } else {
                switch options.target {
                case .transactions: transactionRow(cells, &row)
                case .quotes: quoteRow(cells, &row)
                case .securities: securityRow(cells, &row)
                }
            }
            rows.append(row)
        }
        return ImportProposal(
            target: options.target, mapping: mapping, rows: rows, newSecurities: newSecurities, newAccounts: newAccounts, newDepots: newDepots,
            quoteSecurityID: options.securityID, unrecognizedTypes: unrecognizedTypes, missingFields: missing
        )
    }

    // MARK: Cell parsing

    /// Largest magnitude accepted for a monetary cell (10^15 currency units). Keeps every sum of
    /// value, fees and taxes far away from `Int64` overflow.
    static let amountLimit: Int64 = 100_000_000_000_000_000

    /// nil = empty cell; unreadable content appends a message to `errors`.
    func number(_ row: [String], _ field: CSVField, digits: Int, errors: inout [String]) -> Int64? {
        let text = cell(row, field)
        guard !text.isEmpty else { return nil }
        guard let value = CSVValueParser.decimal(text, decimalSeparator: decimalSeparator, digits: digits) else {
            errors.append("\"\(text)\" in column \"\(field.displayName)\" is not a number.")
            return nil
        }
        if digits == 2, value > ProposalBuilder.amountLimit || value < -ProposalBuilder.amountLimit {
            errors.append("\"\(text)\" in column \"\(field.displayName)\" is too large.")
            return nil
        }
        return value
    }

    /// Whether any row has a negative amount, i.e. the sign of the amount column tells money in from money out.
    mutating func signedAmounts() -> Bool {
        if let known = amountsAreSigned { return known }
        var signed = false
        if let column = columnOf[.amount] {
            for row in document.rows where column < row.count && !row[column].isEmpty {
                if let value = CSVValueParser.decimal(row[column], decimalSeparator: decimalSeparator, digits: 2), value < 0 {
                    signed = true
                    break
                }
            }
        }
        amountsAreSigned = signed
        return signed
    }

    func currencyCode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "€": return "EUR"
        case "$": return "USD"
        case "£": return "GBP"
        case "¥": return "JPY"
        default: return trimmed.uppercased()
        }
    }

    // MARK: Entities

    /// Finds the security a row refers to (ISIN → ticker → WKN → name) or proposes a new one.
    /// An ISIN is authoritative: when the row has one, a security that carries a *different* ISIN is
    /// never matched through its ticker, WKN or name (share classes of one fund share names and tickers).
    mutating func security(_ row: [String], currency: String) -> UUID? {
        let isin = cell(row, .isin).uppercased(), ticker = cell(row, .ticker), wkn = cell(row, .wkn).uppercased(), name = cell(row, .securityName)
        guard !isin.isEmpty || !ticker.isEmpty || !wkn.isEmpty || !name.isEmpty else { return nil }
        if !isin.isEmpty, let id = securityByISIN[isin] { return id }
        func compatible(_ id: UUID) -> Bool { isin.isEmpty || securityISIN[id] == nil || securityISIN[id] == isin }
        if !ticker.isEmpty, let id = securityByTicker[ticker.uppercased()], compatible(id) { return id }
        if !wkn.isEmpty, let id = securityByWKN[wkn], compatible(id) { return id }
        if !name.isEmpty, let id = securityByName[ProposalBuilder.key(name)], compatible(id) { return id }
        let security = Security(name: name.isEmpty ? (isin.isEmpty ? (ticker.isEmpty ? wkn : ticker) : isin) : name, currency: currency, isin: isin, wkn: wkn, ticker: ticker)
        newSecurities.append(security)
        register(security)
        return security.id
    }

    enum Resolution { case found(UUID), missing(String) }

    mutating func account(named name: String, fallback: UUID?, currency: String, purpose: String) -> Resolution {
        let key = ProposalBuilder.key(name)
        if !key.isEmpty {
            if let id = accountByName[key] { return .found(id) }
            guard options.createMissingAccounts else { return .missing("The \(purpose) \"\(name)\" does not exist.") }
            let account = Account(name: name.trimmingCharacters(in: .whitespaces), currency: currency)
            newAccounts.append(account)
            accountByName[key] = account.id
            accountCurrency[account.id] = currency
            return .found(account.id)
        }
        if let fallback { return .found(fallback) }
        if file.accounts.count == 1 { return .found(file.accounts[0].id) }
        if file.accounts.isEmpty {
            // Empty document: start with one account so that a first import "just works".
            return account(named: "Cash Account", fallback: nil, currency: currency, purpose: purpose)
        }
        return .missing("No \(purpose) is given and no default account was chosen.")
    }

    mutating func depot(named name: String, fallback: UUID?, referenceAccount: UUID?, purpose: String) -> Resolution {
        let key = ProposalBuilder.key(name)
        if !key.isEmpty {
            if let id = depotByName[key] { return .found(id) }
            guard options.createMissingAccounts else { return .missing("The \(purpose) \"\(name)\" does not exist.") }
            let depot = Depot(name: name.trimmingCharacters(in: .whitespaces), referenceAccountID: referenceAccount)
            newDepots.append(depot)
            depotByName[key] = depot.id
            if let referenceAccount { depotReference[depot.id] = referenceAccount }
            return .found(depot.id)
        }
        if let fallback { return .found(fallback) }
        if file.depots.count == 1 { return .found(file.depots[0].id) }
        if file.depots.isEmpty {
            return depot(named: "Depot", fallback: nil, referenceAccount: referenceAccount, purpose: purpose)
        }
        return .missing("No \(purpose) is given and no default securities account was chosen.")
    }

    // MARK: Transactions

    mutating func type(_ text: String) -> CSVTransactionType?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .some(nil) }
        if let alias = aliases[trimmed.lowercased()] { return alias }
        if let known = CSVTransactionType.match(trimmed) { return known }
        if seenUnrecognized.insert(trimmed).inserted { unrecognizedTypes.append(trimmed) }
        return nil
    }

    mutating func transactionRow(_ cells: [String], _ row: inout ImportProposal.Row) {
        var errors: [String] = []
        var warnings: [String] = []

        // Date and time.
        let dateText = cell(cells, .date)
        var day: Day?
        var minute: Int?
        if dateText.isEmpty {
            errors.append("The date is missing.")
        } else if let parsed = CSVValueParser.date(dateText, order: document.dialect.dateOrder) {
            day = parsed.day
            minute = parsed.minuteOfDay
        } else {
            errors.append("\"\(dateText)\" is not a valid date.")
        }
        let timeText = cell(cells, .time)
        if !timeText.isEmpty {
            if let time = CSVValueParser.time(timeText) { minute = time == 0 ? nil : time } else { warnings.append("The time \"\(timeText)\" could not be read and was ignored.") }
        }

        // Numbers.
        let sharesValue = number(cells, .shares, digits: 8, errors: &errors)
        let quoteValue = number(cells, .quote, digits: 8, errors: &errors)
        let amountValue = number(cells, .amount, digits: 2, errors: &errors)
        let feesValue = number(cells, .fees, digits: 2, errors: &errors) ?? 0
        let taxesValue = number(cells, .taxes, digits: 2, errors: &errors) ?? 0
        let grossValue = number(cells, .grossAmount, digits: 2, errors: &errors)

        // Type: explicit, or inferred from what the row contains.
        let hasIdentifier = !cell(cells, .isin).isEmpty || !cell(cells, .ticker).isEmpty || !cell(cells, .wkn).isEmpty
        let nameText = cell(cells, .securityName)
        var hasSecurity = hasIdentifier || !nameText.isEmpty
        var noteFromName: String?
        var csvType: CSVTransactionType?
        let typeText = cell(cells, .type)
        switch type(typeText) {
        case .some(.some(let known)):
            csvType = known
        case .some(.none):
            // Without a type, a bare description ("WIRE IN") on a row without shares is a cash booking, not a security.
            if !hasIdentifier, !nameText.isEmpty, (sharesValue ?? 0) == 0, securityByName[ProposalBuilder.key(nameText)] == nil {
                hasSecurity = false
                noteFromName = nameText
            }
            csvType = ProposalBuilder.inferType(hasSecurity: hasSecurity, shares: sharesValue ?? 0, amount: amountValue ?? 0, signedAmounts: signedAmounts())
            if columnOf[.type] != nil { warnings.append("The type is empty; the row was read as \"\(csvType!.label(german: false))\".") }
        case .none:
            errors.append("The type \"\(typeText)\" is not known.")
        }
        guard errors.isEmpty, let csvType, let day else {
            row.status = .error
            row.messages = errors + warnings
            return
        }

        // Accounts by name.
        let accountName = cell(cells, .account), counterAccountName = cell(cells, .counterAccount)
        let depotName = cell(cells, .depot), counterDepotName = cell(cells, .counterDepot)
        var shares = abs(sharesValue ?? 0)
        let signedAmount = amountValue

        // Resolve the kind.
        var kind: Transaction.Kind
        var swapSides = false
        switch csvType {
        case .buy: kind = .buy
        case .sell: kind = .sell
        case .deliveryIn: kind = .deliveryIn
        case .deliveryOut: kind = .deliveryOut
        case .deposit: kind = .deposit
        case .withdrawal: kind = .withdrawal
        case .dividend: kind = .dividend
        case .interest:
            kind = (signedAmount ?? 0) < 0 ? .interestCharge : .interest
        case .interestCharge: kind = .interestCharge
        case .fee: kind = .fee
        case .feeRefund: kind = .feeRefund
        case .tax: kind = .tax
        case .taxRefund: kind = .taxRefund
        case .transfer, .transferIn, .transferOut:
            // "Transfer (Inbound)" rows are written from the receiving side: the offset account is the source.
            let inbound = csvType == .transferIn
            if hasSecurity, shares != 0 {
                if counterDepotName.isEmpty {
                    kind = inbound || (csvType == .transfer && (sharesValue ?? 0) > 0) ? .deliveryIn : .deliveryOut
                    warnings.append("The transfer names no offset securities account; it was read as \(kind == .deliveryIn ? "an inbound" : "an outbound") delivery.")
                } else {
                    kind = .securityTransfer
                    swapSides = inbound
                }
            } else {
                if counterAccountName.isEmpty {
                    let credit = csvType == .transferIn || (csvType == .transfer && (signedAmount ?? 0) > 0)
                    kind = credit ? .deposit : .withdrawal
                    warnings.append("The transfer names no offset account; it was read as a \(credit ? "deposit" : "withdrawal").")
                } else {
                    kind = .cashTransfer
                    swapSides = inbound
                }
            }
        }

        // Currency: explicit column, else the account's, else the default.
        let explicitCurrency = currencyCode(cell(cells, .currency))
        let grossCurrency = currencyCode(cell(cells, .grossCurrency))
        let knownAccount = accountByName[ProposalBuilder.key(swapSides ? counterAccountName : accountName)]
            ?? (accountName.isEmpty ? options.defaultAccountID ?? (file.accounts.count == 1 ? file.accounts[0].id : nil) : nil)
        let currency = explicitCurrency ?? knownAccount.flatMap { accountCurrency[$0] } ?? options.defaultCurrency ?? file.settings.baseCurrency

        // Security.
        var securityID: UUID?
        let usesSecurity = kind.requiresSecurity || ((kind == .fee || kind == .feeRefund || kind == .tax || kind == .taxRefund) && hasSecurity)
        if usesSecurity {
            securityID = security(cells, currency: grossCurrency ?? currency)
            if securityID == nil {
                row.status = .error
                row.messages = ["A \(csvType.label(german: false)) needs a security, but the row names none (ISIN, ticker, WKN or name)."] + warnings
                return
            }
        }

        // Amount and shares, deriving one from the other via the quote where necessary.
        var amount = signedAmount.map(abs)
        let movesShares = kind.sharesSign != 0 || kind == .securityTransfer
        if movesShares {
            if shares == 0, let quoteValue, quoteValue > 0, let amount {
                // All three are bounded by `amountLimit`, so this cannot overflow.
                let gross = kind == .buy || kind == .deliveryIn ? amount - abs(feesValue) - abs(taxesValue) : amount + abs(feesValue) + abs(taxesValue)
                shares = max(0, mulDiv(gross, Scale.price * Scale.shares / Scale.amount, quoteValue))
                warnings.append("The number of shares was calculated from value and quote.")
            }
            if shares == 0 {
                row.status = .error
                row.messages = ["The number of shares is missing."] + warnings
                return
            }
            if amount == nil {
                if let grossValue, grossCurrency == nil || grossCurrency == currency {
                    amount = kind == .buy || kind == .deliveryIn ? abs(grossValue) + abs(feesValue) + abs(taxesValue) : abs(grossValue) - abs(feesValue) - abs(taxesValue)
                } else if let quoteValue {
                    // shares × quote saturates for absurd inputs; cap it so that adding fees cannot overflow.
                    let gross = min(Price(raw: abs(quoteValue)).value(of: Shares(raw: shares)), Int64.max / 2)
                    amount = kind == .buy || kind == .deliveryIn ? gross + abs(feesValue) + abs(taxesValue) : gross - abs(feesValue) - abs(taxesValue)
                    if kind != .securityTransfer { warnings.append("The value was calculated from shares and quote.") }
                } else if kind == .securityTransfer || kind == .deliveryIn || kind == .deliveryOut {
                    amount = 0
                    if kind != .securityTransfer { warnings.append("The row has no value; the delivery was recorded with a value of 0.") }
                }
            }
        } else if kind != .dividend {
            shares = 0
        }
        if amount == nil {
            // Rows that only carry their breakdown: a fee/tax booking is its fee/tax, a dividend or
            // interest payment is gross − fees − taxes.
            switch kind {
            case .fee, .feeRefund:
                if feesValue != 0 { amount = abs(feesValue) }
            case .tax, .taxRefund:
                if taxesValue != 0 { amount = abs(taxesValue) }
            case .dividend, .interest:
                if let grossValue, grossCurrency == nil || grossCurrency == currency {
                    amount = abs(grossValue) - abs(feesValue) - abs(taxesValue)
                }
            default:
                break
            }
        }
        guard var amount else {
            row.status = .error
            row.messages = ["The value is missing."] + warnings
            return
        }
        if amount < 0 { amount = 0 }
        if amount > ProposalBuilder.amountLimit || shares > Int64.max / 2 {
            row.status = .error
            row.messages = ["The value or the number of shares is implausibly large."] + warnings
            return
        }
        if kind == .dividend, (signedAmount ?? 0) < 0 {
            warnings.append("The dividend has a negative value; its absolute value was used.")
        }

        // Accounts.
        var transaction = Transaction(kind: kind, date: day, minuteOfDay: minute, securityID: securityID, shares: Shares(raw: shares),
                                      amount: Money(minor: amount, currency: currency), note: cell(cells, .note), source: options.sourceTag)
        if transaction.note.isEmpty, let noteFromName { transaction.note = noteFromName }
        func fail(_ message: String) {
            row.status = .error
            row.messages = [message] + warnings
        }
        if kind.requiresAccount {
            let primaryName = swapSides ? counterAccountName : accountName
            // Without an account of its own, a securities account's reference account settles the trade.
            var fallback = options.defaultAccountID
            if fallback == nil, primaryName.isEmpty, kind.requiresDepot {
                let depot = depotByName[ProposalBuilder.key(depotName)] ?? options.defaultDepotID ?? (file.depots.count == 1 ? file.depots[0].id : nil)
                fallback = depot.flatMap { depotReference[$0] }
            }
            switch account(named: primaryName, fallback: fallback, currency: currency, purpose: "cash account") {
            case .found(let id): transaction.accountID = id
            case .missing(let message): return fail(message)
            }
            if let existing = transaction.accountID.flatMap({ accountCurrency[$0] }), existing != currency {
                warnings.append("The row's currency (\(currency)) differs from the account's currency (\(existing)).")
            }
        }
        if kind == .cashTransfer {
            switch account(named: swapSides ? accountName : counterAccountName, fallback: swapSides ? options.defaultAccountID : nil, currency: grossCurrency ?? currency, purpose: "offset account") {
            case .found(let id): transaction.counterAccountID = id
            case .missing(let message): return fail(message)
            }
            if transaction.counterAccountID == transaction.accountID { return fail("Source and target account of the transfer are the same.") }
            // The gross columns carry the amount credited to the target: another currency, or (rarely) the
            // same currency with a different amount.
            if let grossValue, grossValue != 0 {
                let credited = Money(minor: abs(grossValue), currency: grossCurrency ?? currency)
                if credited != transaction.amount { transaction.counterAmount = credited }
            }
        }
        if movesShares {
            switch depot(named: swapSides ? counterDepotName : depotName, fallback: options.defaultDepotID, referenceAccount: transaction.accountID, purpose: "securities account") {
            case .found(let id): transaction.depotID = id
            case .missing(let message): return fail(message)
            }
        }
        if kind == .securityTransfer {
            switch depot(named: swapSides ? depotName : counterDepotName, fallback: swapSides ? options.defaultDepotID : nil, referenceAccount: nil, purpose: "offset securities account") {
            case .found(let id): transaction.counterDepotID = id
            case .missing(let message): return fail(message)
            }
            if transaction.counterDepotID == transaction.depotID { return fail("Source and target securities account of the transfer are the same.") }
        }

        // Fee/tax breakdown and foreign-currency gross value.
        switch kind {
        case .buy, .sell, .deliveryIn, .deliveryOut, .dividend, .interest:
            transaction.fees = abs(feesValue)
            transaction.taxes = abs(taxesValue)
            if let grossValue, let grossCurrency, grossCurrency != currency, grossValue != 0 {
                transaction.securityGross = Money(minor: abs(grossValue), currency: grossCurrency)
            }
            if transaction.grossMinor < 0 {
                warnings.append("Fees and taxes exceed the value of the transaction.")
            }
        default:
            break
        }

        row.transaction = transaction
        row.messages = warnings
        if let existing = existingKeys[DuplicateKey(transaction)] {
            row.status = .duplicate(of: existing)
            row.messages.insert("An identical transaction already exists.", at: 0)
        } else {
            row.status = warnings.isEmpty ? .ok : .warning
        }
    }

    /// The most plausible type of a row without a type column.
    /// - Parameter signedAmounts: whether the file's amount column uses negative numbers at all. Only
    ///   then does a positive amount mean "money in"; a list of trades with unsigned values is a list of purchases.
    static func inferType(hasSecurity: Bool, shares: Int64, amount: Int64, signedAmounts: Bool) -> CSVTransactionType {
        if hasSecurity {
            if shares < 0 { return .sell }
            if shares > 0 { return signedAmounts && amount > 0 ? .sell : .buy } // money in + shares listed = sale; otherwise a purchase
            return amount >= 0 ? .dividend : .fee
        }
        return amount >= 0 ? .deposit : .withdrawal
    }

    // MARK: Quotes

    mutating func quoteRow(_ cells: [String], _ row: inout ImportProposal.Row) {
        let dateText = cell(cells, .date), quoteText = cell(cells, .quote)
        guard let day = CSVValueParser.date(dateText, order: document.dialect.dateOrder)?.day else {
            row.status = .error
            row.messages = [dateText.isEmpty ? "The date is missing." : "\"\(dateText)\" is not a valid date."]
            return
        }
        guard let raw = CSVValueParser.decimal(quoteText, decimalSeparator: decimalSeparator, digits: 8), raw >= 0 else {
            row.status = .error
            row.messages = [quoteText.isEmpty ? "The quote is missing." : "\"\(quoteText)\" is not a valid quote."]
            return
        }
        row.quote = PricePoint(day: day, price: Price(raw: raw))
        if let id = options.securityID, let security = file.security(id), let index = security.prices.index(onOrBefore: day), security.prices[index].day == day {
            if security.prices[index].price.raw == raw {
                row.status = .duplicate(of: id)
                row.messages = ["This quote already exists."]
            } else {
                row.status = .warning
                row.messages = ["Replaces the existing quote \(security.prices[index].price) of that day."]
            }
        }
    }

    // MARK: Securities

    mutating func securityRow(_ cells: [String], _ row: inout ImportProposal.Row) {
        let isin = cell(cells, .isin).uppercased(), ticker = cell(cells, .ticker), wkn = cell(cells, .wkn).uppercased(), name = cell(cells, .securityName)
        guard !isin.isEmpty || !ticker.isEmpty || !wkn.isEmpty || !name.isEmpty else {
            row.status = .error
            row.messages = ["The row contains neither a name nor an ISIN, WKN or ticker symbol."]
            return
        }
        let countBefore = newSecurities.count
        let currency = currencyCode(cell(cells, .currency)) ?? options.defaultCurrency ?? file.settings.baseCurrency
        guard let id = security(cells, currency: currency) else { return }
        if newSecurities.count == countBefore {
            row.status = .duplicate(of: id)
            row.messages = ["This security already exists."]
            return
        }
        newSecurities[countBefore].note = cell(cells, .note)
        row.securityID = id
        if columnOf[.currency] == nil || cell(cells, .currency).isEmpty {
            row.status = .warning
            row.messages = ["No currency is given; \(currency) was assumed."]
        }
    }
}
