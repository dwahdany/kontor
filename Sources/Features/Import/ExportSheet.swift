import SwiftUI
import KontorInterchange
import KontorUI

/// The sheet behind `SheetRequest.export`: pick what to write (transactions, holdings, quotes or
/// securities as CSV, a Portfolio Performance XML, or a readable Kontor JSON copy), set the CSV
/// notation, see the first lines, then save.
///
/// Launch state (screenshots): `format=transactions|holdings|quotes|securities|pp|json`,
/// `preset=international|german`.
struct ExportSheet: View {
    let request: ExportRequest
    var initialFormat: ExportFormat?

    @Environment(PortfolioStore.self) private var store
    @State private var options = ExportOptions()
    @State private var result = Loadable<ExportResult>()
    @State private var isSaving = false
    @State private var isConfigured = false

    /// Everything the preview depends on.
    private struct Query: Hashable {
        var options: ExportOptions
        var revision: Int
        var scope: Scope
        var interval: DayInterval
        var isConfigured: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(symbol: "square.and.arrow.up", title: "Export", subtitle: store.file.name.isEmpty ? "This portfolio" : store.file.name)
            Divider()
            HStack(spacing: 0) {
                formatList
                    .frame(width: 250)
                Divider()
                detail
            }
            .frame(height: 430)
            Divider()
            footer
        }
        .frame(width: 800)
        .onAppear(perform: configure)
        .task(id: Query(options: options, revision: store.revision, scope: store.scope, interval: store.periodInterval, isConfigured: isConfigured)) {
            guard isConfigured else { return }
            await refresh()
        }
    }

    private func configure() {
        guard !isConfigured else { return }
        var value = ExportOptions()
        value.format = store.launchValue("format", as: ExportFormat.self) ?? initialFormat ?? ExportFormat(request.content)
        switch request.content {
        case .transactions(let only):
            value.transactionIDs = only.flatMap { $0.isEmpty ? nil : $0 }
        case .quotes(let securityID):
            value.securityID = securityID
        case .portfolio, .securities:
            break
        }
        if value.securityID == nil {
            value.securityID = store.route.securityID ?? store.file.securities.first { !$0.prices.isEmpty }?.id
        }
        let preset = store.launchValue("preset", as: CSVPreset.self)
            ?? UserDefaults.standard.string(forKey: Self.presetKey).flatMap(CSVPreset.init(rawValue:))
        if preset == .german { value.csv = .german }
        options = value
        isConfigured = true
    }

    private static let presetKey = "export.csv.preset"

    // MARK: Formats

    private var formatList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            sectionTitle("Spreadsheet (CSV)")
            ForEach(ExportFormat.allCases.filter(\.isCSV)) { formatRow($0) }
            sectionTitle("Whole portfolio").padding(.top, DS.Spacing.s)
            ForEach(ExportFormat.allCases.filter { !$0.isCSV }) { formatRow($0) }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.kontorCaption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
    }

    private func formatRow(_ format: ExportFormat) -> some View {
        let isSelected = options.format == format
        return Button {
            options.format = format
        } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: format.symbol)
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.title).fontWeight(.medium)
                    Text(format.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs + 1)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Options + preview

    private var detail: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(headline).font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            optionsGrid
            preview
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headline: String {
        switch options.format {
        case .transactions: "Transactions as CSV"
        case .holdings: "Holdings as CSV"
        case .quotes: "Quotes as CSV"
        case .securities: "Securities as CSV"
        case .portfolioPerformance: "Portfolio Performance XML"
        case .json: "Kontor JSON"
        }
    }

    private var explanation: String {
        switch options.format {
        case .transactions:
            "One row per transaction, in date order, with the column titles Portfolio Performance uses — the file imports again here and there."
        case .holdings:
            "Positions and cash balances of \(store.isWholePortfolioScope ? "the whole portfolio" : store.scopeTitle) on \(Fmt.day(store.periodInterval.end, style: .medium)), valued in \(store.baseCurrency)."
        case .quotes:
            "The stored price history of one security: date and quote."
        case .securities:
            "Name, ISIN, WKN, ticker, currency and note of every security."
        case .portfolioPerformance:
            "Compatible export — best effort. Securities with quotes, accounts, all transactions, taxonomies, watchlists and savings plans open in Portfolio Performance (2022 or newer). Kontor-only settings travel along invisibly."
        case .json:
            "A complete copy in Kontor's open file format — readable, diff-able and easy to process with other tools. Kontor opens it like any portfolio."
        }
    }

    @ViewBuilder private var optionsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
            switch options.format {
            case .transactions:
                if let ids = options.transactionIDs {
                    GridRow {
                        label("Rows")
                        Picker("Rows", selection: $options.onlySelection) {
                            Text("Selected (\(Fmt.integer(ids.count)))").tag(true)
                            Text("All (\(Fmt.integer(store.file.transactions.count)))").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            case .quotes:
                GridRow {
                    label("Security")
                    SecurityPicker(selection: $options.securityID, includesRetired: true)
                        .frame(maxWidth: 300, alignment: .leading)
                }
            case .json:
                GridRow {
                    label("Layout")
                    Toggle("Pretty-printed (indented, one value per line)", isOn: $options.prettyJSON)
                }
            case .holdings, .securities, .portfolioPerformance:
                EmptyView()
            }
            if options.format.isCSV {
                GridRow {
                    label("Notation")
                    Picker("Notation", selection: presetBinding) {
                        ForEach(CSVPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("Delimiter")
                    HStack(spacing: DS.Spacing.l) {
                        Picker("Delimiter", selection: $options.csv.delimiter) {
                            Text("Comma  ,").tag(Character(","))
                            Text("Semicolon  ;").tag(Character(";"))
                            Text("Tab").tag(Character("\t"))
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Picker("Numbers", selection: $options.csv.decimalSeparator) {
                            Text("1234.56").tag(Character("."))
                            Text("1234,56").tag(Character(","))
                        }
                        .frame(width: 170)
                    }
                }
                GridRow {
                    label("Dates")
                    HStack(spacing: DS.Spacing.l) {
                        Picker("Dates", selection: $options.csv.dateStyle) {
                            Text("2024-03-31").tag(CSVExportFormat.DateStyle.iso)
                            Text("31.03.2024").tag(CSVExportFormat.DateStyle.dayMonthYearDots)
                            Text("03/31/2024").tag(CSVExportFormat.DateStyle.monthDayYearSlashes)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Picker("Titles", selection: $options.csv.language) {
                            Text("English").tag(CSVExportFormat.Language.english)
                            Text("German").tag(CSVExportFormat.Language.german)
                        }
                        .frame(width: 170)
                    }
                }
                GridRow {
                    label("Excel")
                    Toggle("Add a byte-order mark so Excel recognizes UTF-8", isOn: $options.csv.includeByteOrderMark)
                }
            }
        }
        .numeric()
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var presetBinding: Binding<CSVPreset> {
        Binding(
            get: { CSVPreset(options.csv) },
            set: { preset in
                let mark = options.csv.includeByteOrderMark
                switch preset {
                case .international: options.csv = .international
                case .german: options.csv = .german
                case .custom: return
                }
                options.csv.includeByteOrderMark = mark
            })
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview")
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
            }
            Group {
                if let problem = result.value?.problem {
                    Text(problem)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let lines = result.value?.previewLines, !lines.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(lines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineSpacing(2)
                            .fixedSize()
                            .padding(DS.Spacing.s)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else if result.isLoading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(contentSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .numeric()
                        .padding(DS.Spacing.m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.hairline))
            .opacity(result.isRefreshing ? 0.6 : 1)
            if let warnings = result.value?.warnings, !warnings.isEmpty {
                Label {
                    Text("\(Fmt.integer(warnings.reduce(0) { $0 + $1.count })) details cannot be represented in Portfolio Performance: \(warnings[0].message)")
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                }
                .font(.caption)
                .help(warnings.map(\.description).joined(separator: "\n"))
            }
        }
    }

    private var sizeText: String {
        guard let value = result.value, value.problem == nil else { return "" }
        var parts: [String] = []
        if let rows = value.rowCount { parts.append("\(Fmt.integer(rows)) \(rows == 1 ? "row" : "rows")") }
        if let data = value.data { parts.append(ByteText.string(data.count)) }
        return parts.joined(separator: " · ")
    }

    /// Shown instead of the first lines when the document is too large to serialise just for a preview.
    private var contentSummary: String {
        let file = store.file
        let quotes = file.securities.reduce(0) { $0 + $1.prices.count }
        return "\(Fmt.integer(file.securities.count)) securities with \(Fmt.integer(quotes)) quotes and "
            + "\(Fmt.integer(file.transactions.count)) transactions.\nToo large for a preview — the file is written when you save."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Spacing.m) {
            Text("The portfolio itself is not changed by exporting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || result.value?.problem != nil || (options.format == .quotes && options.securityID == nil))
        }
        .padding(DS.Spacing.l)
    }

    // MARK: Work

    private func refresh() async {
        let options = options
        let file = store.file
        if !options.format.isCSV, ExportBuilder.isHeavy(file) {
            // Too large to serialise for a preview: describe it, write on save.
            result = Loadable(ExportResult(data: nil, previewLines: []))
            return
        }
        result.isLoading = true
        let built = await build(options, file: file)
        guard !Task.isCancelled else { return }
        if let built { result = Loadable(built) }
        result.isLoading = false
    }

    private func build(_ options: ExportOptions, file: PortfolioFile) async -> ExportResult? {
        var holdings: HoldingsExport?
        if options.format == .holdings {
            holdings = try? await store.analyze("import.export.holdings") { analysis in HoldingsExport(analysis) }
            if holdings == nil { return nil }
        }
        let snapshot = holdings
        return await store.whileBusy { await Background.run { ExportBuilder.build(options, file: file, holdings: snapshot) } }
    }

    private func save() {
        let options = options
        let file = store.file
        if options.format.isCSV { UserDefaults.standard.set(CSVPreset(options.csv).rawValue, forKey: Self.presetKey) }
        guard let url = ImportPanels.chooseDestination(
            fileName: ExportBuilder.fileName(options, file: file, today: store.today), type: options.format.contentType,
            message: "Export \(headline)") else { return }
        isSaving = true
        Task {
            var data = result.value?.data
            if data == nil { data = await build(options, file: file)?.data }
            let payload = data
            let failure: String? = await store.whileBusy {
                await Background.run {
                    guard let payload else { return "There was nothing to export." }
                    do {
                        try payload.write(to: url, options: .atomic)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            isSaving = false
            if let failure {
                store.show(Toast("Export failed", message: failure, style: .error, duration: 6))
            } else {
                store.dismissSheet()
                store.toast("Exported “\(url.lastPathComponent)”", message: sizeText.isEmpty ? nil : sizeText, style: .success)
            }
        }
    }
}
