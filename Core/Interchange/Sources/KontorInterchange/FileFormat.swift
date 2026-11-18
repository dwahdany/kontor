import Foundation
import KontorModel

/// The kinds of files Kontor can be asked to open or import.
public enum FileFormat: String, Hashable, Sendable, CaseIterable {
    /// A Kontor document (`PortfolioFile` JSON) — open with `PortfolioFile(data:)`.
    case kontor
    /// Portfolio Performance XML — import with `PortfolioPerformanceImporter.read`.
    case portfolioPerformanceXML
    /// Portfolio Performance XML inside PP's ZIP container — also handled by `PortfolioPerformanceImporter.read`.
    case portfolioPerformanceZippedXML
    /// Portfolio Performance binary (protobuf) file — cannot be imported; ask the user to save as XML.
    case portfolioPerformanceBinary
    /// Password-protected Portfolio Performance file — cannot be imported; ask the user to save as XML.
    case portfolioPerformanceEncrypted
    /// Delimited text — import with `CSVDocument` / `CSVImporter`.
    case csv
    case unknown

    /// Whether an importer in this package (or `PortfolioFile(data:)`) can read the format.
    public var isReadable: Bool {
        switch self {
        case .kontor, .portfolioPerformanceXML, .portfolioPerformanceZippedXML, .csv: return true
        case .portfolioPerformanceBinary, .portfolioPerformanceEncrypted, .unknown: return false
        }
    }

    /// Short user-facing name.
    public var displayName: String {
        switch self {
        case .kontor: return "Kontor document"
        case .portfolioPerformanceXML: return "Portfolio Performance (XML)"
        case .portfolioPerformanceZippedXML: return "Portfolio Performance (compressed XML)"
        case .portfolioPerformanceBinary: return "Portfolio Performance (binary)"
        case .portfolioPerformanceEncrypted: return "Portfolio Performance (password-protected)"
        case .csv: return "CSV"
        case .unknown: return "Unknown format"
        }
    }

    /// For formats that cannot be read: what the user should do instead.
    public var advice: String? {
        switch self {
        case .portfolioPerformanceBinary: return PortfolioPerformanceImportError.binaryFormat.errorDescription
        case .portfolioPerformanceEncrypted: return PortfolioPerformanceImportError.encrypted.errorDescription
        case .unknown: return "The file is neither a Kontor document, a Portfolio Performance file nor a CSV file."
        default: return nil
        }
    }

    /// Identifies a file by content, using the file name only as a tie-breaker.
    ///
    /// ```swift
    /// switch FileFormat.detect(data: data, filename: url.lastPathComponent) {
    /// case .kontor: document = try PortfolioFile(data: data)
    /// case .portfolioPerformanceXML, .portfolioPerformanceZippedXML: result = try PortfolioPerformanceImporter.read(data)
    /// case .csv: wizard(CSVDocument(data: data))
    /// case let other: show(other.advice)
    /// }
    /// ```
    public static func detect(data: Data, filename: String? = nil) -> FileFormat {
        guard !data.isEmpty else { return .unknown }
        var fileExtension = ""
        if let filename, let dot = filename.lastIndex(of: "."), !filename[dot...].contains("/") {
            fileExtension = filename[filename.index(after: dot)...].lowercased()
        }
        switch PortfolioPerformanceImporter.container(of: data) {
        case .encrypted: return .portfolioPerformanceEncrypted
        case .binary: return .portfolioPerformanceBinary
        case .zippedXML: return .portfolioPerformanceZippedXML
        case .xml: return .portfolioPerformanceXML
        case .unknown: break
        }
        let head = [UInt8](data.prefix(4096))
        if ZipArchive.isZip(head) { return .unknown }
        let encoding = CSVTextEncoding.detect(data)
        let text = encoding.decode(data.prefix(65_536))
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if trimmed.hasPrefix("{") {
            // A Kontor document is a JSON object with these top-level keys.
            if fileExtension == PortfolioFile.fileExtension || trimmed.contains("\"formatVersion\"")
                || (trimmed.contains("\"securities\"") && trimmed.contains("\"transactions\"")) {
                return .kontor
            }
            return .unknown
        }
        if trimmed.hasPrefix("<") || trimmed.hasPrefix("[") { return .unknown }
        // Binary data is not CSV.
        if head.contains(0), encoding == .utf8 || encoding == .windows1252 { return .unknown }
        let sniffed = CSVSniffer.sniff(text: String(text), encoding: encoding)
        let records = CSVCodec.parse(String(text), delimiter: sniffed.dialect.delimiter.asciiValue ?? 44, limit: 50)
        let multiColumn = records.filter { $0.fields.count > 1 }.count
        if multiColumn > 0, multiColumn * 2 >= records.count { return .csv }
        if ["csv", "tsv", "txt"].contains(fileExtension), !records.isEmpty { return .csv }
        return .unknown
    }
}
