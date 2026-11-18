import Foundation
import KontorModel

/// What ``CSVQuoteParser`` found out (or was told) about a CSV file.
public struct CSVDialect: Hashable, Sendable {
    /// Field delimiter: `,` `;` tab or `|`.
    public var delimiter: Character
    /// Index of the first data row (rows before it are a preamble and/or the header).
    public var firstDataRow: Int
    /// Column titles, if the file has a header row.
    public var header: [String]?
    /// Zero-based index of the date column.
    public var dateColumn: Int
    /// Zero-based index of the close/price column.
    public var closeColumn: Int
    public var decimalSeparator: DecimalSeparator
    /// Resolved reading order for ambiguous numeric dates (nil = per-separator default).
    public var dateOrder: DayParser.NumericOrder?
}

/// Explicit settings that override auto-detection. Empty/nil values mean "detect".
public struct CSVOptions: Hashable, Sendable {
    /// `,` `;` `|`, a tab character, or the words `tab`, `comma`, `semicolon`, `pipe`.
    public var delimiter: String?
    /// Header title (case-insensitive) or 1-based column number.
    public var dateColumn: String?
    /// Header title (case-insensitive) or 1-based column number.
    public var closeColumn: String?
    public var decimalSeparator: DecimalSeparator?
    public var dateFormat: DateFormat

    public init(delimiter: String? = nil, dateColumn: String? = nil, closeColumn: String? = nil,
                decimalSeparator: DecimalSeparator? = nil, dateFormat: DateFormat = .auto) {
        self.delimiter = delimiter
        self.dateColumn = dateColumn
        self.closeColumn = closeColumn
        self.decimalSeparator = decimalSeparator
        self.dateFormat = dateFormat
    }
}

/// Reads historical quotes from CSV text, detecting delimiter, header, the date and close
/// columns, the decimal separator and the date notation.
public enum CSVQuoteParser {
    /// Parses a downloaded file (UTF-8 with or without BOM; falls back to Latin-1).
    public static func parse(_ data: Data, options: CSVOptions = CSVOptions()) throws -> [PricePoint] {
        try parse(decode(data), options: options)
    }

    /// Parses CSV text into ascending, de-duplicated price points. Rows whose date or price
    /// cannot be read (blank lines, footers, "null" quotes) are skipped.
    public static func parse(_ text: String, options: CSVOptions = CSVOptions()) throws -> [PricePoint] {
        let (dialect, rows) = try analyze(text, options: options)
        var points = [PricePoint]()
        points.reserveCapacity(rows.count - dialect.firstDataRow)
        let needed = max(dialect.dateColumn, dialect.closeColumn)
        for row in rows[dialect.firstDataRow...] where row.count > needed {
            guard let day = options.dateFormat.parse(row[dialect.dateColumn], order: dialect.dateOrder),
                  let value = NumberParser.parse(row[dialect.closeColumn], decimal: dialect.decimalSeparator),
                  let price = Price(checkedQuote: value)
            else { continue }
            points.append(PricePoint(day: day, price: price))
        }
        guard !points.isEmpty else { throw MarketDataError.malformedResponse("The CSV file contains no quotes.") }
        return normalized(points)
    }

    /// Detects the dialect without converting the rows (useful for a preview in the UI).
    public static func sniff(_ text: String, options: CSVOptions = CSVOptions()) throws -> CSVDialect {
        try analyze(text, options: options).dialect
    }

    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Analysis

    private static func analyze(_ text: String, options: CSVOptions) throws -> (dialect: CSVDialect, rows: [[String]]) {
        var text = text
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let delimiter = try explicitDelimiter(options.delimiter) ?? detectDelimiter(text)
        let rows = split(text, delimiter: delimiter)
        let format = options.dateFormat

        // First data row: the first row with a date and a number in it.
        func isData(_ row: [String]) -> Bool {
            var dateAt = -1, dates = 0, numberAt = -1, numbers = 0
            for (i, cell) in row.enumerated() {
                if format.parse(cell) != nil { dates += 1; dateAt = i }
                if NumberParser.parse(cell) != nil { numbers += 1; numberAt = i }
            }
            // A date in one cell and a number in another (a Unix time counts as both).
            return dates > 0 && numbers > 0 && !(dates == 1 && numbers == 1 && dateAt == numberAt)
        }
        guard let firstData = rows.firstIndex(where: isData) else {
            throw MarketDataError.malformedResponse("The CSV file contains no rows with a date and a price.")
        }
        var header: [String]?
        if firstData > 0 {
            let candidate = rows[firstData - 1]
            if candidate.count >= 2, !candidate.contains(where: { format.parse($0) != nil }) {
                header = candidate.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        let sample = Array(rows[firstData...].prefix(64))
        let width = sample.map(\.count).max() ?? 0

        func column(_ c: Int) -> [String] { sample.compactMap { c < $0.count ? $0[c] : nil } }
        func share(_ c: Int, _ test: (String) -> Bool) -> Double {
            let cells = column(c).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return cells.isEmpty ? 0 : Double(cells.filter(test).count) / Double(cells.count)
        }
        func resolve(_ spec: String?, what: String) throws -> Int? {
            guard let spec = spec?.trimmingCharacters(in: .whitespaces), !spec.isEmpty else { return nil }
            if let header, let i = header.firstIndex(where: { $0.caseInsensitiveCompare(spec) == .orderedSame }) { return i }
            if let n = Int(spec), n >= 1, n <= width { return n - 1 }
            throw MarketDataError.invalidConfiguration("The CSV file has no \(what) column “\(spec)”.")
        }
        func headerMatch(_ names: [String], excluding: Int?, accept: (Int) -> Bool) -> Int? {
            guard let header else { return nil }
            let titles = header.map { $0.lowercased() }
            for name in names {
                if let i = titles.firstIndex(of: name), i != excluding, accept(i) { return i }
            }
            for name in names {
                if let i = titles.indices.first(where: { titles[$0].contains(name) && !titles[$0].contains("adj") && $0 != excluding && accept($0) }) {
                    return i
                }
            }
            return nil
        }

        // Date column.
        let isDate: (String) -> Bool = { format.parse($0) != nil }
        var dateColumn = try resolve(options.dateColumn, what: "date")
        if dateColumn == nil {
            dateColumn = headerMatch(["date", "datum", "day", "tag", "time", "timestamp", "zeit"], excluding: nil) { share($0, isDate) >= 0.8 }
                ?? (0..<width).first { share($0, isDate) >= 0.8 }
        }
        guard let dateColumn else {
            throw MarketDataError.malformedResponse("Could not find a date column in the CSV file.")
        }

        // Close column.
        let isNumber: (String) -> Bool = { NumberParser.parse($0) != nil }
        var closeColumn = try resolve(options.closeColumn, what: "price")
        if closeColumn == nil {
            closeColumn = headerMatch(
                ["close", "schluss", "schlusskurs", "last", "price", "kurs", "preis", "nav", "value", "wert", "quote", "rate"],
                excluding: dateColumn
            ) { share($0, isNumber) >= 0.5 } // a titled column may contain gaps ("null")
            if closeColumn == nil {
                let numeric = (0..<width).filter { $0 != dateColumn && share($0, isNumber) >= 0.8 }
                // Without a header, four or more numeric columns are read as open/high/low/close….
                closeColumn = numeric.count >= 4 ? numeric[3] : numeric.first
            }
        }
        guard let closeColumn else {
            throw MarketDataError.malformedResponse("Could not find a price column in the CSV file.")
        }

        let dialect = CSVDialect(
            delimiter: Character(Unicode.Scalar(delimiter)),
            firstDataRow: firstData,
            header: header,
            dateColumn: dateColumn,
            closeColumn: closeColumn,
            decimalSeparator: options.decimalSeparator ?? detectDecimalSeparator(column(closeColumn), delimiter: delimiter),
            dateOrder: format == .auto ? DayParser.detectOrder(rows[firstData...].lazy.compactMap { dateColumn < $0.count ? $0[dateColumn] : nil }) : nil
        )
        return (dialect, rows)
    }

    private static func explicitDelimiter(_ option: String?) throws -> UInt8? {
        guard let option, !option.isEmpty else { return nil }
        switch option.lowercased() {
        case "auto": return nil
        case ",", "comma": return UInt8(ascii: ",")
        case ";", "semicolon": return UInt8(ascii: ";")
        case "\t", "tab", "\\t": return UInt8(ascii: "\t")
        case "|", "pipe": return UInt8(ascii: "|")
        default: throw MarketDataError.invalidConfiguration("Unsupported CSV delimiter “\(option)”.")
        }
    }

    /// Picks the delimiter that splits the most lines into the same number (> 1) of fields.
    static func detectDelimiter(_ text: String) -> UInt8 {
        // Preference order breaks ties: with decimal commas, "2024-01-02;82,21" is consistent for
        // both ';' and ',' — the semicolon is the delimiter.
        let candidates: [UInt8] = [UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|"), UInt8(ascii: ",")]
        var counts = [[Int]](repeating: [], count: candidates.count)
        var lines = 0
        var current = [Int](repeating: 0, count: candidates.count)
        var inQuotes = false, lineHasContent = false
        func endLine() {
            if lineHasContent {
                for k in candidates.indices { counts[k].append(current[k]) }
                lines += 1
            }
            current = [Int](repeating: 0, count: candidates.count)
            lineHasContent = false
        }
        for b in text.utf8 {
            if b == UInt8(ascii: "\"") { inQuotes.toggle(); lineHasContent = true; continue }
            if !inQuotes, b == 0x0A || b == 0x0D {
                endLine()
                if lines >= 40 { break }
                continue
            }
            lineHasContent = true
            if !inQuotes, let k = candidates.firstIndex(of: b) { current[k] += 1 }
        }
        endLine()

        var best = UInt8(ascii: ","), bestScore = 0
        for k in candidates.indices {
            var frequency = [Int: Int]()
            for c in counts[k] where c > 0 { frequency[c, default: 0] += 1 }
            let score = frequency.values.max() ?? 0
            if score > bestScore {
                bestScore = score
                best = candidates[k]
            }
        }
        return best
    }

    /// Infers the decimal separator of a numeric column.
    static func detectDecimalSeparator(_ cells: [String], delimiter: UInt8) -> DecimalSeparator {
        var commaCells = 0, dotCells = 0
        for cell in cells {
            let dots = cell.utf8.filter { $0 == UInt8(ascii: ".") }.count
            let commas = cell.utf8.filter { $0 == UInt8(ascii: ",") }.count
            if dots > 0, commas > 0 {
                let lastDot = cell.utf8.lastIndex(of: UInt8(ascii: "."))!
                let lastComma = cell.utf8.lastIndex(of: UInt8(ascii: ","))!
                return lastDot > lastComma ? .point : .comma
            }
            if commas > 1 { return .point }
            if dots > 1 { return .comma }
            if commas == 1 {
                // "1,234" could be either; anything else ("82,2", "0,123", "82,2160") is decimal.
                let digitsAfter = cell.utf8.reversed().prefix { $0 != UInt8(ascii: ",") }.filter { $0 >= 48 && $0 <= 57 }.count
                let leadingZero = cell.trimmingCharacters(in: .whitespaces).hasPrefix("0,")
                if digitsAfter != 3 || leadingZero { return .comma }
                commaCells += 1
            }
            if dots == 1 { dotCells += 1 }
        }
        if dotCells > 0 { return .point }
        // Only "1,234"-shaped values: decimal commas unless the file is comma-delimited (where
        // such a value must have been quoted, which points to a thousands separator).
        if commaCells > 0 { return delimiter == UInt8(ascii: ",") ? .point : .comma }
        return .point
    }

    /// Splits CSV text into rows of fields (RFC 4180 quoting, any line ending). Blank lines are
    /// dropped.
    static func split(_ text: String, delimiter: UInt8) -> [[String]] {
        var text = text
        return text.withUTF8 { bytes -> [[String]] in
            var rows = [[String]]()
            var row = [String]()
            var field = [UInt8]()
            var inQuotes = false, fieldWasQuoted = false
            var i = 0
            let n = bytes.count
            func endField() {
                var s = String(decoding: field, as: UTF8.self)
                if !fieldWasQuoted { s = s.trimmingCharacters(in: .whitespaces) }
                row.append(s)
                field.removeAll(keepingCapacity: true)
                fieldWasQuoted = false
            }
            func endRow() {
                endField()
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row.removeAll(keepingCapacity: true)
            }
            while i < n {
                let b = bytes[i]
                if inQuotes {
                    if b == UInt8(ascii: "\"") {
                        if i + 1 < n, bytes[i + 1] == UInt8(ascii: "\"") {
                            field.append(b)
                            i += 1
                        } else {
                            inQuotes = false
                        }
                    } else {
                        field.append(b)
                    }
                } else if b == UInt8(ascii: "\"") {
                    inQuotes = true
                    fieldWasQuoted = true
                } else if b == delimiter {
                    endField()
                } else if b == 0x0A {
                    endRow()
                } else if b == 0x0D {
                    endRow()
                    if i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                } else {
                    field.append(b)
                }
                i += 1
            }
            if !field.isEmpty || !row.isEmpty { endRow() }
            return rows
        }
    }
}
