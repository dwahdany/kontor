import SwiftUI
import KontorUI

/// The transaction editor: one compact sheet for all fifteen kinds, shown for every
/// `.newTransaction` / `.editTransaction` request of the app.
///
/// Launch state (screenshots; applied once when the sheet opens, on top of the request's prefill):
/// `kind=<Transaction.Kind>` · `security=<name prefix>` · `account=<name>` · `depot=<name>` ·
/// `to=<name of the target account or depot>` · `date=YYYY-MM-DD` · `time=HH:MM` · `shares=` ·
/// `price=` · `gross=` · `total=` · `fees=` · `taxes=` · `rate=` (numbers in any format, applied in
/// that order as if typed) · `picker=kind|security` (open that list) · `validate=on` (show what is
/// missing as after a save attempt).
///
/// Keyboard: Tab walks date → security → depot → account → numbers → note; the choosers open with
/// Space, ↓ or by typing a name; ⌃K opens the type list and ⌃B/S/D/P/W/I/F/X/C/T/L/O pick a type
/// directly; ⌘↩ saves, ⇧⌘↩ saves and starts the next entry, Esc cancels.
struct TransactionEditor: View {
    enum Mode: Hashable {
        case new(TransactionPrefill)
        case edit(UUID)
    }

    @Environment(PortfolioStore.self) private var store
    let mode: Mode

    @State private var ledger: Ledger?
    @State private var initial: TransactionDraft?
    @State private var isMissing = false

    /// The request (or a screenshot state) named the account / depot: habits must not override it.
    private var keepsAccount: Bool {
        if case .new(let prefill) = mode { return prefill.accountID != nil || store.launchValue("account") != nil }
        return true
    }
    private var keepsDepot: Bool {
        if case .new(let prefill) = mode { return prefill.depotID != nil || store.launchValue("depot") != nil }
        return true
    }

    var body: some View {
        Group {
            if let ledger, let initial {
                EditorForm(draft: initial, ledger: ledger, keepsAccount: keepsAccount, keepsDepot: keepsDepot)
            } else if isMissing {
                EmptyState("Transaction Not Found", symbol: "questionmark.circle", message: "It was deleted in the meantime.") {
                    Button("Close") { store.dismissSheet() }.keyboardShortcut(.defaultAction)
                }
                .frame(height: 260)
            } else {
                ProgressView().frame(height: 420)
            }
        }
        .frame(width: 580)
        .task(id: store.revision) {
            // The ledger is the document index the draft resolves currencies, quotes and rates
            // against; it is built off the main actor and shared with the screens.
            let ledger = await store.ledgerOffMain()
            self.ledger = ledger
            guard initial == nil else { return }
            switch mode {
            case .new(let prefill):
                let prefill = Self.applyingLaunchKind(prefill, store: store)
                let kind = prefill.kind ?? .buy
                // "Last used": where the latest entry of this kind was booked, else the latest entry at all.
                let entries = store.file.transactions
                var draft = TransactionDraft(
                    prefill: prefill, ledger: ledger, today: store.today,
                    lastUsedDepot: (entries.last { $0.kind == kind && $0.depotID != nil } ?? entries.last { $0.depotID != nil })?.depotID,
                    lastUsedAccount: (entries.last { $0.kind == kind && $0.accountID != nil } ?? entries.last { $0.accountID != nil })?.accountID)
                Self.applyHabits(to: &draft, store: store, ledger: ledger, keepsAccount: keepsAccount, keepsDepot: keepsDepot)
                Self.applyLaunchState(to: &draft, store: store, ledger: ledger, keepsAccount: keepsAccount, keepsDepot: keepsDepot)
                initial = draft
            case .edit(let id):
                if let transaction = store.transaction(id) {
                    var draft = TransactionDraft(editing: transaction, ledger: ledger)
                    Self.applyLaunchState(to: &draft, store: store, ledger: ledger, keepsAccount: true, keepsDepot: true)
                    initial = draft
                } else {
                    isMissing = true
                }
            }
        }
    }

    /// People book a security the same way every time: the depot and the account it was booked on
    /// last (for this kind of entry) are better defaults than the globally last-used ones.
    static func habits(for securityID: UUID, kind: Transaction.Kind, store: PortfolioStore) -> (depot: UUID?, account: UUID?) {
        let history = store.transactions(forSecurity: securityID)
        var depot: UUID?
        var account: UUID?
        if kind.requiresDepot {
            depot = history.last { $0.depotID != nil }?.depotID
            if store.depot(depot)?.isRetired != false { depot = nil }
        }
        if kind.requiresAccount {
            // Dividends usually arrive where the last dividend arrived; trades where the last trade settled.
            account = (history.last { $0.kind == kind && $0.accountID != nil } ?? history.last { $0.accountID != nil })?.accountID
            if store.account(account)?.isRetired != false { account = nil }
            if account == nil, let reference = store.depot(depot)?.referenceAccountID, store.account(reference) != nil { account = reference }
        }
        return (depot, account)
    }

    private static func applyHabits(to draft: inout TransactionDraft, store: PortfolioStore, ledger: Ledger, keepsAccount: Bool, keepsDepot: Bool) {
        guard draft.isNew, let securityID = draft.securityID else { return }
        let habits = habits(for: securityID, kind: draft.kind, store: store)
        if !keepsDepot, let depot = habits.depot { draft.depotID = depot }
        if !keepsAccount, let account = habits.account, account != draft.accountID {
            draft.accountID = account
            draft.resolve(ledger, changed: [.account])
        }
    }

    private static func applyingLaunchKind(_ prefill: TransactionPrefill, store: PortfolioStore) -> TransactionPrefill {
        var prefill = prefill
        if let kind = store.launchValue("kind", as: Transaction.Kind.self) { prefill.kind = kind }
        if let date = store.launchValue("date").flatMap({ Day(iso: $0) }) { prefill.date = date }
        return prefill
    }

    /// `--state` keys that fill the form the way a user would, so every variant can be rendered.
    private static func applyLaunchState(to draft: inout TransactionDraft, store: PortfolioStore, ledger: Ledger, keepsAccount: Bool, keepsDepot: Bool) {
        guard !store.launchState.isEmpty else { return }
        func match<E>(_ items: [E], _ key: String, name: (E) -> String) -> E? {
            guard let wanted = store.launchValue(key)?.lowercased(), !wanted.isEmpty else { return nil }
            return items.first { name($0).lowercased() == wanted } ?? items.first { name($0).lowercased().hasPrefix(wanted) }
                ?? items.first { name($0).lowercased().contains(wanted) }
        }
        if let kind = store.launchValue("kind", as: Transaction.Kind.self), kind != draft.kind {
            draft.setKind(kind)
            draft.resolve(ledger, changed: [.kind])
        }
        if let date = store.launchValue("date").flatMap({ Day(iso: $0) }), date != draft.date {
            draft.date = date
            draft.resolve(ledger, changed: [.date])
        }
        if let depot = match(ledger.depots, "depot", name: \.name) {
            draft.depotID = depot.id
            draft.resolve(ledger, changed: [.depot])
        }
        if let account = match(ledger.accounts, "account", name: \.name) {
            draft.accountID = account.id
            draft.resolve(ledger, changed: [.account])
        }
        if draft.kind == .cashTransfer, let account = match(ledger.accounts, "to", name: \.name) {
            draft.counterAccountID = account.id
            draft.resolve(ledger, changed: [.counterAccount])
        }
        if draft.kind == .securityTransfer, let depot = match(ledger.depots, "to", name: \.name) { draft.counterDepotID = depot.id }
        if let security = match(ledger.securities, "security", name: \.name) {
            draft.securityID = security.id
            draft.resolve(ledger, changed: [.security])
            applyHabits(to: &draft, store: store, ledger: ledger, keepsAccount: keepsAccount, keepsDepot: keepsDepot)
        }
        if let time = store.launchValue("time")?.split(separator: ":").compactMap({ Int($0) }), time.count == 2 {
            draft.minuteOfDay = min(max(time[0], 0), 23) * 60 + min(max(time[1], 0), 59)
        }
        let numbers: [(String, TransactionDraft.Field, Int)] = [
            ("shares", .shares, 8), ("price", .price, 8), ("fees", .fees, 2), ("taxes", .taxes, 2), ("gross", .gross, 2), ("total", .total, 2),
        ]
        for (key, field, digits) in numbers {
            if let value = store.launchValue(key).flatMap({ Arithmetic.evaluate($0, scaleDigits: digits) }) { draft.edit(field, value) }
        }
        if let rate = store.launchValue("rate").flatMap({ Fmt.parseDouble($0) }) { draft.editRate(rate) }
    }
}

/// The form itself, once the draft exists.
private struct EditorForm: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle

    @State var draft: TransactionDraft
    let ledger: Ledger
    /// True once the account / depot was chosen deliberately (by the request or by the user).
    @State var keepsAccount: Bool
    @State var keepsDepot: Bool

    @State private var context = PositionContext()
    @State private var isKindPickerOpen = false
    @State private var showsAllIssues = false
    @State private var addedCount = 0
    @State private var opensSecurityList = false
    @FocusState private var focus: EditorFocus?

    private let labelWidth: CGFloat = 96
    private let fieldWidth: CGFloat = 148

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                parties
                amounts
                noteRow
                feedback
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.l)
            Divider()
            footer
        }
        .background { kindShortcuts }
        .onAppear(perform: start)
        .onChange(of: draft.securityID) { _, id in
            followHabits(for: id)
            draft.resolve(ledger, changed: [.security])
        }
        .onChange(of: draft.accountID) { _, _ in draft.resolve(ledger, changed: [.account]) }
        .onChange(of: draft.counterAccountID) { _, _ in draft.resolve(ledger, changed: [.counterAccount]) }
        .onChange(of: draft.date) { _, _ in draft.resolve(ledger, changed: [.date]) }
        .task(id: contextKey) { await loadContext() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            KindPicker(kind: draft.kind, focus: $focus, isOpen: $isKindPickerOpen) { setKind($0) }
            Text(draft.kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let helpTopic { HelpButton(helpTopic) }
            Spacer(minLength: DS.Spacing.s)
            Text(draft.isNew ? "New Transaction" : "Edit Transaction")
                .font(.callout.weight(.medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.m)
    }

    /// ⌃K opens the kind list, ⌃B / ⌃S / ⌃D … pick a kind directly.
    private var kindShortcuts: some View {
        ZStack {
            Button("Choose Type") { isKindPickerOpen = true }
                .keyboardShortcut("k", modifiers: .control)
            ForEach(Transaction.Kind.allCases, id: \.self) { kind in
                if let key = kind.shortcutKey {
                    Button(kind.title) { setKind(kind) }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .control)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var helpTopic: HelpTopic? {
        switch draft.kind {
        case .deliveryIn, .deliveryOut: .delivery
        case .securityTransfer: .securityTransfer
        case .dividend, .interest: .grossVersusNet
        default: nil
        }
    }

    // MARK: Who and when

    private var parties: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
            GridRow {
                label("Date")
                HStack(spacing: DS.Spacing.s) {
                    DayField("Date", day: $draft.date)
                    timeControl
                    Spacer(minLength: 0)
                    if draft.date != store.today {
                        Button("Today") { draft.date = store.today }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
            if draft.showsSecurity {
                GridRow {
                    label("Security")
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        ComboField(
                            title: "Security", selection: $draft.securityID, items: securityItems,
                            placeholder: draft.needsSecurity ? "Choose Security…" : "None (optional)",
                            allowsNone: !draft.needsSecurity, isInvalid: isFlagged(.security), focus: $focus, target: .security,
                            startsOpen: opensSecurityList)
                        if let caption = quoteCaption {
                            Text(caption).font(.caption).foregroundStyle(.secondary).numeric()
                        }
                    }
                }
            }
            if draft.kind.requiresDepot {
                GridRow {
                    label(draft.kind == .securityTransfer ? "From Depot" : "Depot")
                    ComboField(
                        title: "Depot", selection: depotChoice, items: depotItems(selected: draft.depotID), placeholder: "Choose Depot…",
                        isInvalid: isFlagged(.depot), focus: $focus, target: .depot)
                }
            }
            if draft.kind == .securityTransfer {
                GridRow {
                    label("To Depot")
                    ComboField(
                        title: "Target Depot", selection: $draft.counterDepotID, items: depotItems(selected: draft.counterDepotID),
                        placeholder: "Choose Depot…", isInvalid: isFlagged(.counterDepot), focus: $focus, target: .counterDepot)
                }
            }
            if draft.kind.requiresAccount {
                GridRow {
                    label(draft.kind == .cashTransfer ? "From Account" : "Account")
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        ComboField(
                            title: "Account", selection: accountChoice, items: accountItems(selected: draft.accountID),
                            placeholder: "Choose Account…", isInvalid: isFlagged(.account), focus: $focus, target: .account)
                        if let counterpart = draft.kind.deliveryCounterpart {
                            Button("No cash involved? Record as \(counterpart.title)") { setKind(counterpart) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            } else if let counterpart = draft.kind.deliveryCounterpart {
                GridRow {
                    label("Account")
                    HStack(spacing: DS.Spacing.xs) {
                        Text("No cash is moved.").foregroundStyle(.secondary)
                        Button("Settle against an account (\(counterpart.title))") { setKind(counterpart) }
                            .buttonStyle(.link)
                        HelpButton(.delivery)
                    }
                    .font(.callout)
                }
            }
            if draft.kind == .dividend {
                GridRow {
                    label("Ex-Date")
                    HStack(spacing: DS.Spacing.s) {
                        DayField("Ex-Date", day: $draft.exDate, placeholder: "Not Set")
                        HelpButton(.exDate)
                    }
                }
            }
            if draft.kind == .cashTransfer {
                GridRow {
                    label("To Account")
                    ComboField(
                        title: "Target Account", selection: $draft.counterAccountID, items: accountItems(selected: draft.counterAccountID),
                        placeholder: "Choose Account…", isInvalid: isFlagged(.counterAccount), focus: $focus, target: .counterAccount)
                }
            }
        }
    }

    @ViewBuilder private var timeControl: some View {
        if draft.minuteOfDay != nil {
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .numeric()
                .fixedSize()
            Button {
                draft.minuteOfDay = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove the time")
            .accessibilityLabel("Remove time")
        } else {
            Button("Add Time") { draft.minuteOfDay = 9 * 60 }
                .buttonStyle(.link)
                .font(.callout)
                .help("Give the entry a time of day — it orders several transactions of the same day.")
        }
    }

    private var timeBinding: Binding<Date> {
        let midnight = draft.date.date(in: .current)
        return Binding(
            get: { midnight.addingTimeInterval(Double(draft.minuteOfDay ?? 0) * 60) },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                draft.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    // MARK: Numbers

    private var amounts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
            let currency = draft.currency
            let securityCurrency = draft.securityCurrency ?? currency
            if draft.kind.usesPrice {
                number("Shares", .shares, draft.shares, digits: 8, calculated: draft.calculated == .shares) { Fmt.shares(Shares(raw: $0)) }
                number("Price", .price, draft.price, digits: 8, operation: "×", unit: securityCurrency,
                       calculated: draft.calculated == .price, hint: priceHint) { Fmt.price(Price(raw: $0)) }
            } else if draft.kind == .dividend {
                number("Shares", .shares, draft.shares, digits: 8, hint: dividendSharesHint) { Fmt.shares(Shares(raw: $0)) }
            }
            if draft.isForeign {
                money(draft.kind == .dividend ? "Gross" : "Value", .securityGross, draft.securityGross, operation: draft.kind.usesPrice ? "=" : nil,
                      unit: securityCurrency, calculated: draft.calculated == .amount)
                GridRow {
                    label("Rate", operation: "×")
                    HStack(spacing: DS.Spacing.s) {
                        CalcField(
                            title: "Exchange rate", value: FixedMath.saturatingInt64(draft.rate * 1e8), scaleDigits: 8,
                            format: { Fmt.number(Double($0) / 1e8, decimals: 4) }, isCalculated: !draft.ratePinned,
                            focus: $focus, target: .rate
                        ) { draft.editRate(Double($0) / 1e8) }
                        .frame(width: fieldWidth)
                        Text("\(currency) per \(securityCurrency)").foregroundStyle(.secondary).fixedSize()
                        HelpButton(.exchangeRates)
                        hintText(draft.rateMissing && !draft.ratePinned ? "no rate on file" : draft.ratePinned ? "from the amounts" : "rate of that day")
                    }
                }
            }
            if draft.kind.chargeSign != 0 {
                money(draft.isForeign ? "In \(currency)" : "Gross", .gross, draft.gross,
                      operation: draft.kind.usesPrice || draft.isForeign ? "=" : nil, unit: currency,
                      calculated: draft.kind.usesPrice && !draft.isForeign && draft.calculated == .amount,
                      hint: draft.kind == .dividend || draft.kind == .interest ? "before taxes and fees" : nil)
                if draft.showsFees {
                    money("Fees", .fees, draft.fees, operation: draft.kind.chargeSign > 0 ? "+" : "−", unit: currency)
                }
                if draft.showsTaxes {
                    money("Taxes", .taxes, draft.taxes, operation: draft.kind.chargeSign > 0 ? "+" : "−", unit: currency)
                }
                money(totalTitle, .total, draft.total, operation: "=", unit: currency, emphasized: true, hint: totalHint)
            } else {
                money(draft.kind == .securityTransfer ? "Value" : "Amount", .total, draft.total,
                      operation: draft.kind.usesPrice && !draft.isForeign ? "=" : nil, unit: currency, emphasized: true,
                      calculated: draft.kind.usesPrice && draft.calculated == .amount,
                      hint: draft.kind == .securityTransfer ? "for your records — no cash moves" : nil)
            }
            if draft.isCrossCurrencyTransfer, let counterCurrency = draft.counterCurrency {
                GridRow {
                    label("Rate", operation: "×")
                    HStack(spacing: DS.Spacing.s) {
                        CalcField(
                            title: "Exchange rate", value: FixedMath.saturatingInt64(draft.counterRate * 1e8), scaleDigits: 8,
                            format: { Fmt.number(Double($0) / 1e8, decimals: 4) }, isCalculated: !draft.counterRatePinned,
                            focus: $focus, target: .counterRate
                        ) { draft.editCounterRate(Double($0) / 1e8) }
                        .frame(width: fieldWidth)
                        Text("\(counterCurrency) per \(currency)").foregroundStyle(.secondary).fixedSize()
                        HelpButton(.exchangeRates)
                        hintText(draft.counterRateMissing && !draft.counterRatePinned ? "no rate on file" : draft.counterRatePinned ? "from the amounts" : "rate of that day")
                    }
                }
                money("Arrives", .counterAmount, draft.counterAmount, operation: "=", unit: counterCurrency, emphasized: true)
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .padding(.horizontal, -DS.Spacing.m)
    }

    private var totalTitle: String {
        switch draft.kind {
        case .buy: "Total"
        case .sell: "Proceeds"
        case .dividend, .interest: "Net"
        case .deliveryIn: "Cost"
        case .deliveryOut: "Net Value"
        default: "Value"
        }
    }

    private var totalHint: String? {
        switch draft.kind {
        case .buy: "leaves the account"
        case .sell, .dividend, .interest: "arrives in the account"
        case .deliveryIn: "what the shares cost you"
        default: nil
        }
    }

    private var priceHint: String? {
        if draft.calculated == .price, draft.price != 0, !draft.priceIsQuote { return "calculated" }
        if draft.priceIsQuote, let day = draft.quoteDay {
            return day == draft.date ? "closing quote" : "quote of \(Fmt.day(day, style: .dayMonth))"
        }
        if draft.price == 0, draft.securityID != nil, draft.quote == nil { return "no quote on file" }
        return nil
    }

    private var dividendSharesHint: String? {
        guard draft.shares != 0, draft.gross != 0, let perShare = Price(minor: draft.isForeign && draft.securityGross != 0 ? draft.securityGross : draft.gross, per: Shares(raw: draft.shares)) else {
            return "optional"
        }
        let currency = draft.isForeign && draft.securityGross != 0 ? draft.securityCurrency : draft.currency
        return "\(Fmt.price(perShare, currency: currency)) per share"
    }

    private func number(
        _ title: String, _ field: TransactionDraft.Field, _ value: Int64, digits: Int, operation: String? = nil, unit: String? = nil,
        calculated: Bool = false, hint: String? = nil, format: @escaping (Int64) -> String
    ) -> some View {
        GridRow {
            label(title, operation: operation)
            HStack(spacing: DS.Spacing.s) {
                CalcField(
                    title: title, value: value, scaleDigits: digits, format: format, isCalculated: calculated,
                    focus: $focus, target: focusTarget(field)
                ) { draft.edit(field, $0) }
                .frame(width: fieldWidth)
                if let unit { Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading) }
                hintText(hint ?? (calculated && value != 0 ? "calculated" : nil))
            }
        }
    }

    private func money(
        _ title: String, _ field: TransactionDraft.Field, _ value: Int64, operation: String? = nil, unit: String,
        emphasized: Bool = false, calculated: Bool = false, hint: String? = nil
    ) -> some View {
        GridRow {
            label(title, operation: operation, emphasized: emphasized)
            HStack(spacing: DS.Spacing.s) {
                CalcField(
                    title: title, value: value, scaleDigits: 2, format: { Fmt.money(minor: $0) }, isCalculated: calculated,
                    isEmphasized: emphasized, focus: $focus, target: focusTarget(field)
                ) { draft.edit(field, $0) }
                .frame(width: fieldWidth)
                Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                hintText(hint ?? (calculated && value != 0 ? "calculated" : nil))
            }
        }
    }

    @ViewBuilder private func hintText(_ text: String?) -> some View {
        if let text {
            Text(text).font(.caption).foregroundStyle(.tertiary).numeric().lineLimit(1)
        }
    }

    private func focusTarget(_ field: TransactionDraft.Field) -> EditorFocus {
        switch field {
        case .shares: .shares
        case .price: .price
        case .securityGross: .securityGross
        case .gross: .gross
        case .fees: .fees
        case .taxes: .taxes
        case .total: .total
        case .counterAmount: .counterAmount
        }
    }

    private func label(_ title: String, operation: String? = nil, emphasized: Bool = false) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if let operation {
                Text(operation).foregroundStyle(.secondary).numeric().accessibilityHidden(true)
            }
            Text(title)
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
        .frame(width: labelWidth, alignment: .trailing)
        .gridColumnAlignment(.trailing)
    }

    // MARK: Note, messages, preview

    private var noteRow: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
            GridRow {
                label("Note")
                TextField("Note", text: $draft.note, prompt: Text("Optional"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .note)
            }
        }
    }

    private var issues: [EditorIssue] {
        draft.issues(
            context: context, today: store.today,
            names: .init(account: store.account(draft.accountID)?.name, depot: store.depot(draft.depotID)?.name))
    }

    private var visibleIssues: [EditorIssue] {
        issues.filter { $0.severity == .warning || showsAllIssues }
    }

    private func isFlagged(_ field: EditorIssue.Field) -> Bool {
        showsAllIssues && issues.contains { $0.severity == .error && $0.field == field }
    }

    @ViewBuilder private var feedback: some View {
        let visible = visibleIssues
        let preview = previewText
        if !visible.isEmpty || preview != nil || noAccountsHint != nil {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                ForEach(visible) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.red : DS.Colors.warning)
                            .imageScale(.small)
                            .accessibilityLabel(issue.severity == .error ? "Error" : "Warning")
                        Text(issue.message)
                            .font(.callout)
                            .numeric()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let hint = noAccountsHint {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
                        Text(hint.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button(hint.action) {
                            store.dismissSheet()
                            store.present(hint.request)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
                if let preview {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .numeric()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, labelWidth + DS.Spacing.m)
        }
    }

    /// Nothing to pick from yet: say so and offer the way out.
    private var noAccountsHint: (text: String, action: String, request: SheetRequest)? {
        if draft.kind.requiresAccount, store.file.accounts.isEmpty {
            return ("This portfolio has no cash account yet.", "New Account…", .newAccount)
        }
        if draft.kind.requiresDepot, store.file.depots.isEmpty {
            return ("This portfolio has no depot yet.", "New Depot…", .newDepot)
        }
        if draft.needsSecurity, store.file.securities.isEmpty {
            return ("This portfolio has no securities yet.", "New Security…", .newSecurity)
        }
        return nil
    }

    /// "After this, you hold 42.5 shares in Main Depot; Giro holds €1,203.11."
    private var previewText: String? {
        let outcome = draft.outcome(context: context)
        var clauses = [String]()
        if let shares = outcome.shares, let depot = store.depot(draft.depotID) {
            let text = "\(Fmt.shares(Shares(raw: shares))) \(shares == Scale.shares ? "share" : "shares")"
            if draft.kind == .securityTransfer, let target = store.depot(draft.counterDepotID), let targetShares = outcome.counterShares {
                clauses.append("\(depot.name) holds \(text) and \(target.name) \(Fmt.shares(Shares(raw: targetShares)))")
            } else {
                clauses.append("you hold \(text) in \(depot.name)")
            }
        }
        if let cash = outcome.cash, let account = store.account(draft.accountID) {
            var text = "\(account.name) holds \(Fmt.money(minor: cash, currency: account.currency))"
            if draft.kind == .cashTransfer, let target = store.account(draft.counterAccountID), let targetCash = outcome.counterCash {
                text += " and \(target.name) \(Fmt.money(minor: targetCash, currency: target.currency))"
            }
            clauses.append(text)
        }
        guard !clauses.isEmpty else { return nil }
        let day = draft.date == store.today ? "" : " (end of \(Fmt.day(draft.date, style: .medium)))"
        // Nothing entered yet: the same sentence describes where things stand.
        let changesNothing = draft.sharesDelta == 0 && draft.cashDelta == 0
        return "\(changesNothing ? "So far" : "After this"), \(clauses.joined(separator: "; "))\(day)."
    }

    private var quoteCaption: String? {
        guard draft.kind.usesPrice || draft.kind == .dividend, let security = store.security(draft.securityID) else { return nil }
        guard let quote = draft.quote, let day = draft.quoteDay else { return "No quotes on file for \(Fmt.day(draft.date, style: .medium)) or earlier." }
        return "Quote \(Fmt.price(Price(raw: quote), currency: security.currency)) · \(Fmt.day(day, style: .medium))"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            if let id = draft.original?.id {
                Button(role: .destructive) {
                    store.mutate("Delete \(draft.kind.title)") { file in file.transactions.removeAll { $0.id == id } }
                    store.dismissSheet()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this entry (you can undo it)")
            } else if addedCount > 0 {
                Label("\(Fmt.integer(addedCount)) added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .numeric()
            } else {
                Text("Number fields calculate: 3 × 120.5")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .numeric()
            }
            Spacer()
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            if draft.isNew {
                Button("Save & New") { save(andNew: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Save and start the next entry (⇧⌘↩)")
            }
            Button("Save") { save(andNew: false) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Save (⌘↩)")
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.m)
    }

    // MARK: Actions

    private func start() {
        showsAllIssues = store.launchValue("validate") == "on"
        switch store.launchValue("picker") {
        case "kind": isKindPickerOpen = true
        case "security": opensSecurityList = true
        default: break
        }
        guard store.launchValue("picker") == nil else { return }
        focusFirstField()
    }

    private func focusFirstField() {
        if draft.showsSecurity, draft.needsSecurity, draft.securityID == nil {
            focus = .security
        } else if draft.kind.usesPrice {
            focus = .shares
        } else if draft.kind.chargeSign != 0 {
            focus = .gross
        } else {
            focus = .total
        }
    }

    /// The depot picker: a deliberate choice, which also brings the depot's reference account along.
    private var depotChoice: Binding<UUID?> {
        Binding(get: { draft.depotID }, set: { id in
            draft.depotID = id
            keepsDepot = true
            if draft.isNew, !keepsAccount, let reference = store.depot(id)?.referenceAccountID, store.account(reference) != nil {
                draft.accountID = reference
            }
        })
    }

    private var accountChoice: Binding<UUID?> {
        Binding(get: { draft.accountID }, set: { id in
            draft.accountID = id
            keepsAccount = true
        })
    }

    private func followHabits(for securityID: UUID?) {
        guard draft.isNew, let securityID else { return }
        let habits = TransactionEditor.habits(for: securityID, kind: draft.kind, store: store)
        if !keepsDepot, let depot = habits.depot { draft.depotID = depot }
        if !keepsAccount, let account = habits.account { draft.accountID = account }
    }

    private func setKind(_ kind: Transaction.Kind) {
        guard kind != draft.kind else { return }
        draft.setKind(kind)
        draft.resolve(ledger, changed: [.kind])
        if focus == nil || focus == .kind { focusFirstField() }
    }

    private func save(andNew: Bool) {
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            showsAllIssues = true
            focus = errors.first.map(focusTarget(for:)) ?? focus
            NSSound.beep()
            return
        }
        let transaction = draft.makeTransaction()
        let isNew = draft.isNew
        store.mutate("\(isNew ? "Add" : "Edit") \(draft.kind.title)") { file in
            if let index = file.transactions.firstIndex(where: { $0.id == transaction.id }) {
                file.transactions[index] = transaction
            } else {
                file.transactions.append(transaction)
            }
        }
        if store.route.screen == .transactions { store.setFocus(.transaction(transaction.id)) }
        guard andNew else {
            store.dismissSheet()
            return
        }
        addedCount += 1
        showsAllIssues = false
        let finished = draft
        Task {
            // The next draft resolves against the document that now contains the saved entry.
            let ledger = await store.ledgerOffMain()
            draft = finished.next(ledger: ledger)
            focusFirstField()
        }
    }

    private func focusTarget(for issue: EditorIssue) -> EditorFocus {
        switch issue.field {
        case .date: .note
        case .security: .security
        case .depot: .depot
        case .account: .account
        case .counterAccount: .counterAccount
        case .counterDepot: .counterDepot
        case .shares: .shares
        case .price: .price
        case .amount: draft.kind.chargeSign != 0 ? .total : .total
        case .charges: .fees
        case .counterAmount: .counterAmount
        }
    }

    // MARK: Engine context

    private struct ContextKey: Hashable, Sendable {
        var revision: Int
        var day: Day
        var securityID: UUID?
        var depotID: UUID?
        var counterDepotID: UUID?
        var accountID: UUID?
        var counterAccountID: UUID?
        var original: UUID?
    }

    private var contextKey: ContextKey {
        ContextKey(
            revision: store.revision, day: draft.date,
            securityID: draft.kind.sharesSign != 0 || draft.kind == .dividend ? draft.securityID : nil,
            depotID: draft.kind.requiresDepot ? draft.depotID : nil,
            counterDepotID: draft.kind == .securityTransfer ? draft.counterDepotID : nil,
            accountID: draft.kind.requiresAccount ? draft.accountID : nil,
            counterAccountID: draft.kind == .cashTransfer ? draft.counterAccountID : nil,
            original: draft.original?.id)
    }

    /// Holdings and balances on the entry's day come from the engine's snapshot, off the main actor.
    private func loadContext() async {
        let key = contextKey
        let original = draft.original
        let result = try? await store.compute(key) { ledger in
            PositionContext(
                ledger: ledger, day: key.day, securityID: key.securityID, depotID: key.depotID, counterDepotID: key.counterDepotID,
                accountID: key.accountID, counterAccountID: key.counterAccountID, excluding: original)
        }
        guard let result, !Task.isCancelled else { return }
        context = result
        // A dividend is paid on what was held: offer that share count unless one was entered.
        if draft.kind == .dividend, draft.isNew, !draft.pinned.contains(.shares), let held = result.sharesHeld {
            draft.shares = max(0, held)
        }
    }

    // MARK: Picker items

    private var securityItems: [PickerItem<UUID>] {
        store.file.securities
            .filter { !$0.isRetired || $0.id == draft.securityID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.ticker.isEmpty ? $0.isin : $0.ticker, keywords: [$0.isin, $0.wkn, $0.ticker, $0.currency]) }
    }

    private func accountItems(selected: UUID?) -> [PickerItem<UUID>] {
        store.file.accounts
            .filter { !$0.isRetired || $0.id == selected }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.currency) }
    }

    private func depotItems(selected: UUID?) -> [PickerItem<UUID>] {
        store.file.depots
            .filter { !$0.isRetired || $0.id == selected }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { PickerItem(id: $0.id, title: $0.name) }
    }
}
