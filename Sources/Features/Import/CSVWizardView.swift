import SwiftUI
import KontorInterchange
import KontorUI

/// The CSV wizard: one sheet, four steps, a preview that follows every change.
///
/// 1 File (encoding, delimiter, number and date notation) · 2 Content (what the rows are, defaults) ·
/// 3 Columns (mapping, type synonyms) · 4 Review (per-row status, selection) · result page.
/// Steps are freely reachable from the header — nothing is a dead end. ⌘← / ⌘→ move between steps.
struct CSVWizardView: View {
    @Bindable var wizard: CSVWizard
    var chooseAnother: () -> Void

    @Environment(PortfolioStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(symbol: "tablecells", title: "Import CSV", subtitle: subtitle) {
                if wizard.step != .done { StepIndicator(wizard: wizard) }
            }
            Divider()
            Group {
                switch wizard.step {
                case .file, .content, .mapping:
                    HStack(spacing: 0) {
                        Group {
                            switch wizard.step {
                            case .file: CSVFileStep(wizard: wizard, chooseAnother: chooseAnother)
                            case .content: CSVContentStep(wizard: wizard)
                            default: CSVMappingStep(wizard: wizard)
                            }
                        }
                        .frame(width: 348)
                        Divider()
                        CSVPreviewPane(wizard: wizard)
                    }
                case .review:
                    CSVReviewStep(wizard: wizard)
                case .done:
                    CSVDoneStep(wizard: wizard, chooseAnother: chooseAnother)
                }
            }
            .frame(height: 468)
            if wizard.step != .done {
                Divider()
                footer
            }
        }
        .frame(width: 980)
    }

    private var subtitle: String {
        guard let output = wizard.output else { return wizard.fileName }
        return "\(wizard.fileName) · \(Fmt.integer(output.rowCount)) \(output.rowCount == 1 ? "row" : "rows") · \(ByteText.string(wizard.data.count))"
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.l) {
            if let output = wizard.output {
                HStack(spacing: DS.Spacing.m) {
                    StatusChip(status: .ok, count: output.counts.ok)
                    StatusChip(status: .warning, count: output.counts.warning)
                    StatusChip(status: .error, count: output.counts.error)
                    StatusChip(status: .duplicate, count: output.counts.duplicate)
                }
                // The counts never wrap or shrink; the reason next to them gives way instead.
                .fixedSize()
                .opacity(wizard.isComputing ? 0.5 : 1)
                .help("Ready and warning rows are imported; errors cannot be, duplicates are skipped unless you tick them in the review.")
            }
            if wizard.isComputing { ProgressView().controlSize(.small) }
            Spacer(minLength: DS.Spacing.s)
            if wizard.step == .review, let reason = wizard.blockingReason {
                // What stands in the way — and, where another step resolves it, the way there.
                if let step = wizard.blockingStep {
                    Button(reason) { wizard.step = step }
                        .buttonStyle(.link)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .help("Go to step “\(step.title)”")
                } else {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Back") { move(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(wizard.step == .file)
            if wizard.step == .review {
                Button(importTitle) { Task { await wizard.performImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizard.blockingReason != nil || wizard.isComputing || wizard.isImporting)
            } else {
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizard.output == nil)
                    .background {
                        // ⌘→ as the counterpart of Back's ⌘←.
                        Button("Next Step") { move(1) }
                            .keyboardShortcut(.rightArrow, modifiers: .command)
                            .disabled(wizard.output == nil)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            }
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.m)
    }

    private var importTitle: String {
        let count = wizard.importCount
        return "Import \(Fmt.integer(count)) \(wizard.currentTarget.noun(count).capitalized)"
    }

    private func move(_ offset: Int) {
        let steps = CSVWizard.Step.numbered
        guard let index = steps.firstIndex(of: wizard.step), steps.indices.contains(index + offset) else { return }
        wizard.step = steps[index + offset]
    }
}

/// "① File  ② Content  ③ Columns  ④ Review" — clickable.
private struct StepIndicator: View {
    @Bindable var wizard: CSVWizard

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(Array(CSVWizard.Step.numbered.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(DS.Colors.hairline)
                        .frame(width: 14, height: 1)
                }
                Button {
                    wizard.step = step
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .numeric()
                            .foregroundStyle(step == wizard.step ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .frame(width: 20, height: 20)
                            .background(step == wizard.step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                        Text(step.title)
                            .font(.callout.weight(step == wizard.step ? .semibold : .regular))
                            .foregroundStyle(step == wizard.step ? .primary : .secondary)
                        if step == .mapping, !wizard.missingFields.isEmpty || wizard.unrecognizedTypeCount > 0 {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(DS.Colors.warning)
                                .imageScale(.small)
                                .accessibilityLabel("needs attention")
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xxs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(wizard.output == nil)
                .accessibilityLabel("Step \(index + 1): \(step.title)")
                .accessibilityAddTraits(step == wizard.step ? .isSelected : [])
            }
        }
    }
}

// MARK: - Step 1: file and format

private struct CSVFileStep: View {
    @Bindable var wizard: CSVWizard
    var chooseAnother: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    Text(wizard.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose Another File…", action: chooseAnother)
                    .buttonStyle(.link)
            }
            Section {
                Picker("Encoding", selection: binding(\.encoding)) {
                    ForEach(CSVTextEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Delimiter", selection: binding(\.delimiter)) {
                    Text("Semicolon  ;").tag(Character(";"))
                    Text("Comma  ,").tag(Character(","))
                    Text("Tab").tag(Character("\t"))
                    Text("Pipe  |").tag(Character("|"))
                }
                Picker("Numbers", selection: binding(\.decimalSeparator)) {
                    Text("1,234.56").tag(Character("."))
                    Text("1.234,56").tag(Character(","))
                }
                if wizard.isDecimalSeparatorAmbiguous {
                    hint("The numbers in this file can be read both ways. Check the preview.")
                }
                Picker("Dates", selection: binding(\.dateOrder)) {
                    ForEach(CSVDateOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if wizard.isDateOrderAmbiguous {
                    hint("Day and month cannot be told apart in this file. Check the preview.")
                }
                Toggle("First row has column titles", isOn: Binding(
                    get: { wizard.currentDialect.headerRecord != nil },
                    set: { wizard.setHasHeader($0) }))
            } header: {
                Text("Format")
            } footer: {
                HStack {
                    Text(wizard.isDialectOverridden ? "You changed the detected format." : "Detected automatically — change anything that looks wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if wizard.isDialectOverridden {
                        Button("Reset") { wizard.resetDialect() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(wizard.output == nil)
    }

    private func hint(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(DS.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<CSVDialect, Value>) -> Binding<Value> {
        Binding(
            get: { wizard.currentDialect[keyPath: keyPath] },
            set: { value in wizard.setDialect { $0[keyPath: keyPath] = value } })
    }
}

extension CSVTextEncoding {
    var title: String {
        switch self {
        case .utf8: "Unicode (UTF-8)"
        case .utf16LittleEndian: "Unicode (UTF-16, little endian)"
        case .utf16BigEndian: "Unicode (UTF-16, big endian)"
        case .windows1252: "Western (Windows-1252)"
        }
    }
}

extension CSVDateOrder {
    var title: String {
        switch self {
        case .yearMonthDay: "2024-03-31 · year first"
        case .dayMonthYear: "31.03.2024 · day first"
        case .monthDayYear: "03/31/2024 · month first"
        }
    }
}

// MARK: - Step 2: content and defaults

private struct CSVContentStep: View {
    @Bindable var wizard: CSVWizard
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        Form {
            Section("This file contains") {
                ForEach(CSVImportTarget.allCases, id: \.self) { target in
                    Button {
                        wizard.setTarget(target)
                    } label: {
                        HStack(alignment: .top, spacing: DS.Spacing.s) {
                            Image(systemName: wizard.currentTarget == target ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(wizard.currentTarget == target ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .imageScale(.large)
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(target.title).fontWeight(.medium)
                                Text(target.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(wizard.currentTarget == target ? .isSelected : [])
                }
            }
            switch wizard.currentTarget {
            case .transactions:
                Section {
                    LabeledContent("Cash Account") {
                        AccountPicker(selection: Binding(get: { wizard.accountID }, set: { wizard.setAccount($0) }), allowsNone: true)
                    }
                    LabeledContent("Depot") {
                        DepotPicker(selection: Binding(get: { wizard.depotID }, set: { wizard.setDepot($0) }), allowsNone: true)
                    }
                    Toggle("Create accounts named in the file", isOn: Binding(
                        get: { wizard.createMissingAccounts }, set: { wizard.setCreateMissingAccounts($0) }))
                } header: {
                    Text("Defaults")
                } footer: {
                    Text("For rows that name no cash account or no depot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .quotes:
                Section {
                    LabeledContent("Security") {
                        SecurityPicker(selection: Binding(get: { wizard.securityID }, set: { wizard.setSecurity($0) }), includesRetired: true)
                    }
                } header: {
                    Text("Quotes for")
                } footer: {
                    Text(store.file.securities.isEmpty
                        ? "This portfolio has no securities yet. Add the security first, then import its quotes."
                        : "New days are added; a day with the same quote is skipped. A day whose quote differs is replaced — the review marks it.")
                        .font(.caption)
                        .foregroundStyle(store.file.securities.isEmpty ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .securities:
                Section {
                    Text("Securities that already exist — same ISIN, ticker, WKN or name — are skipped. Transactions are not created.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(wizard.output == nil)
    }
}

// MARK: - Step 3: column mapping

private struct CSVMappingStep: View {
    @Bindable var wizard: CSVWizard
    /// Decided when the step appears, so that nothing jumps while the user resolves the types.
    @State private var typesFirst = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                if wizard.usedMemory {
                    banner("clock.arrow.circlepath", "Known layout — the mapping from your last import of this format is applied.", color: .accentColor)
                }
                if !wizard.missingFields.isEmpty {
                    banner(
                        "exclamationmark.triangle.fill",
                        "Choose the column for " + wizard.missingFields.map(\.displayName).formatted(.list(type: .and)) + ". Without it nothing can be imported.",
                        color: DS.Colors.warning)
                }
                if let output = wizard.output {
                    // Unknown type values block rows, so they come first; otherwise the columns do.
                    if typesFirst {
                        types(output)
                        columns(output)
                    } else {
                        columns(output)
                        types(output)
                    }
                }
            }
            .padding(DS.Spacing.l)
        }
        .onAppear { typesFirst = wizard.unrecognizedTypeCount > 0 }
    }

    @ViewBuilder private func columns(_ output: CSVPipelineOutput) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Columns").font(.headline)
            Spacer()
            Button("Reset to Automatic") { wizard.resetMapping() }
                .buttonStyle(.link)
                .font(.callout)
        }
        VStack(spacing: 0) {
            ForEach(Array(output.header.enumerated()), id: \.offset) { column, title in
                if column > 0 { Divider() }
                columnRow(
                    column, title: title, sample: output.columnSamples[column],
                    field: wizard.isMappingPending ? output.mapping.columns[column] : wizard.field(forColumn: column), target: output.target)
            }
        }
        .cardBackground(radius: DS.Radius.control)
    }

    @ViewBuilder private func types(_ output: CSVPipelineOutput) -> some View {
        if !output.typeValues.isEmpty {
            let unknown = wizard.unrecognizedTypeCount
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Transaction types").font(.headline)
                Text(unknown > 0
                    ? "\(Fmt.integer(unknown)) \(unknown == 1 ? "value is" : "values are") not recognized. Say what \(unknown == 1 ? "it means" : "they mean") — otherwise those rows are left out."
                    : "How the values of the type column are read. Change any that Kontor got wrong.")
                    .font(.caption)
                    .foregroundStyle(unknown > 0 ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(output.typeValues.enumerated()), id: \.element.id) { index, value in
                    if index > 0 { Divider() }
                    typeRow(value)
                }
            }
            .cardBackground(radius: DS.Radius.control)
        }
    }

    private func banner(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func columnRow(_ column: Int, title: String, sample: String, field: CSVField?, target: CSVImportTarget) -> some View {
        HStack(spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(sample.isEmpty ? "empty" : sample)
                    .font(.caption)
                    .foregroundStyle(sample.isEmpty ? .tertiary : .secondary)
                    .numeric()
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.s)
            Picker(title, selection: Binding(get: { field }, set: { wizard.setField($0, column: column) })) {
                Text("Ignore").tag(CSVField?.none)
                Divider()
                ForEach(target.fields, id: \.self) { candidate in
                    Text(candidate.displayName + (target.requiredFields.contains(candidate) ? " (required)" : ""))
                        .tag(CSVField?.some(candidate))
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .foregroundStyle(field == nil ? .secondary : .primary)
            .disabled(wizard.isMappingPending)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    private func typeRow(_ value: TypeValue) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if value.resolved == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                    .imageScale(.small)
                    .accessibilityLabel("Unknown type")
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(value.text)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(Fmt.integer(value.count)) \(value.count == 1 ? "row" : "rows")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
            }
            Spacer(minLength: DS.Spacing.s)
            Picker(value.text, selection: Binding(get: { wizard.alias(for: value.text) }, set: { wizard.setAlias($0, for: value.text) })) {
                Text(value.automatic.map { "Automatic: \($0.displayName)" } ?? "Not recognized").tag(CSVTransactionType?.none)
                Divider()
                ForEach(CSVTransactionType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(CSVTransactionType?.some(type))
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }
}

// MARK: - Live preview

/// The first rows of the file with, per row, what Kontor makes of it — updates with every change.
private struct CSVPreviewPane: View {
    @Bindable var wizard: CSVWizard

    private let lineWidth: CGFloat = 40
    private let readingWidth: CGFloat = 270
    private let cellWidth: CGFloat = 128
    private let rowHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text("Preview").font(.headline)
                if let output = wizard.output {
                    Text(caption(output))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .numeric()
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.m)
            Divider()
            if let output = wizard.output {
                if output.rowCount == 0 {
                    EmptyState("No Data Rows", symbol: "tablecells", message: "The file has column titles but no rows below them. Check the delimiter and the header setting.")
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(Array(output.sampleRows.enumerated()), id: \.offset) { index, cells in
                                    row(index, cells: cells, review: index < output.rows.count ? output.rows[index] : nil, mapping: output.mapping, output: output)
                                }
                            } header: {
                                header(output)
                            }
                        }
                    }
                    .opacity(wizard.isComputing ? 0.6 : 1)
                }
            } else {
                ProgressView("Reading the file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.cardFill)
    }

    private func caption(_ output: CSVPipelineOutput) -> String {
        let shown = min(output.rowCount, output.sampleRows.count)
        if shown == 1, output.rowCount == 1 { return "The only row, as Kontor reads it" }
        if shown == output.rowCount { return "All \(Fmt.integer(shown)) rows, as Kontor reads them" }
        return "First \(Fmt.integer(shown)) of \(Fmt.integer(output.rowCount)) rows, as Kontor reads them"
    }

    private func header(_ output: CSVPipelineOutput) -> some View {
        HStack(spacing: 0) {
            Text("Line")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: lineWidth, alignment: .trailing)
                .padding(.trailing, DS.Spacing.s)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kontor reads").font(.caption.weight(.semibold))
                Text(output.target.title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: readingWidth, alignment: .leading)
            ForEach(Array(output.header.enumerated()), id: \.offset) { column, title in
                let field = output.mapping.columns[column]
                VStack(alignment: .leading, spacing: 1) {
                    Text(field?.displayName ?? "Ignored")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(field == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: cellWidth - DS.Spacing.s, alignment: .leading)
                .padding(.trailing, DS.Spacing.s)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.s)
        .background(DS.Colors.cardFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ index: Int, cells: [String], review: ReviewRow?, mapping: CSVColumnMapping, output: CSVPipelineOutput) -> some View {
        HStack(spacing: 0) {
            Text(review.map { "\($0.line)" } ?? "")
                .font(.caption)
                .numeric()
                .foregroundStyle(.tertiary)
                .frame(width: lineWidth, alignment: .trailing)
                .padding(.trailing, DS.Spacing.s)
            HStack(spacing: DS.Spacing.xs) {
                if let review {
                    Image(systemName: review.status.symbol)
                        .foregroundStyle(review.status.color)
                        .imageScale(.small)
                        .accessibilityLabel(review.status.title)
                    Text(Self.reading(review, currency: output.quoteCurrency))
                        .foregroundStyle(review.status == .error ? AnyShapeStyle(DS.Colors.red) : AnyShapeStyle(.primary))
                        .help(review.message.isEmpty ? Self.reading(review, currency: output.quoteCurrency) : review.message)
                }
            }
            .numeric()
            .lineLimit(1)
            .frame(width: readingWidth - DS.Spacing.s, alignment: .leading)
            .padding(.trailing, DS.Spacing.s)
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                Text(cell)
                    .numeric()
                    .lineLimit(1)
                    .foregroundStyle(column < mapping.columns.count && mapping.columns[column] != nil ? .primary : .tertiary)
                    .frame(width: cellWidth - DS.Spacing.s, alignment: .leading)
                    .padding(.trailing, DS.Spacing.s)
            }
        }
        .font(.callout)
        .frame(height: rowHeight)
        .padding(.horizontal, DS.Spacing.s)
        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
    }

    /// "Jan 7, 2019 · Buy · €2,946.83" — or the reason a row cannot be read.
    static func reading(_ row: ReviewRow, currency: CurrencyCode?) -> String {
        if row.status == .error { return row.message.isEmpty ? "Cannot be read" : row.message }
        var parts: [String] = []
        if let day = row.day { parts.append(Fmt.day(day, style: .medium)) }
        if let amount = row.amount {
            parts.append(row.kind)
            parts.append(Fmt.money(amount))
        } else if let price = row.price {
            parts.append(Fmt.price(price, currency: currency))
        } else if !row.security.isEmpty {
            parts.append(row.security)
        }
        return parts.isEmpty ? row.status.title : parts.joined(separator: " · ")
    }
}

// MARK: - Result

private struct CSVDoneStep: View {
    @Bindable var wizard: CSVWizard
    var chooseAnother: () -> Void
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            if let outcome = wizard.outcome {
                Image(systemName: outcome.imported > 0 ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(outcome.imported > 0 ? AnyShapeStyle(DS.Colors.green) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(spacing: DS.Spacing.xs) {
                    Text(outcome.imported > 0
                        ? "Imported \(Fmt.integer(outcome.imported)) \(outcome.target.noun(outcome.imported).capitalized)"
                        : "Nothing Was Imported")
                        .font(.title2.weight(.semibold))
                        .numeric()
                    Text(details(outcome))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .numeric()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.imported > 0 {
                    Label("One step: Edit ▸ Undo \(outcome.target.actionName) (⌘Z) takes all of it back. The layout is remembered for the next file like this.", systemImage: "arrow.uturn.backward.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DS.Spacing.s) {
                    Button("Import Another File…", action: chooseAnother)
                    if let route = outcome.route, outcome.imported > 0 {
                        Button("Show Imported") {
                            store.dismissSheet()
                            store.navigate(to: route)
                        }
                        .help(outcome.target == .transactions
                            ? "Opens Transactions at the first imported entry. Filter by “\(outcome.sourceTag)” to see all of them."
                            : "Opens the security")
                    }
                    Button("Done") { store.dismissSheet() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, DS.Spacing.s)
            }
        }
        .padding(DS.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func details(_ outcome: CSVWizard.Outcome) -> String {
        var parts = ["From “\(wizard.fileName)”."]
        var created: [String] = []
        if outcome.target != .securities, outcome.newSecurities > 0 {
            created.append("\(Fmt.integer(outcome.newSecurities)) \(outcome.newSecurities == 1 ? "security" : "securities")")
        }
        if outcome.newAccounts > 0 { created.append("\(Fmt.integer(outcome.newAccounts)) cash \(outcome.newAccounts == 1 ? "account" : "accounts")") }
        if outcome.newDepots > 0 { created.append("\(Fmt.integer(outcome.newDepots)) \(outcome.newDepots == 1 ? "depot" : "depots")") }
        if !created.isEmpty { parts.append("Created " + created.formatted(.list(type: .and)) + ".") }
        if outcome.skipped > 0 { parts.append("\(Fmt.integer(outcome.skipped)) \(outcome.skipped == 1 ? "row was" : "rows were") left out.") }
        return parts.joined(separator: " ")
    }
}
