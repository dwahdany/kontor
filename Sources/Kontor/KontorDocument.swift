import SwiftUI
import UniformTypeIdentifiers
import KontorModel
import KontorUI

extension UTType {
    /// `.kontor` — the native JSON document (exported type, declared in Info.plist).
    static let kontorPortfolio = UTType(exportedAs: PortfolioFile.uniformTypeIdentifier, conformingTo: .json)
    /// Portfolio Performance's `.portfolio` container (imported type, declared in Info.plist).
    static let portfolioPerformance = UTType(importedAs: "info.portfolio-performance.portfolio", conformingTo: .data)

    /// Types offered by File ▸ Import….
    static let importable: [UTType] = [.xml, .portfolioPerformance, .commaSeparatedText, .json]
}

/// The document behind a portfolio window.
///
/// `ReferenceFileDocument` (rather than the value-type `FileDocument`) because edits flow through
/// one long-lived `PortfolioStore` per window: undo registration marks the document edited without
/// SwiftUI diffing/copying the whole file through a binding on every keystroke, and saving
/// snapshots the value-type `PortfolioFile` on the main thread (O(1), copy-on-write) and encodes
/// it on a background thread.
final class KontorDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.kontorPortfolio]
    static let writableContentTypes: [UTType] = [.kontorPortfolio]

    /// The store all windows of this document share.
    @MainActor private(set) lazy var store = PortfolioStore(file: initialFile)
    private let initialFile: PortfolioFile

    init(file: PortfolioFile = PortfolioFile(settings: Settings(baseCurrency: AppPreferences.defaultCurrency))) {
        initialFile = file
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            initialFile = try PortfolioFile(data: data)
        } catch let error as PortfolioFile.FormatError {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: error.description])
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The file is not a valid Kontor portfolio.",
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    /// SwiftUI takes the snapshot on the main thread; the hop keeps this correct if that ever changes.
    func snapshot(contentType: UTType) throws -> PortfolioFile {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { store.file }
        }
        return DispatchQueue.main.sync { store.file }
    }

    /// Runs off the main thread: encoding even large portfolios never blocks the UI.
    func fileWrapper(snapshot: PortfolioFile, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded(pretty: AppPreferences.prettyPrintFiles))
    }
}
