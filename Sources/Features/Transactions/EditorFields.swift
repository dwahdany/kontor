import SwiftUI
import KontorUI

/// The editor's keyboard focus targets, in tab order.
enum EditorFocus: Hashable {
    case kind, security, depot, counterDepot, account, counterAccount
    case shares, price, securityGross, rate, gross, fees, taxes, total, counterRate, counterAmount, note
}

// MARK: - Number field

/// A right-aligned number field of the transaction editor. Unlike the shared numeric fields it
/// reports *user* edits (so the draft knows which value was typed last), accepts simple
/// calculations (`3*120.5`) and can show a value as "calculated".
struct CalcField: View {
    let title: String
    let value: Int64
    let scaleDigits: Int
    let format: (Int64) -> String
    var isCalculated = false
    var isEmphasized = false
    var focus: FocusState<EditorFocus?>.Binding
    let target: EditorFocus
    let onEdit: (Int64) -> Void

    @State private var text = ""
    @State private var isInvalid = false

    private var isFocused: Bool { focus.wrappedValue == target }

    var body: some View {
        TextField(title, text: $text, prompt: Text(format(0)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(isEmphasized ? .body.weight(.semibold) : .body)
            .numeric()
            .foregroundStyle(isCalculated && !isFocused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .focused(focus, equals: target)
            .onSubmit { settle() }
            .overlay(alignment: .leading) {
                if isInvalid {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                        .padding(.leading, 6)
                        .help("Not a number or calculation")
                        .accessibilityLabel("Invalid number")
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(isCalculated ? "\(text), calculated" : text)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in
                // Follow the model unless the user is typing exactly this value right now.
                if !isFocused || Arithmetic.evaluate(text, scaleDigits: scaleDigits) ?? 0 != newValue { text = display(newValue) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { settle() }
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                if newText.trimmingCharacters(in: .whitespaces).isEmpty {
                    isInvalid = false
                    if value != 0 { onEdit(0) }
                } else if let parsed = Arithmetic.evaluate(newText, scaleDigits: scaleDigits) {
                    isInvalid = false
                    if parsed != value { onEdit(parsed) }
                } else {
                    isInvalid = true
                }
            }
    }

    private func display(_ value: Int64) -> String { value == 0 ? "" : format(value) }

    /// Replaces what was typed (possibly a calculation) by the canonical number.
    private func settle() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty || Arithmetic.evaluate(text, scaleDigits: scaleDigits) != nil {
            isInvalid = false
            text = display(value)
        }
    }
}

// MARK: - Entity field

/// A keyboard-first chooser for securities, accounts and depots: it takes part in the tab order,
/// opens with Space, Return or ↓ — or by simply starting to type the name — and lists matches in a
/// searchable popover (↑ ↓ ⏎ ⎋).
struct ComboField: View {
    let title: String
    @Binding var selection: UUID?
    let items: [PickerItem<UUID>]
    var placeholder = "Choose…"
    var allowsNone = false
    var isInvalid = false
    var focus: FocusState<EditorFocus?>.Binding
    let target: EditorFocus
    /// Opens the list right away (screenshots).
    var startsOpen = false

    @State private var isOpen = false
    @State private var initialQuery = ""

    private var selected: PickerItem<UUID>? { selection.flatMap { id in items.first { $0.id == id } } }
    private var isFocused: Bool { focus.wrappedValue == target }

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(selected?.title ?? placeholder)
                .foregroundStyle(selected == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.xs)
            if let detail = selected?.detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).numeric().lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.s)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isInvalid ? AnyShapeStyle(Color.red.opacity(0.7)) : AnyShapeStyle(DS.Colors.hairline), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .focusable(true, interactions: .edit)
        .focused(focus, equals: target)
        .onTapGesture {
            focus.wrappedValue = target
            open()
        }
        .onKeyPress(phases: .down) { press in
            guard !isOpen, press.modifiers.isSubset(of: [.shift]) else { return .ignored }
            switch press.key {
            case .space, .return, .downArrow, .upArrow:
                open()
                return .handled
            case .delete, .deleteForward:
                guard allowsNone else { return .ignored }
                selection = nil
                return .handled
            default:
                guard let character = press.characters.first, character.isLetter || character.isNumber else { return .ignored }
                open(query: press.characters)
                return .handled
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ComboList(title: title, items: items, selection: selection, allowsNone: allowsNone, initialQuery: initialQuery) { choice in
                selection = choice
                isOpen = false
            }
        }
        .onChange(of: startsOpen) { _, opens in if opens { open() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected?.title ?? placeholder)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func open(query: String = "") {
        initialQuery = query
        isOpen = true
    }
}

private struct ComboList: View {
    let title: String
    let items: [PickerItem<UUID>]
    let selection: UUID?
    let allowsNone: Bool
    let initialQuery: String
    let choose: (UUID?) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private struct Row: Identifiable {
        let index: Int
        let item: PickerItem<UUID>?
        var id: Int { index }
    }

    private var rows: [Row] {
        let ranked = FuzzyMatcher.rank(items, query: query) { [$0.title, $0.detail] + $0.keywords }.map(\.item)
        var result = [Row]()
        if allowsNone, query.isEmpty { result.append(Row(index: 0, item: nil)) }
        for item in ranked { result.append(Row(index: result.count, item: item)) }
        return result
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(title)", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if rows.indices.contains(highlighted) { choose(rows[highlighted].item?.id) }
                    }
            }
            .padding(DS.Spacing.m)
            Divider()
            if rows.isEmpty {
                Text(items.isEmpty ? "Nothing to choose from yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding(DS.Spacing.l)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                rowView(row, isHighlighted: row.index == highlighted)
                                    .id(row.index)
                                    .onTapGesture { choose(row.item?.id) }
                                    .onHover { if $0 { highlighted = row.index } }
                            }
                        }
                        .padding(DS.Spacing.xs)
                    }
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
                .frame(maxHeight: 264)
            }
        }
        .frame(width: 340)
        .onAppear {
            query = initialQuery
            searchFocused = true
            highlighted = initialQuery.isEmpty ? (rows.firstIndex { $0.item?.id == selection && selection != nil } ?? 0) : 0
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(rows.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .fontWeight(.semibold)
                .opacity(row.item?.id == selection && (row.item != nil || selection == nil) ? 1 : 0)
            if let item = row.item {
                Text(item.title).lineLimit(1)
                Spacer(minLength: DS.Spacing.s)
                Text(item.detail)
                    .font(.callout)
                    .numeric()
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            } else {
                Text("None")
                Spacer()
            }
        }
        .opacity(row.item?.isDimmed == true && !isHighlighted ? 0.55 : 1)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 5)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Kind picker

/// Colour of a kind's icon: the family it belongs to, nothing more.
struct KindIcon: View {
    @Environment(\.gainStyle) private var gainStyle
    let kind: Transaction.Kind

    var body: some View {
        Image(systemName: kind.symbol)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch kind.group {
        case .trades: .accentColor
        case .income: gainStyle.gain
        case .cash, .transfers: .secondary
        case .costs: DS.Colors.warning
        }
    }
}

/// The editor's kind chooser: a prominent button that opens a grouped, searchable list of all
/// fifteen kinds with their ⌃-shortcuts. ⌃K opens it from anywhere in the sheet.
struct KindPicker: View {
    let kind: Transaction.Kind
    var focus: FocusState<EditorFocus?>.Binding
    @Binding var isOpen: Bool
    let choose: (Transaction.Kind) -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            KindIcon(kind: kind).font(.title3)
            Text(kind.title).font(.title3.weight(.semibold)).lineLimit(1).fixedSize()
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.m)
        .frame(height: 32)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .focusable(true, interactions: .edit)
        .focused(focus, equals: .kind)
        .onTapGesture { isOpen = true }
        .onKeyPress(phases: .down) { press in
            guard !isOpen, press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .space, .return, .downArrow, .upArrow:
                isOpen = true
                return .handled
            default:
                return .ignored
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            KindList(selection: kind) { choice in
                isOpen = false
                choose(choice)
            }
        }
        .help("Change the type (⌃K)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Type")
        .accessibilityValue(kind.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOpen = true }
    }
}

private struct KindList: View {
    let selection: Transaction.Kind
    let choose: (Transaction.Kind) -> Void

    @State private var query = ""
    @State private var highlighted: Transaction.Kind?
    @FocusState private var searchFocused: Bool

    private var sections: [(group: KindGroup, kinds: [Transaction.Kind])] {
        KindGroup.allCases.compactMap { group in
            let kinds = group.kinds.filter { kind in
                query.isEmpty || FuzzyMatcher.match(query, in: kind.title) != nil || FuzzyMatcher.match(query, in: group.title)?.isTight == true
            }
            return kinds.isEmpty ? nil : (group, kinds)
        }
    }

    private var flat: [Transaction.Kind] { sections.flatMap(\.kinds) }

    var body: some View {
        let sections = sections
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search types", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let kind = highlighted ?? flat.first { choose(kind) } }
            }
            .padding(DS.Spacing.m)
            Divider()
            if sections.isEmpty {
                Text("No matching type").foregroundStyle(.secondary).padding(DS.Spacing.l)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(sections, id: \.group) { section in
                        Text(section.group.title)
                            .font(.kontorCaption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.top, DS.Spacing.xs)
                        ForEach(section.kinds, id: \.self) { kind in
                            row(kind)
                                .onTapGesture { choose(kind) }
                                .onHover { if $0 { highlighted = kind } }
                        }
                    }
                }
                .padding(DS.Spacing.xs)
            }
        }
        .frame(width: 440)
        .onAppear {
            searchFocused = true
            highlighted = selection
        }
        .onChange(of: query) { _, _ in highlighted = flat.first }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
    }

    private func move(_ step: Int) {
        let kinds = flat
        guard !kinds.isEmpty else { return }
        let index = highlighted.flatMap { kinds.firstIndex(of: $0) } ?? (step > 0 ? -1 : kinds.count)
        highlighted = kinds[min(max(index + step, 0), kinds.count - 1)]
    }

    private func row(_ kind: Transaction.Kind) -> some View {
        let isHighlighted = highlighted == kind
        return HStack(spacing: DS.Spacing.s) {
            Group {
                if isHighlighted {
                    Image(systemName: kind.symbol).foregroundStyle(.white)
                } else {
                    KindIcon(kind: kind)
                }
            }
            .frame(width: 20)
            Text(kind.title)
                .fontWeight(kind == selection ? .semibold : .regular)
                .lineLimit(1)
                .layoutPriority(1)
            Text(kind.explanation)
                .font(.callout)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.xs)
            if let key = kind.shortcutKey {
                Text("⌃\(String(key).uppercased())")
                    .font(.callout)
                    .numeric()
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 4)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
