import SwiftUI

/// A titled content panel — the basic building block of dashboards and detail panes.
///
/// ```swift
/// Card("Allocation", symbol: "chart.pie") {
///     AllocationChart(model)
/// } accessory: {
///     Button("Details") { store.navigate(to: .allocation) }.buttonStyle(.link)
/// }
/// ```
public struct Card<Content: View, Accessory: View>: View {
    private let title: String?
    private let symbol: String?
    private let padding: CGFloat
    private let content: Content
    private let accessory: Accessory

    public init(
        _ title: String? = nil, symbol: String? = nil, padding: CGFloat = DS.Spacing.l,
        @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.symbol = symbol
        self.padding = padding
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    if let title {
                        Text(title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: DS.Spacing.s)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Card where Accessory == EmptyView {
    public init(
        _ title: String? = nil, symbol: String? = nil, padding: CGFloat = DS.Spacing.l,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, symbol: symbol, padding: padding, content: content) { EmptyView() }
    }
}

private struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(DS.Colors.cardFill, in: shape)
            .overlay(shape.strokeBorder(DS.Colors.hairline.opacity(contrast == .increased ? 1 : 0.6), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

extension View {
    /// The standard card surface (fill + hairline border) for custom containers.
    public func cardBackground(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardBackground(radius: radius))
    }

    /// A floating Liquid Glass panel — reserved for transient chrome that sits above content
    /// (command palette, toasts, floating bars). Do not use it for content cards.
    public func glassPanel(radius: CGFloat = DS.Radius.panel) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Standard padding around a screen's scrollable content.
    public func screenPadding() -> some View { padding(DS.Spacing.xl) }
}

/// A section title with optional subtitle and trailing controls.
public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .numeric()
            }
            Spacer(minLength: DS.Spacing.s)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A label/value pair for inspectors and detail panes.
///
/// ```swift
/// KeyValueRow("ISIN", security.isin)
/// KeyValueRow("Value") { GainText(money: gain) }
/// ```
public struct KeyValueRow<Value: View>: View {
    private let key: String
    private let value: Value

    public init(_ key: String, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    public var body: some View {
        LabeledContent {
            value
                .numeric()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(key).foregroundStyle(.secondary)
        }
    }
}

extension KeyValueRow where Value == Text {
    /// Shows `–` for empty values.
    public init(_ key: String, _ value: String) {
        self.init(key) { Text(value.isEmpty ? Fmt.missing : value) }
    }
}

/// A centered explanation for screens or panes without content.
///
/// ```swift
/// EmptyState("No Transactions", symbol: "list.bullet.rectangle",
///            message: "Record a purchase or import your history.") {
///     Button("New Transaction") { store.present(.newTransaction) }
///     Button("Import…") { store.present(.importFile(nil)) }
/// }
/// ```
public struct EmptyState<Actions: View>: View {
    private let title: String
    private let symbol: String
    private let message: String?
    private let actions: Actions

    public init(_ title: String, symbol: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    public init(_ title: String, symbol: String, message: String? = nil) {
        self.init(title, symbol: symbol, message: message) { EmptyView() }
    }
}

private struct LoadingOverlay: ViewModifier {
    let isLoading: Bool
    let label: String?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if visible {
                    VStack(spacing: DS.Spacing.s) {
                        ProgressView().controlSize(.small)
                        if let label {
                            Text(label).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.m)
                    .glassPanel(radius: DS.Radius.card)
                    .transition(.opacity)
                }
            }
            // Only show the spinner when loading takes noticeable time, so fast screens never flicker.
            .task(id: isLoading) {
                if isLoading {
                    try? await Task.sleep(for: .milliseconds(180))
                    if !Task.isCancelled { visible = true }
                } else {
                    visible = false
                }
            }
    }
}

extension View {
    /// Shows a small spinner panel over the view while `isLoading` — but only if loading takes longer
    /// than ~180 ms, so instant recomputations never flash.
    public func loadingOverlay(_ isLoading: Bool, label: String? = nil) -> some View {
        modifier(LoadingOverlay(isLoading: isLoading, label: label))
    }
}
