import Foundation
import KontorInterchange
import KontorUI

/// Runs pure work off the main actor.
enum Background {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}

// MARK: - Source tags

/// The `Transaction.source` written by this feature: `<kind>:<yyyy-MM-dd>:<file name>`, e.g.
/// `csv-import:2026-06-30:broker.csv`. The date and the name make every import identifiable
/// afterwards ("Recent Imports", the Source column and the quick filter of Transactions).
/// Plain `csv-import` / `pp-import` (written by KontorInterchange's defaults) parse as well.
struct ImportTag: Hashable, Sendable {
    enum Kind: String, Sendable {
        case csv = "csv-import"
        case portfolioPerformance = "pp-import"

        var title: String {
            switch self {
            case .csv: "CSV"
            case .portfolioPerformance: "Portfolio Performance"
            }
        }

        var symbol: String {
            switch self {
            case .csv: "tablecells"
            case .portfolioPerformance: "shippingbox"
            }
        }
    }

    var kind: Kind
    var day: Day?
    var fileName: String?

    init(kind: Kind, day: Day?, fileName: String?) {
        self.kind = kind
        self.day = day
        self.fileName = fileName
    }

    init?(source: String) {
        let parts = source.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = Kind(rawValue: String(first)) else { return nil }
        self.kind = kind
        day = parts.count > 1 ? Day(iso: parts[1]) : nil
        fileName = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
    }

    var source: String {
        guard let day else { return kind.rawValue }
        guard let fileName, !fileName.isEmpty else { return "\(kind.rawValue):\(day.iso)" }
        return "\(kind.rawValue):\(day.iso):\(fileName)"
    }
}

// MARK: - Loading a file

/// A Portfolio Performance file, converted and summarised — everything the summary sheet shows.
struct PortfolioPerformanceResult: Sendable, Hashable {
    var fileName: String
    var byteCount: Int
    /// The converted document; transactions carry `tag.source`. Plan executions keep `plan:<id>` (the
    /// Plans screen finds them by it); `ImportRecord` in the file's settings says which of them came
    /// with this import.
    var file: PortfolioFile
    var report: ImportReport
    var tag: ImportTag
    var firstDay: Day?
    var lastDay: Day?
    /// Number of transactions per kind, most frequent first.
    var kinds: [KindCount]
    /// What merging into the open portfolio would do; nil when that portfolio is untouched (the
    /// file then simply becomes its content).
    var mergePreview: PortfolioMerge.Summary?

    struct KindCount: Sendable, Hashable, Identifiable {
        var kind: Transaction.Kind
        var count: Int
        var id: Transaction.Kind { kind }
    }

    /// Currencies used in the file for which it holds no exchange rates. Portfolio Performance
    /// downloads rates itself and does not store them, so this is the normal case for a file with
    /// more than one currency: until rates are downloaded, amounts in these currencies count as 0.
    var currenciesWithoutRates: [CurrencyCode] {
        let base = file.settings.baseCurrency
        return file.currencies.filter { currency in
            currency != base && !file.exchangeRates.contains { !$0.days.isEmpty && ($0.base == currency || $0.quote == currency) }
        }.sorted()
    }

    var warnings: [ImportWarning] { report.warnings.filter { $0.severity == .warning } }
    var notes: [ImportWarning] { report.warnings.filter { $0.severity == .info } }
}

/// What a file turned out to be.
enum LoadedImport: Sendable {
    case portfolioPerformance(PortfolioPerformanceResult)
    case csv(data: Data, fileName: String)
    /// A Kontor document: it is opened, not imported.
    case kontorDocument(fileName: String)
    /// A recognised format that cannot be read (encrypted / binary Portfolio Performance), or an unknown file.
    case unreadable(format: FileFormat, fileName: String, advice: String)
    case failed(fileName: String, message: String)
}

enum ImportLoader {
    /// Files larger than this are refused up front (a Portfolio Performance file with a million quotes is ~80 MB).
    static let maximumByteCount = 1 << 30

    /// Reads, identifies and — for Portfolio Performance files — converts `url`. Pure apart from reading
    /// the file; call it off the main actor.
    static func load(_ url: URL, into current: PortfolioFile, today: Day) -> LoadedImport {
        let fileName = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumByteCount else {
                return .failed(fileName: fileName, message: "The file is larger than 1 GB. Kontor does not import files of that size.")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failed(fileName: fileName, message: error.localizedDescription)
        }
        return load(data, fileName: fileName, into: current, today: today)
    }

    static func load(_ data: Data, fileName: String, into current: PortfolioFile, today: Day) -> LoadedImport {
        guard !data.isEmpty else {
            return .failed(fileName: fileName, message: "The file is empty.")
        }
        let format = FileFormat.detect(data: data, filename: fileName)
        switch format {
        case .kontor:
            return .kontorDocument(fileName: fileName)
        case .csv:
            return .csv(data: data, fileName: fileName)
        case .portfolioPerformanceXML, .portfolioPerformanceZippedXML:
            do {
                let name = (fileName as NSString).deletingPathExtension
                let result = try PortfolioPerformanceImporter.read(data, name: name)
                return .portfolioPerformance(summarize(result, fileName: fileName, byteCount: data.count, into: current, today: today))
            } catch let error as PortfolioPerformanceImportError {
                switch error {
                case .encrypted:
                    return .unreadable(format: .portfolioPerformanceEncrypted, fileName: fileName, advice: error.description)
                case .binaryFormat:
                    return .unreadable(format: .portfolioPerformanceBinary, fileName: fileName, advice: error.description)
                default:
                    return .failed(fileName: fileName, message: error.description)
                }
            } catch {
                return .failed(fileName: fileName, message: error.localizedDescription)
            }
        case .portfolioPerformanceBinary, .portfolioPerformanceEncrypted, .unknown:
            return .unreadable(format: format, fileName: fileName, advice: format.advice ?? "This file cannot be imported.")
        }
    }

    static func summarize(
        _ result: PortfolioPerformanceImport, fileName: String, byteCount: Int, into current: PortfolioFile, today: Day
    ) -> PortfolioPerformanceResult {
        let tag = ImportTag(kind: .portfolioPerformance, day: today, fileName: fileName)
        var file = result.file
        var first: Day?
        var last: Day?
        var counts: [Transaction.Kind: Int] = [:]
        for index in file.transactions.indices {
            let transaction = file.transactions[index]
            if transaction.source == nil || transaction.source == ImportTag.Kind.portfolioPerformance.rawValue {
                file.transactions[index].source = tag.source
            }
            first = min(first ?? transaction.date, transaction.date)
            last = max(last ?? transaction.date, transaction.date)
            counts[transaction.kind, default: 0] += 1
        }
        // Plan executions keep their plan tag; note which ones belong to this import.
        ImportRecord(planExecutionsIn: file.transactions)?.write(for: tag.source, to: &file.settings.preferences)
        let order = Dictionary(uniqueKeysWithValues: Transaction.Kind.allCases.enumerated().map { ($1, $0) })
        let kinds = counts
            .map { PortfolioPerformanceResult.KindCount(kind: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : order[$0.kind, default: 0] < order[$1.kind, default: 0] }
        return PortfolioPerformanceResult(
            fileName: fileName, byteCount: byteCount, file: file, report: result.report, tag: tag,
            firstDay: first, lastDay: last, kinds: kinds,
            mergePreview: current.isUntouched ? nil : PortfolioMerge.merge(file, into: current).summary)
    }
}

extension PortfolioFile {
    /// Nothing at all in it.
    var isBlank: Bool {
        securities.isEmpty && accounts.isEmpty && depots.isEmpty && transactions.isEmpty && taxonomies.isEmpty && plans.isEmpty
    }

    /// Nothing has been recorded yet — an import may simply become the document. True for an empty
    /// file and for a new portfolio as the app creates it (one cash account, one depot and empty
    /// taxonomy templates): no securities, transactions or plans, nothing classified, nothing watched.
    /// A portfolio with several hand-made accounts or depots is not untouched; an import merges into it.
    var isUntouched: Bool {
        guard securities.isEmpty, transactions.isEmpty, plans.isEmpty, accounts.count <= 1, depots.count <= 1 else { return false }
        guard watchlists.allSatisfy(\.securityIDs.isEmpty) else { return false }
        return taxonomies.allSatisfy { !$0.root.contains(where: \.hasAssignments) }
    }
}

extension Classification {
    /// Anything assigned here or below.
    var hasAssignments: Bool { !assignments.isEmpty || children.contains(where: \.hasAssignments) }
}

// MARK: - Import records

/// Which plan executions an import brought. Transactions normally carry their import's tag in
/// `source`, but plan executions must keep `plan:<id>` (that is how plans find their bookings), so
/// the import notes them in the document's settings: `import.plan-executions:<import tag>` =
/// `<last day>|<plan id>,<plan id>…`. "Recent Imports" counts and removes them with the import.
struct ImportRecord: Hashable, Sendable {
    static let keyPrefix = "import.plan-executions:"

    /// The plans whose executions came with the import.
    var planIDs: Set<UUID>
    /// The date of the last imported execution: later bookings of these plans were made in Kontor.
    var through: Day

    init(planIDs: Set<UUID>, through: Day) {
        self.planIDs = planIDs
        self.through = through
    }

    /// The record for the plan executions among `transactions`; nil if there are none.
    init?(planExecutionsIn transactions: some Sequence<Transaction>) {
        var ids = Set<UUID>()
        var last: Day?
        for transaction in transactions {
            guard let id = Self.planID(of: transaction) else { continue }
            ids.insert(id)
            last = max(last ?? transaction.date, transaction.date)
        }
        guard let last else { return nil }
        self.init(planIDs: ids, through: last)
    }

    init?(value: String) {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let day = Day(iso: parts[0]) else { return nil }
        let ids = parts[1].split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return nil }
        self.init(planIDs: Set(ids), through: day)
    }

    var value: String { "\(through.iso)|" + planIDs.map(\.uuidString).sorted().joined(separator: ",") }

    /// The plan a transaction is an execution of (`source` = `plan:<uuid>`).
    static func planID(of transaction: Transaction) -> UUID? {
        guard let source = transaction.source, source.count > 5, source.prefix(5).lowercased() == "plan:" else { return nil }
        return UUID(uuidString: String(source.dropFirst(5)))
    }

    func contains(_ transaction: Transaction) -> Bool {
        guard transaction.date <= through, let id = Self.planID(of: transaction) else { return false }
        return planIDs.contains(id)
    }

    /// Stores the record for the import tagged `source`, extending one that is already there.
    func write(for source: String, to preferences: inout [String: String]) {
        var record = self
        if let existing = preferences[Self.keyPrefix + source].flatMap(ImportRecord.init(value:)) {
            record.planIDs.formUnion(existing.planIDs)
            record.through = max(record.through, existing.through)
        }
        preferences[Self.keyPrefix + source] = record.value
    }

    /// All records of a document, by import tag.
    static func all(in preferences: [String: String]) -> [String: ImportRecord] {
        var result: [String: ImportRecord] = [:]
        for (key, value) in preferences where key.hasPrefix(keyPrefix) {
            if let record = ImportRecord(value: value) { result[String(key.dropFirst(keyPrefix.count))] = record }
        }
        return result
    }
}

// MARK: - Recent imports

/// One earlier import, reconstructed from the source tags of the ledger.
struct RecentImport: Sendable, Hashable, Identifiable {
    var source: String
    var tag: ImportTag
    var count: Int
    var firstDay: Day
    var lastDay: Day
    /// The chronologically first entry — where "Show" leads.
    var firstTransactionID: UUID

    var id: String { source }

    /// Groups the ledger by import tag, most recent import first (untagged dates last). `preferences`
    /// are the document's (`Settings.preferences`): they hold the `ImportRecord`s, which add the plan
    /// executions a Portfolio Performance import brought to that import.
    static func list(_ transactions: [Transaction], preferences: [String: String] = [:]) -> [RecentImport] {
        let membership = Membership(preferences: preferences)
        var bySource: [String: RecentImport] = [:]
        var firstEntry: [String: Transaction] = [:]
        for transaction in transactions {
            guard let source = membership.importSource(of: transaction) else { continue }
            if var entry = bySource[source] {
                entry.count += 1
                entry.firstDay = min(entry.firstDay, transaction.date)
                entry.lastDay = max(entry.lastDay, transaction.date)
                if let first = firstEntry[source], Transaction.chronological(transaction, first) {
                    firstEntry[source] = transaction
                    entry.firstTransactionID = transaction.id
                }
                bySource[source] = entry
            } else if let tag = ImportTag(source: source) {
                bySource[source] = RecentImport(
                    source: source, tag: tag, count: 1, firstDay: transaction.date, lastDay: transaction.date,
                    firstTransactionID: transaction.id)
                firstEntry[source] = transaction
            }
        }
        return bySource.values.sorted { a, b in
            switch (a.tag.day, b.tag.day) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.source.localizedStandardCompare(b.source) == .orderedAscending
            }
        }
    }

    /// Removes everything `source` imported from `file`: the transactions carrying the tag and the plan
    /// executions its record names (and the record). Securities, accounts and plans stay.
    /// Returns the number of transactions removed.
    @discardableResult
    static func remove(_ source: String, from file: inout PortfolioFile) -> Int {
        let membership = Membership(preferences: file.settings.preferences)
        let before = file.transactions.count
        file.transactions.removeAll { membership.importSource(of: $0) == source }
        file.settings.preferences[ImportRecord.keyPrefix + source] = nil
        return before - file.transactions.count
    }

    /// Which import a transaction belongs to.
    struct Membership: Sendable {
        private var records: [(source: String, record: ImportRecord)]
        private var planIDs = Set<UUID>()

        init(preferences: [String: String]) {
            // Deterministic when two imports name the same plan: the older import (lower tag) wins.
            records = ImportRecord.all(in: preferences).sorted { $0.key < $1.key }.map { (source: $0.key, record: $0.value) }
            for entry in records { planIDs.formUnion(entry.record.planIDs) }
        }

        func importSource(of transaction: Transaction) -> String? {
            guard let source = transaction.source else { return nil }
            if source.hasPrefix("csv-import") || source.hasPrefix("pp-import") { return source }
            guard !records.isEmpty, let id = ImportRecord.planID(of: transaction), planIDs.contains(id) else { return nil }
            return records.first { $0.record.contains(transaction) }?.source
        }
    }
}

// MARK: - Small text helpers

enum ImportText {
    /// "Jun 2026" when both days fall into one month, "Mar 2019 – Jun 2026" otherwise.
    static func months(_ first: Day, _ last: Day) -> String {
        let from = Fmt.day(first, style: .shortMonthYear), to = Fmt.day(last, style: .shortMonthYear)
        return from == to ? from : "\(from) – \(to)"
    }

    /// "1 row", "2 rows".
    static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(Fmt.integer(count)) \(count == 1 ? singular : plural)"
    }
}
