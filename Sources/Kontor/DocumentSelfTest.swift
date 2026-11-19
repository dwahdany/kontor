import AppKit
import SwiftUI
import KontorModel
import KontorUI
import KontorSampleData

/// `Kontor --document-selftest <directory | auto>` — exercises the *real* document machinery
/// (`DocumentGroup`, AppKit's `NSDocument` save/autosave/revert, the window wiring) of a normally
/// launched app, without any user interaction.
///
/// Unlike `--selftest`, which hosts the views itself, this mode needs the SwiftUI app life cycle,
/// so it runs inside a regular launch. Start it hidden and in the background so that it never
/// takes the focus (this is what `Scripts/selftest.sh --document` does):
///
///     open -n -g -j dist/Kontor.app --stdout out.txt --stderr err.txt \
///          --args --document-selftest auto -marketData.autoUpdateOnOpen NO
///
/// It writes one `ok`/`FAIL` line per step to standard output and to `<directory>/result.txt`,
/// ends with `RESULT pass` or `RESULT fail`, and exits with 0 or 1. A watchdog on a background
/// thread turns a blocked main thread (a deadlocked save) into a failure instead of a hang.
@MainActor
enum DocumentSelfTest {
    private static var isActive = false
    private static var stores: [PortfolioStore] = []
    private static var lines: [String] = []
    private static var failed = false
    private static var directory = URL(fileURLWithPath: NSTemporaryDirectory())
    private static let watchdog = Watchdog()

    static var requestedDirectory: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--document-selftest") else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "auto"
    }

    /// Called by the document window when it has wired a store (also after a revert).
    static func documentWindowAppeared(_ store: PortfolioStore) {
        guard isActive else { return }
        stores.append(store)
    }

    static func startIfRequested() {
        guard let requested = requestedDirectory else { return }
        isActive = true
        if requested != "auto" {
            directory = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("kontor-document-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        }
        Task { @MainActor in
            do {
                try await run()
            } catch {
                record(false, "aborted: \(error)")
            }
            finish()
        }
    }

    // MARK: Steps

    private static func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selftest.kontor")
        var original = SampleData.starterPortfolio(name: "Document Self-Test", baseCurrency: "EUR")
        let account = try unwrap(original.accounts.first, "starter has a cash account")
        original.transactions.append(Transaction(kind: .deposit, date: Day(iso: "2026-01-05")!, accountID: account.id, amount: Money(minor: 500_000, currency: account.currency)))
        try KontorDocument.write(original).write(to: url, options: .atomic)

        // Open through the document controller: the same path as File ▸ Open.
        watchdog.arm("opening the document", seconds: 30)
        let document: NSDocument = try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let document { continuation.resume(returning: document) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        let store = try await nextStore(after: 0, "document window appeared and wired its store")
        record(store.file == original, "opened file equals what was written")
        await waitUntil { store.undoManager != nil }
        record(store.undoManager != nil, "store has the document's undo manager")
        record(store.undoManager === document.undoManager, "it is the NSDocument's undo manager")
        record(store.onNonUndoableChange != nil, "change tracking is installed")
        record(store.services.chooseImportFile != nil, "services are installed")
        record(!document.isDocumentEdited, "a freshly opened document is clean")

        // Edit → dirty → save (the path that used to deadlock).
        store.addTransaction(Transaction(kind: .deposit, date: Day(iso: "2026-02-02")!, accountID: account.id, amount: Money(minor: 12_345, currency: account.currency), note: "edit 1"))
        await settle()
        await waitUntil { document.isDocumentEdited }
        record(document.isDocumentEdited, "an edit marks the document as edited")
        try await save(document, to: url, operation: .saveOperation, label: "Save")
        record(try readBack(url) == store.file, "the saved file equals the store's file")
        record(!document.isDocumentEdited, "the document is clean after saving")

        // Autosave in place.
        store.addTransaction(Transaction(kind: .withdrawal, date: Day(iso: "2026-02-03")!, accountID: account.id, amount: Money(minor: 2_000, currency: account.currency), note: "edit 2"))
        await waitUntil { document.hasUnautosavedChanges }
        record(document.hasUnautosavedChanges, "a second edit leaves unautosaved changes")
        watchdog.arm("autosave", seconds: 30)
        let autosaveError: Error? = await withCheckedContinuation { continuation in
            document.autosave(withImplicitCancellability: false) { error in continuation.resume(returning: error) }
        }
        watchdog.disarm()
        record(autosaveError == nil, "autosave completed" + (autosaveError.map { " (\($0.localizedDescription))" } ?? ""))
        record(try readBack(url) == store.file, "the autosaved file equals the store's file")

        // Undo back to the saved state and redo.
        let afterEdits = store.file
        document.undoManager?.undo()
        await settle()
        record(store.file.transactions.count == afterEdits.transactions.count - 1, "undo through the document's undo manager reverts the last edit")
        document.undoManager?.redo()
        await settle()
        record(store.file == afterEdits, "redo restores it")

        // A change that bypasses undo (automatic quote update) still dirties the document.
        try await save(document, to: url, operation: .saveOperation, label: "Save before the non-undoable change")
        store.mutate("Background Change", undoable: false) { $0.name = "Document Self-Test (background)" }
        await waitUntil { document.isDocumentEdited }
        record(document.isDocumentEdited, "a non-undoable change marks the document as edited")
        try await save(document, to: url, operation: .saveOperation, label: "Save after the non-undoable change")

        // The file changes on disk; revert. SwiftUI hands the window a NEW document and store.
        var external = store.file
        external.name = "Changed Elsewhere"
        external.transactions.append(Transaction(kind: .deposit, date: Day(iso: "2026-03-01")!, accountID: account.id, amount: Money(minor: 77_700, currency: account.currency), note: "external"))
        try KontorDocument.write(external).write(to: url, options: .atomic)
        // Give the file system notification a moment: reverting in the same instant as the
        // replacement has been seen to hand the document an unreadable file wrapper.
        for _ in 0..<5 {
            pumpEvent()
            try? await Task.sleep(for: .milliseconds(300))
        }
        let known = stores.count
        watchdog.arm("revert", seconds: 30)
        try document.revert(toContentsOf: url, ofType: document.fileType ?? PortfolioFile.uniformTypeIdentifier)
        watchdog.disarm()
        let reverted = try await nextStore(after: known, "after Revert the window is wired to the new store")
        record(reverted !== store, "revert produced a new store")
        record(reverted.file == external, "the reverted store holds the file from disk")
        await waitUntil { reverted.undoManager != nil }
        record(reverted.undoManager != nil, "the new store has an undo manager")
        record(reverted.onNonUndoableChange != nil, "the new store has change tracking")
        record(reverted.services.chooseImportFile != nil, "the new store has services")
        record(!document.isDocumentEdited, "the reverted document is clean")
        reverted.addTransaction(Transaction(kind: .deposit, date: Day(iso: "2026-03-02")!, accountID: account.id, amount: Money(minor: 100, currency: account.currency), note: "after revert"))
        await waitUntil { document.isDocumentEdited }
        record(document.isDocumentEdited, "an edit after Revert marks the document as edited")
        record(document.undoManager?.canUndo == true, "an edit after Revert is undoable")
        try await save(document, to: url, operation: .saveOperation, label: "Save after Revert")
        record(try readBack(url) == reverted.file, "the file saved after Revert equals the new store's file")
        record(try readBack(url).transactions.contains { $0.note == "after revert" }, "the edit made after Revert reached the disk")

        // Files that are not portfolios are refused instead of opening empty.
        for (name, text) in [("empty-object", "{}"), ("unrelated", "{\"name\":\"left-pad\",\"version\":\"1.0.0\"}"), ("null-collection", "{\"formatVersion\":1,\"transactions\":null}")] {
            let bad = directory.appendingPathComponent("\(name).kontor")
            try Data(text.utf8).write(to: bad)
            let opened: Bool = await withCheckedContinuation { continuation in
                NSDocumentController.shared.openDocument(withContentsOf: bad, display: false) { document, _, error in
                    document?.close()
                    continuation.resume(returning: document != nil && error == nil)
                }
            }
            record(!opened, "“\(text)” is refused as a document")
        }
        document.close()
    }

    // MARK: Helpers

    private static func save(_ document: NSDocument, to url: URL, operation: NSDocument.SaveOperationType, label: String) async throws {
        watchdog.arm(label, seconds: 30)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: document.fileType ?? PortfolioFile.uniformTypeIdentifier, for: operation) { error in
                continuation.resume(returning: error)
            }
        }
        watchdog.disarm()
        record(error == nil, "\(label) completed without blocking" + (error.map { " (\($0.localizedDescription))" } ?? ""))
        if let error { throw error }
    }

    private static func readBack(_ url: URL) throws -> PortfolioFile {
        try KontorDocument.read(Data(contentsOf: url)).file
    }

    private static func nextStore(after count: Int, _ label: String) async throws -> PortfolioStore {
        await waitUntil(timeout: 20) { stores.count > count }
        record(stores.count > count, label)
        guard stores.count > count, let store = stores.last else { throw Abort(description: label) }
        return store
    }

    private static func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline {
            pumpEvent()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lets AppKit finish the current "event": undo groups opened by an edit close at the end of
    /// an event, and a hidden app that is driven only by tasks never sees one on its own.
    private static func pumpEvent() {
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func settle() async {
        pumpEvent()
        try? await Task.sleep(for: .milliseconds(150))
    }

    private struct Abort: Error, CustomStringConvertible { var description: String }

    private static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw Abort(description: label) }
        return value
    }

    private static func record(_ ok: Bool, _ label: String) {
        if !ok { failed = true }
        let line = "\(ok ? "ok  " : "FAIL") \(label)"
        lines.append(line)
        print(line)
        fflush(stdout)
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private static func finish() -> Never {
        let verdict = "RESULT \(failed ? "fail" : "pass")"
        lines.append(verdict)
        print(verdict)
        fflush(stdout)
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        exit(failed ? 1 : 0)
    }

    /// Fails the run from a background thread if a step blocks the main thread for too long.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0

        func arm(_ label: String, seconds: Double) {
            lock.lock()
            generation += 1
            let armed = generation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                lock.lock()
                let stillArmed = generation == armed
                lock.unlock()
                guard stillArmed else { return }
                let message = "FAIL \(label) did not finish within \(Int(seconds)) s (main thread blocked?)\nRESULT fail\n"
                FileHandle.standardOutput.write(Data(message.utf8))
                if let path = ProcessInfo.processInfo.environment["KONTOR_SELFTEST_RESULT"] {
                    try? message.write(toFile: path, atomically: true, encoding: .utf8)
                }
                exit(1)
            }
        }

        func disarm() {
            lock.lock()
            generation += 1
            lock.unlock()
        }
    }
}
