import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Builds tab-separated text for "Copy" in tables — pastes cleanly into Numbers, Excel and Sheets.
///
/// ```swift
/// let tsv = TSV.string(
///     header: ["Name", "Shares", "Value"],
///     rows: selectedRows.map { [$0.name, TSV.number($0.shares.decimalValue), TSV.number($0.value.decimalValue)] }
/// )
/// Pasteboard.copy(tsv)
/// ```
public enum TSV {
    /// Joins cells with tabs and rows with newlines. Tabs/newlines inside cells become spaces.
    public static func string(header: [String]? = nil, rows: [[String]]) -> String {
        var out = ""
        out.reserveCapacity(rows.count * 48)
        func append(_ cells: [String]) {
            for (i, cell) in cells.enumerated() {
                if i > 0 { out.append("\t") }
                if cell.utf8.contains(where: { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                    out.append(String(cell.map { $0 == "\t" || $0.isNewline ? " " : $0 }))
                } else {
                    out.append(cell)
                }
            }
            out.append("\n")
        }
        if let header { append(header) }
        rows.forEach(append)
        return out
    }

    /// A machine-readable number for spreadsheets: no grouping, the locale's decimal separator
    /// (spreadsheets parse pasted numbers with the user's locale).
    public static func number(_ value: Decimal, locale: Locale = .current) -> String {
        var v = value
        return NSDecimalString(&v, locale)
    }
}

/// Clipboard helpers.
public enum Pasteboard {
    /// Replaces the clipboard contents with `string` (also offered as TSV for spreadsheet apps).
    @MainActor
    public static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        if string.contains("\t") {
            pb.setString(string, forType: NSPasteboard.PasteboardType(UTType.tabSeparatedText.identifier))
        }
    }
}

/// A compact search field for filtering a table in place. ⌘F focuses it when `focusShortcut` is on.
///
/// ```swift
/// @State private var filter = ""
/// …
/// .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: "Filter holdings") } }
/// ```
public struct QuickFilterField: View {
    @Binding private var text: String
    private let prompt: String
    private let focusShortcut: Bool
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String = "Filter", focusShortcut: Bool = true) {
        _text = text
        self.prompt = prompt
        self.focusShortcut = focusShortcut
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    if text.isEmpty { isFocused = false } else { text = "" }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 4)
        .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .background {
            if focusShortcut {
                Button("Filter") { isFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(prompt)
    }
}

/// A row-filter helper: all whitespace-separated terms must occur (case/diacritic-insensitive) in
/// at least one of the row's fields. Build it once per filter string, then test rows.
public struct QuickFilter: Sendable {
    private let terms: [String]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ fields: String...) -> Bool { matches(fields) }

    public func matches(_ fields: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.map(Self.fold)
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// A status line for the bottom of table screens: "128 transactions · 3 selected" plus optional totals.
public struct TableFooter<Trailing: View>: View {
    private let text: String
    private let trailing: Trailing

    /// - Parameters:
    ///   - noun: Singular ("transaction"). The plural appends "s" (or turns "…y" into "…ies")
    ///     unless `plural` is given ("securities", "entries").
    ///   - leading: Extra text before the count, e.g. the period.
    public init(
        count: Int, noun: String, plural: String? = nil, selected: Int = 0, filteredFrom total: Int? = nil,
        leading: String? = nil, @ViewBuilder trailing: () -> Trailing
    ) {
        let many = plural ?? Self.pluralize(noun)
        var parts = ["\(Fmt.integer(count)) \(count == 1 ? noun : many)"]
        if let leading, !leading.isEmpty { parts.insert(leading, at: 0) }
        let countIndex = parts.count - 1
        if let total, total != count { parts[countIndex] += " of \(Fmt.integer(total))" }
        if selected > 0 { parts.append("\(Fmt.integer(selected)) selected") }
        text = parts.joined(separator: " · ")
        self.trailing = trailing()
    }

    /// "security" → "securities", "trade" → "trades", "class" → "classes".
    nonisolated static func pluralize(_ noun: String) -> String {
        let lower = noun.lowercased()
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return noun.dropLast() + "ies"
        }
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("ch") || lower.hasSuffix("sh") { return noun + "es" }
        return noun + "s"
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(text)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.s)
            trailing
        }
        .font(.callout)
        .numeric()
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension TableFooter where Trailing == EmptyView {
    public init(count: Int, noun: String, plural: String? = nil, selected: Int = 0, filteredFrom total: Int? = nil, leading: String? = nil) {
        self.init(count: count, noun: noun, plural: plural, selected: selected, filteredFrom: total, leading: leading) { EmptyView() }
    }
}
