import SwiftUI
import UniformTypeIdentifiers
import KontorInterchange
import KontorUI

/// The sheet behind `SheetRequest.importFile(url)`: identifies the file off the main actor, then
/// shows the Portfolio Performance summary, the CSV wizard, or specific guidance for files that
/// cannot be read. With no URL it asks for a file (button or drop — never a panel on its own).
/// `expectedTarget` says what the entry point expects `url` to contain (a CSV with transactions,
/// quotes or securities); it applies to that file only.
///
/// Launch state (screenshots): `step=file|content|mapping|review|done`, `target=transactions|quotes|securities`,
/// `filter=ok|warning|error|duplicate`, `line=<n>`, `remembered=on` (CSV wizard); `notes=collapsed`,
/// `matches=expanded|collapsed` (Portfolio Performance summary).
struct ImportSheet: View {
    let url: URL?
    var expectedTarget: CSVImportTarget?

    @Environment(PortfolioStore.self) private var store
    @State private var phase = Phase.choose
    @State private var isDropTargeted = false
    /// Counts the files this sheet started reading: only the latest one may set the phase.
    @State private var loadGeneration = 0

    enum Phase {
        case choose
        case loading(fileName: String)
        case portfolioPerformance(PortfolioPerformanceResult)
        case csv(CSVWizard)
        case kontorDocument(URL)
        case unreadable(format: FileFormat, fileName: String, advice: String)
        case failed(fileName: String, message: String)
    }

    var body: some View {
        Group {
            switch phase {
            case .choose:
                chooser
            case .loading(let fileName):
                loading(fileName)
            case .portfolioPerformance(let result):
                PortfolioPerformanceSummary(result: result, chooseAnother: chooseFile)
            case .csv(let wizard):
                CSVWizardView(wizard: wizard, chooseAnother: chooseFile)
            case .kontorDocument(let url):
                guidance(
                    symbol: "doc.badge.arrow.up", title: "This Is a Kontor Document",
                    fileName: url.lastPathComponent,
                    message: "Kontor documents are opened, not imported. It opens in its own window; this portfolio stays as it is."
                ) {
                    Button("Open “\(url.lastPathComponent)”") {
                        store.dismissSheet()
                        ImportPanels.openDocument(at: url)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .unreadable(let format, let fileName, let advice):
                UnreadableFileView(format: format, fileName: fileName, advice: advice, chooseAnother: chooseFile)
            case .failed(let fileName, let message):
                guidance(symbol: "exclamationmark.triangle", title: "This File Could Not Be Read", fileName: fileName, message: message) {
                    Button("Choose Another File…", action: chooseFile)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard let url = files.first else { return false }
            load(url)
            // Further files follow one after another, once this sheet is done.
            for other in files.dropFirst() { store.present(.importFile(other)) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task {
            if let url, case .choose = phase { load(url, expecting: expectedTarget) }
        }
    }

    // MARK: Phases

    private var chooser: some View {
        VStack(spacing: 0) {
            SheetTitle(symbol: "square.and.arrow.down", title: "Import", subtitle: "Portfolio Performance files and CSV exports from brokers and banks")
            Divider()
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                DropZone(isTargeted: isDropTargeted, compact: true, choose: chooseFile)
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    formatLine("shippingbox", "Portfolio Performance", "XML files (.xml, also zipped). Save encrypted or binary files as XML first.")
                    formatLine("tablecells", "CSV", "Transactions, quotes or a list of securities — any delimiter, encoding and number format.")
                }
            }
            .padding(DS.Spacing.xl)
            Divider()
            HStack {
                Text("Nothing is changed until you confirm, and every import can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 560)
    }

    private func formatLine(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("\(Text(title).fontWeight(.medium))  \(Text(text).foregroundStyle(.secondary))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loading(_ fileName: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView()
                .controlSize(.large)
            Text("Reading “\(fileName)”…")
                .font(.headline)
            Text("Large Portfolio Performance files take a moment.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, DS.Spacing.s)
        }
        .padding(DS.Spacing.xxl)
        .frame(width: 420)
    }

    private func guidance<Actions: View>(
        symbol: String, title: String, fileName: String, message: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.xs) {
                Text(title).font(.title3.weight(.semibold))
                Text(fileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                actions()
            }
        }
        .padding(DS.Spacing.xxl)
        .frame(width: 480)
    }

    // MARK: Loading

    private func chooseFile() {
        if let url = ImportPanels.chooseFile() { load(url) }
    }

    private func load(_ url: URL, expecting expected: CSVImportTarget? = nil) {
        loadGeneration += 1
        let run = loadGeneration
        phase = .loading(fileName: url.lastPathComponent)
        let current = store.file
        let today = store.today
        Task {
            let loaded = await store.whileBusy {
                await Background.run { ImportLoader.load(url, into: current, today: today) }
            }
            // Another file was chosen or dropped meanwhile: that one decides what the sheet shows.
            guard run == loadGeneration else { return }
            switch loaded {
            case .portfolioPerformance(let result):
                phase = .portfolioPerformance(result)
            case .csv(let data, let fileName):
                // Screenshots must not read or write the user's remembered layouts.
                let memory = store.launchState.isEmpty ? MappingMemory() : MappingMemory.ephemeral()
                let hint = store.launchValue("target", as: CSVImportTarget.self) ?? expected
                if store.launchValue("remembered") == "on" {
                    // Pretend this layout was imported before: remember what the automatic run produces.
                    var input = CSVPipelineInput(data: data, file: current)
                    input.targetHint = hint
                    let seed = input
                    let first = await store.whileBusy { await Background.run { CSVPipeline.run(seed) } }
                    guard run == loadGeneration else { return }
                    memory.remember(
                        RememberedMapping(
                            target: first.target, columns: first.mapping.columns, typeAliases: [:], dialect: first.dialect,
                            accountName: nil, depotName: nil, savedAt: Date(timeIntervalSince1970: 0)),
                        for: first.signature)
                }
                let wizard = CSVWizard(store: store, data: data, fileName: fileName, memory: memory)
                wizard.launch(
                    step: store.launchValue("step", as: CSVWizard.Step.self),
                    filter: store.launchValue("filter", as: ReviewStatus.self))
                wizard.start(target: hint)
                phase = .csv(wizard)
            case .kontorDocument:
                phase = .kontorDocument(url)
            case .unreadable(let format, let fileName, let advice):
                phase = .unreadable(format: format, fileName: fileName, advice: advice)
            case .failed(let fileName, let message):
                phase = .failed(fileName: fileName, message: message)
            }
        }
    }
}

// MARK: - Files that cannot be read

/// Encrypted / binary Portfolio Performance files and unknown formats: says exactly what to do.
struct UnreadableFileView: View {
    let format: FileFormat
    let fileName: String
    let advice: String
    var chooseAnother: () -> Void

    @Environment(PortfolioStore.self) private var store

    private var isPortfolioPerformance: Bool {
        format == .portfolioPerformanceEncrypted || format == .portfolioPerformanceBinary
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(symbol: isPortfolioPerformance ? "lock.doc" : "questionmark.folder", title: title, subtitle: fileName)
            Divider()
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text(explanation)
                    .fixedSize(horizontal: false, vertical: true)
                if isPortfolioPerformance {
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        Text("How to bring it in").font(.headline)
                        NumberedStep(number: 1, text: "Open the file in Portfolio Performance" + (format == .portfolioPerformanceEncrypted ? " and enter its password." : "."))
                        NumberedStep(number: 2, text: "Choose File › Save As… and pick the format “XML”" + (format == .portfolioPerformanceEncrypted ? " — without a password." : "."))
                        NumberedStep(number: 3, text: "Import the saved .xml file here. Quotes, accounts, transactions and taxonomies come along.")
                    }
                    .padding(DS.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                    Label("The saved XML file is not encrypted. Delete it after the import if you keep your data protected.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(format == .portfolioPerformanceEncrypted ? 1 : 0)
                        .accessibilityHidden(format != .portfolioPerformanceEncrypted)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text("What Kontor can import").font(.headline)
                        Label("Portfolio Performance files saved as XML (.xml)", systemImage: "shippingbox")
                        Label("CSV files with transactions, quotes or securities", systemImage: "tablecells")
                    }
                    .padding(DS.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                }
            }
            .padding(DS.Spacing.xl)
            Divider()
            HStack {
                Text("Nothing was changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(isPortfolioPerformance ? "Choose the XML File…" : "Choose Another File…", action: chooseAnother)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 560)
    }

    private var title: String {
        switch format {
        case .portfolioPerformanceEncrypted: "This File Is Password-Protected"
        case .portfolioPerformanceBinary: "This File Uses the Binary Format"
        default: "This File Is Not Recognized"
        }
    }

    private var explanation: String {
        switch format {
        case .portfolioPerformanceEncrypted:
            "It is an encrypted Portfolio Performance file. Kontor never asks for that password and cannot read the file directly — but Portfolio Performance can save an XML copy that imports completely."
        case .portfolioPerformanceBinary:
            "It is a Portfolio Performance file in the compact binary format, which cannot be read directly — but Portfolio Performance can save an XML copy that imports completely."
        default:
            advice
        }
    }
}
