import Foundation
import KontorModel

/// Why a file could not be imported as a Portfolio Performance document.
/// `errorDescription` is written for end users and says what to do next.
public enum PortfolioPerformanceImportError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case emptyFile
    /// AES-encrypted `.portfolio` file (starts with the `PORTFOLIO` signature).
    case encrypted
    /// The binary (protocol buffers) format — plain (`PPPBV1`) or inside PP's ZIP container.
    case binaryFormat
    /// A ZIP archive that is not a compressed Portfolio Performance XML file.
    case unsupportedArchive(reason: String)
    /// Not XML at all.
    case notXML
    /// Well-formed XML whose root element is not `<client>`.
    case notPortfolioPerformance(rootElement: String)
    case malformedXML(line: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The file is empty."
        case .encrypted:
            return "This Portfolio Performance file is password-protected (AES-encrypted) and cannot be read directly. "
                + "Open it in Portfolio Performance, choose File › Save As › XML (without password) and import that file."
        case .binaryFormat:
            return "This file uses Portfolio Performance's binary format, which cannot be imported directly. "
                + "Open it in Portfolio Performance, choose File › Save As › XML and import that file."
        case .unsupportedArchive(let reason):
            return "The ZIP archive could not be read as a compressed Portfolio Performance file: \(reason). "
                + "Open the file in Portfolio Performance, choose File › Save As › XML and import that file."
        case .notXML:
            return "The file is not a Portfolio Performance XML file (it does not contain XML)."
        case .notPortfolioPerformance(let root):
            return "The file is XML, but not a Portfolio Performance file: expected the root element <client>, found <\(root)>."
        case .malformedXML(let line, let message):
            return "The XML is damaged near line \(line): \(message)."
        }
    }

    public var description: String { errorDescription ?? "import failed" }
}

/// Result of reading a Portfolio Performance file.
public struct PortfolioPerformanceImport: Hashable, Sendable {
    /// The converted document, ready to be saved as a `.kontor` file.
    public var file: PortfolioFile
    /// Counts and everything that was skipped or approximated.
    public var report: ImportReport
}

/// Reads Portfolio Performance files (the XStream `client` XML, plain or inside PP's ZIP container).
///
/// ```swift
/// let result = try PortfolioPerformanceImporter.read(data, name: "My Portfolio")
/// print(result.report.summary)
/// save(result.file)
/// ```
public enum PortfolioPerformanceImporter {
    /// The physical container of a Portfolio Performance file.
    public enum Container: String, Hashable, Sendable, CaseIterable {
        /// Plain XML (`<client>…`).
        case xml
        /// ZIP archive with `data.xml` (compressed XML).
        case zippedXML
        /// Protocol-buffers payload, plain (`PPPBV1`) or zipped (`data.portfolio`).
        case binary
        /// AES-encrypted (`PORTFOLIO` signature).
        case encrypted
        /// Not a Portfolio Performance container.
        case unknown
    }

    static let encryptedSignature = Array("PORTFOLIO".utf8)
    static let binarySignature = Array("PPPBV1".utf8)

    /// Classifies `data` by its leading bytes (and, for ZIP archives, the archive directory) without parsing it.
    public static func container(of data: Data) -> Container {
        let head = [UInt8](data.prefix(64))
        if head.starts(with: encryptedSignature) { return .encrypted }
        if head.starts(with: binarySignature) { return .binary }
        if ZipArchive.isZip(head) {
            guard let archive = try? ZipArchive([UInt8](data)) else { return .unknown }
            if archive.entries.contains(where: { $0.name == "data.xml" }) { return .zippedXML }
            if archive.entries.contains(where: { $0.name == "data.portfolio" }) { return .binary }
            return .unknown
        }
        return looksLikeClientXML(data) ? .xml : .unknown
    }

    /// True if the document's root element is `<client`. Only inspects the first few kilobytes.
    static func looksLikeClientXML(_ data: Data) -> Bool {
        let probe = [UInt8](data.prefix(4096))
        guard let text = String(bytes: probe, encoding: .utf8) ?? String(bytes: probe, encoding: .isoLatin1) else { return false }
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return false }
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        guard rest.hasPrefix("<client") else { return false }
        let after = rest.dropFirst("<client".count).first
        return after == nil || after == ">" || after == "/" || after!.isWhitespace
    }

    /// Converts a Portfolio Performance file into a `PortfolioFile`.
    ///
    /// - Parameters:
    ///   - data: contents of an `.xml` / `.portfolio` file (plain XML or zipped XML).
    ///   - name: document name for the result (PP files carry none); typically the file name without extension.
    /// - Throws: `PortfolioPerformanceImportError` with a user-presentable explanation.
    public static func read(_ data: Data, name: String = "") throws -> PortfolioPerformanceImport {
        var bytes = [UInt8](data)
        guard !bytes.isEmpty else { throw PortfolioPerformanceImportError.emptyFile }
        if bytes.starts(with: encryptedSignature) { throw PortfolioPerformanceImportError.encrypted }
        if bytes.starts(with: binarySignature) { throw PortfolioPerformanceImportError.binaryFormat }
        if ZipArchive.isZip(bytes) {
            bytes = try unzip(bytes)
            if bytes.starts(with: binarySignature) { throw PortfolioPerformanceImportError.binaryFormat }
        }
        guard let firstMeaningful = bytes.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF && $0 != 0xFF && $0 != 0xFE && $0 != 0 }) else {
            throw PortfolioPerformanceImportError.emptyFile
        }
        guard firstMeaningful == UInt8(ascii: "<") else { throw PortfolioPerformanceImportError.notXML }

        let tree: XMLTree
        do {
            tree = try XMLTree(parsing: bytes)
        } catch let error as XMLSyntaxError {
            throw PortfolioPerformanceImportError.malformedXML(line: error.line, message: error.message)
        }
        guard tree.name(of: tree.root) == "client" else {
            throw PortfolioPerformanceImportError.notPortfolioPerformance(rootElement: tree.name(of: tree.root))
        }
        var mapper = PPMapper(graph: XStreamGraph(tree), name: name)
        return mapper.run()
    }

    private static func unzip(_ bytes: [UInt8]) throws -> [UInt8] {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(bytes)
        } catch {
            throw PortfolioPerformanceImportError.unsupportedArchive(reason: "the archive directory is damaged")
        }
        if let entry = archive.entries.first(where: { $0.name == "data.xml" }) ?? archive.entries.first(where: { $0.name.lowercased().hasSuffix(".xml") }) {
            do {
                return try archive.contents(of: entry)
            } catch ZipArchive.Failure.encrypted {
                throw PortfolioPerformanceImportError.unsupportedArchive(reason: "the archive is password-protected")
            } catch ZipArchive.Failure.unsupportedMethod(let method) {
                throw PortfolioPerformanceImportError.unsupportedArchive(reason: "compression method \(method) is not supported")
            } catch ZipArchive.Failure.checksumMismatch {
                throw PortfolioPerformanceImportError.unsupportedArchive(reason: "the archive is damaged (checksum mismatch)")
            } catch {
                throw PortfolioPerformanceImportError.unsupportedArchive(reason: "the compressed data is damaged")
            }
        }
        if archive.entries.contains(where: { $0.name == "data.portfolio" }) { throw PortfolioPerformanceImportError.binaryFormat }
        throw PortfolioPerformanceImportError.unsupportedArchive(reason: "it does not contain a data.xml entry")
    }
}
