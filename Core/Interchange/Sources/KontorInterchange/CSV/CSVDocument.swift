import Foundation
import KontorModel

/// How a CSV file is written: text-level format plus the notation of numbers and dates.
/// All properties are detected by `CSVSniffer` and can be overridden by the user.
public struct CSVDialect: Hashable, Sendable, Codable {
    public var encoding: CSVTextEncoding
    /// Field delimiter: `;`, `,`, tab or `|`.
    public var delimiter: Character
    /// 0-based index of the record that holds the column titles; nil if the file has no header.
    public var headerRecord: Int?
    /// 0-based index of the first data record (records before it — preamble, header — are skipped).
    public var firstDataRecord: Int
    /// `"."` (1,234.56) or `","` (1.234,56).
    public var decimalSeparator: Character
    public var dateOrder: CSVDateOrder

    public init(
        encoding: CSVTextEncoding = .utf8, delimiter: Character = ",", headerRecord: Int? = 0, firstDataRecord: Int = 1,
        decimalSeparator: Character = ".", dateOrder: CSVDateOrder = .yearMonthDay
    ) {
        self.encoding = encoding
        self.delimiter = delimiter
        self.headerRecord = headerRecord
        self.firstDataRecord = firstDataRecord
        self.decimalSeparator = decimalSeparator
        self.dateOrder = dateOrder
    }

    private enum CodingKeys: String, CodingKey { case encoding, delimiter, headerRecord, firstDataRecord, decimalSeparator, dateOrder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encoding = try c.decode(CSVTextEncoding.self, forKey: .encoding)
        delimiter = try c.decode(String.self, forKey: .delimiter).first ?? ","
        headerRecord = try c.decodeIfPresent(Int.self, forKey: .headerRecord)
        firstDataRecord = try c.decode(Int.self, forKey: .firstDataRecord)
        decimalSeparator = try c.decode(String.self, forKey: .decimalSeparator).first ?? "."
        dateOrder = try c.decode(CSVDateOrder.self, forKey: .dateOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(encoding, forKey: .encoding)
        try c.encode(String(delimiter), forKey: .delimiter)
        try c.encodeIfPresent(headerRecord, forKey: .headerRecord)
        try c.encode(firstDataRecord, forKey: .firstDataRecord)
        try c.encode(String(decimalSeparator), forKey: .decimalSeparator)
        try c.encode(dateOrder, forKey: .dateOrder)
    }
}

/// Result of analysing a CSV file's format.
public struct CSVSniffResult: Hashable, Sendable {
    public var dialect: CSVDialect
    /// True if day/month order could not be proven from the data (e.g. every date is like 03/04/2024);
    /// the wizard should ask the user to confirm `dialect.dateOrder`.
    public var isDateOrderAmbiguous: Bool
    /// True if the decimal separator could not be proven (e.g. every number is like `1,234`).
    public var isDecimalSeparatorAmbiguous: Bool
}

/// Detects encoding, delimiter, header row, decimal separator and date order of a CSV file.
public enum CSVSniffer {
    static let delimiters: [Character] = [";", ",", "\t", "|"]

    /// Number of leading records inspected to find the delimiter, the header and the date column.
    static let sampleSize = 200

    /// Analyses `data`. Never fails: unknown aspects fall back to sensible defaults.
    ///
    /// Delimiter and header are decided on the head of the file; the decimal separator and the date
    /// order are decided on *all* rows, so that a single unambiguous value anywhere in the file
    /// (`25/03/2024`, `12,50`) settles the question.
    public static func sniff(_ data: Data) -> CSVSniffResult {
        let encoding = CSVTextEncoding.detect(data)
        let text = encoding.decode(data)
        return sniff(text: text, encoding: encoding)
    }

    static func sniff(text: String, encoding: CSVTextEncoding) -> CSVSniffResult {
        analyse(text: text, encoding: encoding).result
    }

    /// Sniffs `text` and returns the records of the whole file, split with the detected delimiter.
    static func analyse(text: String, encoding: CSVTextEncoding) -> (result: CSVSniffResult, records: [CSVCodec.Record]) {
        // Delimiter: the candidate that splits most records into the same number (> 1) of fields.
        // Only the head of the file is needed.
        let isSampled = text.utf8.count > 262_144
        let sample = isSampled ? String(text.prefix(131_072)) : text
        var best: (delimiter: Character, records: [CSVCodec.Record], score: Double, columns: Int) = (",", [], -1, 0)
        for delimiter in delimiters {
            let records = CSVCodec.parse(sample, delimiter: delimiter.asciiValue!, limit: sampleSize)
            guard !records.isEmpty else { continue }
            var histogram: [Int: Int] = [:]
            for record in records { histogram[record.fields.count, default: 0] += 1 }
            guard let mode = histogram.filter({ $0.key > 1 }).max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            let score = Double(mode.value) / Double(records.count)
            if score > best.score + 1e-9 || (abs(score - best.score) <= 1e-9 && mode.key > best.columns) {
                best = (delimiter, records, score, mode.key)
            }
        }
        if best.score < 0 {
            best = (",", CSVCodec.parse(sample, delimiter: 44, limit: sampleSize), 0, 1)
        }
        let head = best.records
        let columns = best.columns

        // Header: the first record with the modal field count, unless it already contains data.
        var dialect = CSVDialect(encoding: encoding, delimiter: best.delimiter, headerRecord: nil, firstDataRecord: 0)
        if let candidate = head.firstIndex(where: { $0.fields.count == columns }) {
            let cells = head[candidate].fields
            let dataLike = cells.contains { isDataLike($0) }
            let nonEmpty = cells.filter { !$0.isEmpty }
            let known = nonEmpty.contains { CSVField.match(header: $0) != nil }
            let laterHasData = head.dropFirst(candidate + 1).contains { $0.fields.contains(where: isDataLike) }
            // Unknown titles must at least be distinct to count as a header; recognised ones may repeat
            // (bank statements often have two "Währung" columns).
            let unique = Set(nonEmpty.map { $0.lowercased() }).count == nonEmpty.count
            if !dataLike, !nonEmpty.isEmpty, known || (unique && (laterHasData || head.count == candidate + 1)) {
                dialect.headerRecord = candidate
                dialect.firstDataRecord = candidate + 1
            } else {
                dialect.firstDataRecord = candidate
            }
        }

        // The whole file, split once; `CSVDocument` reuses these records.
        let records = head.count < sampleSize && !isSampled ? head : CSVCodec.parse(text, delimiter: best.delimiter.asciiValue!)
        let dataRecords = records.dropFirst(dialect.firstDataRecord)

        // Decimal separator: vote over all numeric cells.
        var comma = 0, dot = 0, ambiguousComma = 0, ambiguousDot = 0
        func vote(_ cell: String) {
            switch CSVValueParser.separatorEvidence(cell) {
            case .comma: comma += 1
            case .dot: dot += 1
            case .ambiguousComma: ambiguousComma += 1
            case .ambiguousDot: ambiguousDot += 1
            case .none: break
            }
        }
        // Date order: analysed on the column with the most date-like cells (found in the head of the file).
        var dateCounts = [Int](repeating: 0, count: max(columns, 1))
        for (position, record) in dataRecords.enumerated() {
            if position < sampleSize {
                for (index, cell) in record.fields.enumerated() where !cell.isEmpty {
                    if CSVValueParser.looksLikeDate(cell) {
                        if index < dateCounts.count { dateCounts[index] += 1 }
                        continue
                    }
                    if CSVValueParser.looksNumeric(cell) { vote(cell) }
                }
            } else {
                // Beyond the head only cheap tests run per cell. Of all date notations just dotted ones
                // ("02.01.2024") could be mistaken for separator evidence, so only those are checked.
                for cell in record.fields where CSVValueParser.hasSeparator(cell) && CSVValueParser.looksNumeric(cell) {
                    if CSVValueParser.hasRepeatedDot(cell), CSVValueParser.looksLikeDate(cell) { continue }
                    vote(cell)
                }
            }
        }
        var decimalAmbiguous = false
        if comma != dot {
            dialect.decimalSeparator = comma > dot ? "," : "."
            // A sizeable minority voting the other way (mixed notations) needs the user's confirmation.
            decimalAmbiguous = min(comma, dot) * 4 >= max(comma, dot)
        } else if comma == 0, ambiguousComma != ambiguousDot || ambiguousComma > 0 {
            // Only values like "1,234" or "1.234". The delimiter tells the locale: semicolon files are
            // written with decimal commas (so a lone dot groups thousands), comma files with decimal
            // points. Otherwise a lone separator is more often a decimal separator.
            switch best.delimiter {
            case ";": dialect.decimalSeparator = ","
            case ",": dialect.decimalSeparator = "."
            default: dialect.decimalSeparator = ambiguousComma > ambiguousDot ? "," : "."
            }
            decimalAmbiguous = true
        } else {
            dialect.decimalSeparator = best.delimiter == ";" ? "," : "."
            decimalAmbiguous = comma + dot > 0
        }

        var dateAmbiguous = false
        if let dateColumn = dateCounts.indices.max(by: { dateCounts[$0] < dateCounts[$1] }), dateCounts[dateColumn] > 0 {
            let cells = dataRecords.compactMap { $0.fields.count > dateColumn ? $0.fields[dateColumn] : nil }.filter { !$0.isEmpty }
            (dialect.dateOrder, dateAmbiguous) = dateOrder(of: cells, decimalComma: dialect.decimalSeparator == ",")
        } else {
            dialect.dateOrder = dialect.decimalSeparator == "," ? .dayMonthYear : .yearMonthDay
        }
        return (CSVSniffResult(dialect: dialect, isDateOrderAmbiguous: dateAmbiguous, isDecimalSeparatorAmbiguous: decimalAmbiguous), records)
    }

    static func isDataLike(_ cell: String) -> Bool {
        guard !cell.isEmpty else { return false }
        if CSVValueParser.looksLikeDate(cell) { return true }
        guard CSVValueParser.looksNumeric(cell) else { return false }
        // Pure numbers; "Column 1" or "Q1" style titles contain letters and are not data.
        return !cell.unicodeScalars.contains { $0.properties.isAlphabetic } || cell.unicodeScalars.first.map { $0.value >= 48 && $0.value <= 57 || $0 == "-" } == true
    }

    /// Decides the component order of a whole column of dates.
    static func dateOrder(of cells: [String], decimalComma: Bool) -> (CSVDateOrder, ambiguous: Bool) {
        var separator: Unicode.Scalar?
        var numeric: [CSVValueParser.DateTokens] = []
        numeric.reserveCapacity(cells.count)
        for cell in cells {
            guard let tokens = CSVValueParser.tokenize(cell), tokens.namedMonth == nil, tokens.numbers.count >= 3 else { continue }
            if tokens.numbers[0].digits == 4 { return (.yearMonthDay, false) }
            if separator == nil { separator = tokens.separator }
            numeric.append(tokens)
        }
        guard !numeric.isEmpty else { return (.yearMonthDay, false) }
        func analyse(_ order: CSVDateOrder) -> (valid: Bool, inversions: Int) {
            var previous: Day?
            var ascendingBreaks = 0, descendingBreaks = 0
            for tokens in numeric {
                guard let day = CSVValueParser.date(tokens, order: order)?.day else { return (false, 0) }
                if let previous {
                    if day < previous { ascendingBreaks += 1 }
                    if day > previous { descendingBreaks += 1 }
                }
                previous = day
            }
            return (true, min(ascendingBreaks, descendingBreaks))
        }
        let dmy = analyse(.dayMonthYear), mdy = analyse(.monthDayYear)
        switch (dmy.valid, mdy.valid) {
        case (true, false): return (.dayMonthYear, false)
        case (false, true): return (.monthDayYear, false)
        case (false, false): return (analyse(.yearMonthDay).valid ? .yearMonthDay : .dayMonthYear, true)
        case (true, true):
            // Both readings are possible for every row. Exports are sorted by date, so the reading
            // that yields the more monotonic column wins; otherwise fall back to regional conventions.
            if dmy.inversions != mdy.inversions { return (dmy.inversions < mdy.inversions ? .dayMonthYear : .monthDayYear, true) }
            if separator == "." || decimalComma { return (.dayMonthYear, true) }
            return (separator == "/" ? .monthDayYear : .dayMonthYear, true)
        }
    }
}

/// A CSV file split into a header and data rows, ready for column mapping.
///
/// ```swift
/// var sniffed = CSVSniffer.sniff(data)            // detect everything …
/// sniffed.dialect.delimiter = ";"                 // … let the user override anything
/// let document = CSVDocument(data: data, dialect: sniffed.dialect)
/// ```
public struct CSVDocument: Hashable, Sendable {
    public var dialect: CSVDialect
    /// Column titles; generated ("Column 1" …) when the file has no header row.
    public var header: [String]
    /// Data rows, each padded to `header.count` cells.
    public var rows: [[String]]
    /// 1-based line in the file on which each data row starts (parallel to `rows`).
    public var lineNumbers: [Int]
    public var isDateOrderAmbiguous = false
    public var isDecimalSeparatorAmbiguous = false

    /// Sniffs the format and parses the file.
    public init(data: Data) {
        let encoding = CSVTextEncoding.detect(data)
        let text = encoding.decode(data)
        let analysis = CSVSniffer.analyse(text: text, encoding: encoding)
        self.init(records: analysis.records, dialect: analysis.result.dialect)
        isDateOrderAmbiguous = analysis.result.isDateOrderAmbiguous
        isDecimalSeparatorAmbiguous = analysis.result.isDecimalSeparatorAmbiguous
    }

    /// Parses the file with an explicit dialect (e.g. the sniffed one with user overrides).
    public init(data: Data, dialect: CSVDialect) {
        self.init(text: dialect.encoding.decode(data), dialect: dialect)
    }

    /// Parses already decoded text.
    public init(text: String, dialect: CSVDialect) {
        self.init(records: CSVCodec.parse(text, delimiter: dialect.delimiter.asciiValue ?? 44), dialect: dialect)
    }

    init(records: [CSVCodec.Record], dialect: CSVDialect) {
        self.dialect = dialect
        var header: [String] = []
        if let index = dialect.headerRecord, index < records.count { header = records[index].fields }
        let data = records.dropFirst(max(dialect.firstDataRecord, 0))
        var width = header.count
        for record in data where record.fields.count > width {
            // Ignore trailing empty cells produced by a delimiter at the end of the line.
            var count = record.fields.count
            while count > width, record.fields[count - 1].isEmpty { count -= 1 }
            width = max(width, count)
        }
        for column in header.count..<max(width, header.count) { header.append("Column \(column + 1)") }
        for index in header.indices where header[index].isEmpty { header[index] = "Column \(index + 1)" }
        self.header = header
        var rows: [[String]] = []
        var lines: [Int] = []
        rows.reserveCapacity(data.count)
        lines.reserveCapacity(data.count)
        for record in data {
            var fields = record.fields
            if fields.count > width { fields.removeLast(fields.count - width) }
            while fields.count < width { fields.append("") }
            rows.append(fields)
            lines.append(record.line)
        }
        self.rows = rows
        lineNumbers = lines
    }
}
