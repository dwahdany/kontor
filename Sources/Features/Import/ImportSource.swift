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
    /// The converted document; transactions carry `tag.source` (plan executions keep `plan:<id>`).
    var file: PortfolioFile
    var report: ImportReport
    var tag: ImportTag
    var firstDay: Day?
    var lastDay: Day?
    /// Number of transactions per kind, most frequent first.
    var kinds: [KindCount]
    /// What merging into the open portfolio would do; nil when that portfolio is empty.
    var mergePreview: PortfolioMerge.Summary?

    struct KindCount: Sendable, Hashable, Identifiable {
        var kind: Transaction.Kind
        var count: Int
        var id: Transaction.Kind { kind }
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
        let order = Dictionary(uniqueKeysWithValues: Transaction.Kind.allCases.enumerated().map { ($1, $0) })
        let kinds = counts
            .map { PortfolioPerformanceResult.KindCount(kind: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : order[$0.kind, default: 0] < order[$1.kind, default: 0] }
        return PortfolioPerformanceResult(
            fileName: fileName, byteCount: byteCount, file: file, report: result.report, tag: tag,
            firstDay: first, lastDay: last, kinds: kinds,
            mergePreview: current.isBlank ? nil : PortfolioMerge.merge(file, into: current).summary)
    }
}

extension PortfolioFile {
    /// Nothing in it yet — an import may simply become the document.
    var isBlank: Bool {
        securities.isEmpty && accounts.isEmpty && depots.isEmpty && transactions.isEmpty && taxonomies.isEmpty && plans.isEmpty
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

    /// Groups the ledger by import tag, most recent import first (untagged dates last).
    static func list(_ transactions: [Transaction]) -> [RecentImport] {
        var bySource: [String: RecentImport] = [:]
        var firstEntry: [String: Transaction] = [:]
        for transaction in transactions {
            guard let source = transaction.source, source.hasPrefix("csv-import") || source.hasPrefix("pp-import") else { continue }
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
}
