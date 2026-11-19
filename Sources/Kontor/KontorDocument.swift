import SwiftUI
import UniformTypeIdentifiers
import KontorModel
import KontorUI
import KontorSampleData

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
/// one long-lived `PortfolioStore` per document: undo registration marks the document edited
/// without SwiftUI diffing/copying the whole file through a binding on every keystroke.
///
/// Saving never touches the main actor. AppKit asks for the snapshot on a background thread *while
/// the main thread waits for it* (`-[NSDocument _waitForUserInteractionUnblocking]`), so hopping to
/// the main thread there deadlocks every save and autosave. The store mirrors its file into
/// `latest` (a lock-protected value) on every change, and `snapshot` reads that.
final class KontorDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.kontorPortfolio]
    static let writableContentTypes: [UTType] = [.kontorPortfolio]

    /// The store all windows of this document share.
    @MainActor private(set) lazy var store = PortfolioStore(file: latest.current, snapshot: latest)
    /// The current file, readable from any thread.
    private let latest: FileSnapshot
    /// What was repaired while opening (unusable exchange rates), to tell the user once.
    let repairs: DocumentIO.Repairs

    /// A new, untitled document starts from the sample-data starter: a cash account, a depot and
    /// the standard taxonomies, so the first transaction can be recorded right away.
    init(file: PortfolioFile = SampleData.starterPortfolio(name: "", baseCurrency: AppPreferences.defaultCurrency)) {
        latest = FileSnapshot(file)
        repairs = DocumentIO.Repairs()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            let result = try Self.read(data)
            latest = FileSnapshot(result.file)
            repairs = result.repairs
        }
    }

    /// The read path of the document, shared with the self-test.
    static func read(_ data: Data) throws -> (file: PortfolioFile, repairs: DocumentIO.Repairs) {
        do {
            return try DocumentIO.read(data)
        } catch let error as PortfolioFile.FormatError {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: error.description])
        } catch let error as DocumentIO.ReadError {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: error.description])
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The file is not a valid Kontor portfolio.",
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    /// Called on AppKit's background writing thread while the main thread is blocked: must not
    /// wait for the main actor.
    func snapshot(contentType: UTType) throws -> PortfolioFile {
        latest.current
    }

    /// Runs off the main thread: encoding even large portfolios never blocks the UI.
    func fileWrapper(snapshot: PortfolioFile, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.write(snapshot))
    }

    /// The write path of the document, shared with the self-test.
    static func write(_ file: PortfolioFile) throws -> Data {
        do {
            return try DocumentIO.write(file, pretty: AppPreferences.prettyPrintFiles)
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "The portfolio could not be saved because it contains a value that cannot be written (\(error.localizedDescription)).",
                NSUnderlyingErrorKey: error,
            ])
        }
    }
}

/// AppKit calls `snapshot` and `fileWrapper` on background threads. Both only touch `latest`
/// (lock-protected); `store` is main-actor isolated.
extension KontorDocument: @unchecked Sendable {}
