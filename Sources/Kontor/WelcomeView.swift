import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KontorModel
import KontorUI

/// What the welcome window can do. The app wires these to document actions; the screenshot mode
/// passes inert actions.
struct WelcomeActions {
    var newPortfolio: (_ name: String, _ currency: CurrencyCode) -> Void = { _, _ in }
    var open: () -> Void = {}
    var openDemo: () -> Void = {}
    var importPortfolioPerformance: () -> Void = {}
    var openRecent: (URL) -> Void = { _ in }
}

/// Launch window: start a portfolio, open one, explore the demo or import — plus recent documents.
struct WelcomeView: View {
    let actions: WelcomeActions
    var recents: [URL]

    @State private var isCreating = false
    @State private var name = ""
    @State private var currency: CurrencyCode = AppPreferences.defaultCurrency
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: 400)
                .frame(maxHeight: .infinity)
            Divider()
            RecentsList(recents: recents, open: actions.openRecent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var leading: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.xl)
            KontorMark()
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            Text("Kontor")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, DS.Spacing.m)
            Text("Your investments, clearly.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, DS.Spacing.xxs)
            Text(versionText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, DS.Spacing.xs)

            Spacer(minLength: DS.Spacing.l)

            if isCreating {
                newPortfolioForm
            } else {
                VStack(spacing: DS.Spacing.s) {
                    WelcomeButton("New Portfolio", subtitle: "Start with an empty portfolio", symbol: "plus.square", isProminent: true) {
                        isCreating = true
                        nameFocused = true
                    }
                    WelcomeButton("Open…", subtitle: "Open a Kontor file", symbol: "folder", action: actions.open)
                    WelcomeButton("Open Demo Portfolio", subtitle: "Explore with sample data", symbol: "sparkles.rectangle.stack", action: actions.openDemo)
                    WelcomeButton("Import from Portfolio Performance…", subtitle: "Bring in an existing .xml or .portfolio file", symbol: "square.and.arrow.down", action: actions.importPortfolioPerformance)
                }
            }
            Spacer(minLength: DS.Spacing.xl)
        }
        .padding(.horizontal, DS.Spacing.xxl)
    }

    private var newPortfolioForm: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("New Portfolio").font(.headline)
            TextField("Name", text: $name, prompt: Text("My Portfolio"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
            HStack {
                Text("Base Currency").foregroundStyle(.secondary)
                Spacer()
                CurrencyPicker(selection: $currency)
                    .frame(width: 130)
            }
            Text("Reports are converted to the base currency. You can change it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isCreating = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.l)
        .cardBackground()
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        actions.newPortfolio(trimmed.isEmpty ? "My Portfolio" : trimmed, currency)
        isCreating = false
        name = ""
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Development Build"
    }
}

private struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    var isProminent = false
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, subtitle: String, symbol: String, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isHovered ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RecentsList: View {
    /// "~/Documents" style display path of the folder containing `url`.
    static func folder(of url: URL) -> String {
        let path = (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    let recents: [URL]
    let open: (URL) -> Void
    @State private var selection: URL?

    var body: some View {
        if recents.isEmpty {
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: "clock")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Recent Portfolios").font(.headline).foregroundStyle(.secondary)
                Text("Portfolios you open will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Spacing.xl)
        } else {
            List(recents, id: \.self, selection: $selection) { url in
                HStack(spacing: DS.Spacing.m) {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(Self.folder(of: url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.vertical, 3)
                .tag(url)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(url) }
                .onTapGesture { selection = url }
            }
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                open(selection)
                return .handled
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.top, DS.Spacing.xl + 6)
                    .padding(.bottom, DS.Spacing.xs)
            }
        }
    }
}
