import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KontorInterchange
import KontorUI

// MARK: - Panels and documents (AppKit; only ever called from a user's click)

@MainActor
enum ImportPanels {
    /// File types offered by "Choose File…": Portfolio Performance (.xml, .portfolio, .zip) and delimited text.
    static var importable: [UTType] {
        var types: [UTType] = [.xml, .commaSeparatedText, .tabSeparatedText, .plainText, .zip, .json]
        for ext in ["portfolio", "csv", "tsv", "txt", PortfolioFile.fileExtension] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func chooseFile(message: String = "Choose a Portfolio Performance file or a CSV file") -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = importable
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDestination(fileName: String, type: UTType, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = fileName
        panel.message = message
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens `file` in a new, untitled document window. The shell offers no seam for this, so the
    /// document controller is asked to duplicate a temporary `.kontor` file ("open as a template").
    static func openAsNewDocument(_ file: PortfolioFile, name: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kontor Import \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = (name.isEmpty ? "Imported Portfolio" : name).replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent(safeName).appendingPathExtension(PortfolioFile.fileExtension)
        try file.encoded().write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try NSDocumentController.shared.duplicateDocument(withContentsOf: url, copying: true, displayName: safeName)
    }

    static func openDocument(at url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                Task { @MainActor in NSApp.presentError(error) }
            }
        }
    }
}

/// Hand-over between the Import screen's cards and the sheet: what the next chosen file is expected
/// to be. `SheetRequest.importFile` carries only a URL, so the hint travels here.
@MainActor
enum ImportHints {
    static var preferredTarget: CSVImportTarget?

    static func takeTarget() -> CSVImportTarget? {
        defer { preferredTarget = nil }
        return preferredTarget
    }
}

// MARK: - Small views

enum ByteText {
    /// "494 KB", "1.2 MB" — built on `Fmt`.
    static func string(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(Fmt.integer(bytes)) bytes" }
        if bytes < 1_000_000 { return "\(Fmt.integer(Int((Double(bytes) / 1_000).rounded()))) KB" }
        return "\(Fmt.number(Double(bytes) / 1_000_000, decimals: 1)) MB"
    }
}

extension ReviewStatus {
    var color: Color {
        switch self {
        case .ok: DS.Colors.green
        case .warning: DS.Colors.warning
        case .error: DS.Colors.red
        case .duplicate: .secondary
        }
    }
}

/// Icon + title + subtitle at the top of every sheet of this feature.
struct SheetTitle<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Spacing.l)
            trailing
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.l)
    }
}

extension SheetTitle where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A dashed target for file drops with a "Choose File…" button.
struct DropZone: View {
    var title = "Drop a Portfolio Performance file or CSV"
    var message = "Kontor recognizes the format and shows you what it found before anything changes."
    var isTargeted: Bool
    var compact = false
    var choose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: compact ? DS.Spacing.s : DS.Spacing.m) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: compact ? 28 : 38, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.xs) {
                Text(isTargeted ? "Release to import" : title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Choose File…", action: choose)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Choose a file to import (⇧⌘O)")
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, compact ? DS.Spacing.xl : DS.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(DS.Colors.cardFill.opacity(0.6)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5]))
        }
        .animation(DS.Motion.standard(reduceMotion), value: isTargeted)
        .accessibilityElement(children: .contain)
    }
}

/// A count with a status color: "198 Ready".
struct StatusChip: View {
    let status: ReviewStatus
    let count: Int

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: status.symbol)
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(status.color))
                .imageScale(.small)
            Text("\(Fmt.integer(count)) \(count == 1 ? status.title : status.pluralTitle)")
                .numeric()
                .foregroundStyle(count == 0 ? .tertiary : .primary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A numbered instruction ("1  Open the file in Portfolio Performance").
struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .numeric()
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
                .background(.tint.opacity(0.14), in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
