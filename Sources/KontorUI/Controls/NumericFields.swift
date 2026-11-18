import SwiftUI
import KontorModel

/// A text field editing a fixed-point number. While focused the user types freely (either decimal
/// separator, grouping, currency symbols are tolerated); on commit or blur the text is parsed and
/// re-rendered canonically. Invalid input is marked and the bound value left untouched.
struct FixedPointField: View {
    let title: String
    @Binding var value: Int64
    let scaleDigits: Int
    let format: (Int64) -> String
    var suffix: String?
    var allowsNegative = false
    var showsZeroAsEmpty = true

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .numeric()
                .focused($isFocused)
                .onSubmit(commit)
                .accessibilityLabel(title)
            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) {
            if isInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
                    .offset(x: 16)
                    .help("Not a valid number")
                    .accessibilityLabel("Invalid number")
            }
        }
        .onAppear { text = display(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused || parse(text) != newValue { text = display(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: text) { _, newText in
            // Live-update the binding while typing so dependent fields (totals) follow.
            guard isFocused else { return }
            if newText.trimmingCharacters(in: .whitespaces).isEmpty {
                isInvalid = false
                if value != 0 { value = 0 }
            } else if let parsed = parse(newText) {
                isInvalid = false
                if parsed != value { value = parsed }
            } else {
                isInvalid = true
            }
        }
    }

    private func display(_ v: Int64) -> String { v == 0 && showsZeroAsEmpty ? "" : format(v) }

    private func parse(_ s: String) -> Int64? {
        guard let parsed = Fmt.current.parseFixed(s, scaleDigits: scaleDigits) else { return nil }
        return allowsNegative ? parsed : abs(parsed)
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            isInvalid = false
            value = 0
        } else if let parsed = parse(text) {
            isInvalid = false
            value = parsed
            text = display(parsed)
        } else {
            isInvalid = true
        }
    }
}

/// Edits an amount of money in minor units. Shows the currency symbol next to the field.
///
/// ```swift
/// MoneyField("Amount", minor: $draft.amountMinor, currency: account.currency)
/// MoneyField("Amount", money: $draft.amount)
/// ```
public struct MoneyField: View {
    private let title: String
    @Binding private var minor: Int64
    private let currency: CurrencyCode?
    private let allowsNegative: Bool

    public init(_ title: String, minor: Binding<Int64>, currency: CurrencyCode? = nil, allowsNegative: Bool = false) {
        self.title = title
        _minor = minor
        self.currency = currency
        self.allowsNegative = allowsNegative
    }

    public init(_ title: String, money: Binding<Money>, allowsNegative: Bool = false) {
        self.init(title, minor: money.minor, currency: money.wrappedValue.currency, allowsNegative: allowsNegative)
    }

    public var body: some View {
        FixedPointField(
            title: title, value: $minor, scaleDigits: 2, format: { Fmt.money(minor: $0) },
            suffix: currency.map { Fmt.currencySymbol($0) }, allowsNegative: allowsNegative
        )
    }
}

/// Edits a share count (up to 8 decimals).
public struct SharesField: View {
    private let title: String
    @Binding private var shares: Shares

    public init(_ title: String, shares: Binding<Shares>) {
        self.title = title
        _shares = shares
    }

    public var body: some View {
        FixedPointField(title: title, value: $shares.raw, scaleDigits: 8, format: { Fmt.shares(Shares(raw: $0)) })
    }
}

/// Edits a quote / price per share (up to 8 decimals).
public struct PriceField: View {
    private let title: String
    @Binding private var price: Price
    private let currency: CurrencyCode?

    public init(_ title: String, price: Binding<Price>, currency: CurrencyCode? = nil) {
        self.title = title
        _price = price
        self.currency = currency
    }

    public var body: some View {
        FixedPointField(
            title: title, value: $price.raw, scaleDigits: 8, format: { Fmt.price(Price(raw: $0)) },
            suffix: currency.map { Fmt.currencySymbol($0) }
        )
    }
}

/// Edits a percentage stored as a fraction (0.02 = 2 %).
public struct PercentField: View {
    private let title: String
    @Binding private var fraction: Double
    private let decimals: Int

    public init(_ title: String, fraction: Binding<Double>, decimals: Int = 2) {
        self.title = title
        _fraction = fraction
        self.decimals = decimals
    }

    public var body: some View {
        // Edited as fixed-point percent with 6 decimals (1 % = 1_000_000).
        FixedPointField(
            title: title,
            value: Binding(
                get: { Int64((fraction * 100_000_000).rounded()) },
                set: { fraction = Double($0) / 100_000_000 }
            ),
            scaleDigits: 6,
            format: { Fmt.number(Double($0) / 1_000_000, decimals: decimals) },
            suffix: "%", allowsNegative: true, showsZeroAsEmpty: false
        )
    }
}

/// A date control bound to a model `Day` (stepper field with a graphical calendar popover).
///
/// ```swift
/// DayField("Date", day: $draft.date)
/// DayField("End", day: $plan.end, placeholder: "No end")   // optional day
/// ```
public struct DayField: View {
    private let title: String
    private let binding: Binding<Day?>
    private let isOptional: Bool
    private let placeholder: String

    public init(_ title: String, day: Binding<Day>) {
        self.title = title
        self.binding = Binding(get: { day.wrappedValue }, set: { if let d = $0 { day.wrappedValue = d } })
        self.isOptional = false
        self.placeholder = ""
    }

    /// Optional day: shows a button to set a date and a clear button once set.
    public init(_ title: String, day: Binding<Day?>, placeholder: String = "None") {
        self.title = title
        self.binding = day
        self.isOptional = true
        self.placeholder = placeholder
    }

    /// `Day` is time-zone free; the picker works on local-midnight `Date`s of the current calendar.
    private var date: Binding<Date> {
        Binding(
            get: { (binding.wrappedValue ?? .today).date(in: .current) },
            set: { binding.wrappedValue = Day(date: $0, timeZone: .current) }
        )
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if binding.wrappedValue != nil {
                DatePicker(title, selection: date, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .numeric()
                    .accessibilityLabel(title)
                if isOptional {
                    Button {
                        binding.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear date")
                    .accessibilityLabel("Clear \(title)")
                }
            } else {
                Button(placeholder) { binding.wrappedValue = .today }
                    .accessibilityLabel("\(title): \(placeholder). Set date")
            }
        }
    }
}
