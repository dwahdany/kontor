import SwiftUI
import KontorModel
import KontorUI

/// Screen navigation, grouped into sections, with a status footer (background activity, freshness
/// of quotes).
struct SidebarView: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        List(selection: selection) {
            ForEach(AppScreen.Section.allCases) { section in
                Section(section.title) {
                    ForEach(section.screens, id: \.self) { screen in
                        Label(screen.title, systemImage: screen.symbol)
                            .tag(screen)
                            .help(screen.summary)
                            .badge(badge(for: screen))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
        .accessibilityLabel("Screens")
    }

    private var selection: Binding<AppScreen?> {
        Binding(
            get: { store.route.screen },
            set: { if let screen = $0, screen != store.route.screen { store.navigate(to: screen) } }
        )
    }

    /// Entity counts for the data screens — orientation at a glance, never more than a number.
    private func badge(for screen: AppScreen) -> Text? {
        let count: Int
        switch screen {
        case .securities: count = store.file.securities.count
        case .transactions: count = store.file.transactions.count
        case .accounts: count = store.file.accounts.count + store.file.depots.count
        case .plans: count = store.file.plans.count
        default: return nil
        }
        return count == 0 ? nil : Text(Fmt.integer(count)).monospacedDigit()
    }
}

/// Bottom of the sidebar: running activity, otherwise how fresh the quotes are.
private struct SidebarStatus: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let activity = store.activity {
                Text(activity.statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fraction = activity.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else {
                HStack(spacing: DS.Spacing.xs + 2) {
                    Circle()
                        .fill(quoteStatus.color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(quoteStatus.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(store.baseCurrency)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .help("Reporting currency")
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The most recent quote date across active securities.
    private var quoteStatus: (text: String, color: Color) {
        let latest = store.file.securities.lazy.filter { !$0.isRetired }.compactMap { $0.prices.lastDay }.max()
        guard let latest else { return ("No quotes yet", Color.secondary.opacity(0.5)) }
        let age = latest.distance(to: store.today)
        let text = "Quotes: \(Fmt.relativeDay(latest, today: store.today))"
        // Weekends are not stale: allow up to three days before warning.
        return (text, age <= 3 ? DS.Colors.green : DS.Colors.warning)
    }
}
