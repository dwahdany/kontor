import SwiftUI
import KontorUI

/// A watchlist name being entered: a new list (`id == nil`, optionally created with securities) or
/// a rename.
struct WatchlistNameEdit: Identifiable, Equatable {
    var id: UUID?
    var name: String
    var adding: Set<UUID> = []
}

/// The filter chips above the list: status filters, one chip per watchlist (a drop target for
/// securities) and "+" for a new watchlist.
struct FilterChips: View {
    @Environment(PortfolioStore.self) private var store
    @Binding var filter: SecurityFilter
    let counts: SecurityListModel.Counts
    @Binding var edit: WatchlistNameEdit?
    let selection: Set<UUID>

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Spacing.xs) {
                chip("All", count: counts.all, .all)
                chip("Held", count: counts.held, .held)
                chip("Not Held", count: counts.notHeld, .notHeld)
                ForEach(store.file.watchlists) { list in
                    WatchlistChip(list: list, count: counts.watchlists[list.id] ?? 0, filter: $filter, edit: $edit)
                }
                if counts.missingQuotes > 0 || filter == .missingQuotes {
                    chip("Missing Quotes", count: counts.missingQuotes, .missingQuotes, symbol: "exclamationmark.triangle")
                        .help("Securities without quotes, or whose latest quote is more than \(SecurityListModel.staleAfterDays) days old")
                }
                if counts.retired > 0 || filter == .retired {
                    chip("Retired", count: counts.retired, .retired)
                }
                Button {
                    edit = WatchlistNameEdit(id: nil, name: "")
                } label: {
                    Label("New Watchlist", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary.opacity(0.6), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New watchlist")
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.s)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ title: String, count: Int, _ value: SecurityFilter, symbol: String? = nil) -> some View {
        Button {
            filter = value
        } label: {
            ChipLabel(title: title, count: count, symbol: symbol, isSelected: filter == value)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }
}

struct ChipLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let count: Int
    var symbol: String?
    let isSelected: Bool
    var isTargeted = false

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title)
            Text(Fmt.integer(count))
                .numeric()
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, DS.Spacing.s + 2)
        .frame(height: 22)
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .background(
            isSelected || isTargeted ? AnyShapeStyle(Color.accentColor.opacity(isTargeted ? 0.3 : 0.16)) : AnyShapeStyle(.quaternary.opacity(0.6)),
            in: Capsule())
        .overlay {
            if isSelected, contrast == .increased { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
        }
        .contentShape(Capsule())
    }
}

private struct WatchlistChip: View {
    @Environment(PortfolioStore.self) private var store
    let list: Watchlist
    let count: Int
    @Binding var filter: SecurityFilter
    @Binding var edit: WatchlistNameEdit?
    @State private var isTargeted = false

    var body: some View {
        Button {
            filter = .watchlist(list.id)
        } label: {
            ChipLabel(title: list.name, count: count, symbol: "star", isSelected: filter == .watchlist(list.id), isTargeted: isTargeted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == .watchlist(list.id) ? .isSelected : [])
        .help("Watchlist “\(list.name)” — drop securities here to add them")
        .dropDestination(for: String.self) { items, _ in
            let ids = items.flatMap { $0.split(whereSeparator: \.isNewline) }.compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return false }
            store.addSecurities(ids, toWatchlist: list.id)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Rename…") { edit = WatchlistNameEdit(id: list.id, name: list.name) }
            Button("Delete Watchlist", role: .destructive) {
                if filter == .watchlist(list.id) { filter = .all }
                store.deleteWatchlist(list.id)
            }
        }
    }
}

/// Inline name entry for a new or renamed watchlist (no modal dialog).
struct WatchlistNameBar: View {
    let edit: WatchlistNameEdit
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "star").foregroundStyle(.secondary)
            TextField(edit.id == nil ? "Name of the new watchlist" : "Watchlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commit(name) }
                .onExitCommand(perform: cancel)
            Button(edit.id == nil ? (edit.adding.isEmpty ? "Create" : "Create with \(edit.adding.count)") : "Rename") { commit(name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", action: cancel)
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(.quaternary.opacity(0.35))
        .onAppear {
            name = edit.name
            isFocused = true
        }
        .onChange(of: edit) { _, new in name = new.name }
    }
}

/// The context menu of one or more securities (list rows and the detail's "more" menu).
struct SecurityContextMenu: View {
    @Environment(PortfolioStore.self) private var store
    let ids: Set<UUID>
    var filter = SecurityFilter.all
    /// Start naming a new watchlist that will contain `ids`.
    var newWatchlist: ((String) -> Void)?
    /// Select a security created by an action (Duplicate).
    var selectNew: ((UUID) -> Void)?

    var body: some View {
        let single = ids.count == 1 ? ids.first : nil
        let securities = ids.compactMap { store.security($0) }
        if let id = single {
            Button("Edit…") { store.present(.editSecurity(id)) }
            Menu("New Transaction") {
                ForEach([Transaction.Kind.buy, .sell, .dividend, .deliveryIn, .deliveryOut], id: \.self) { kind in
                    Button(kind.title) { store.presentNewTransaction(kind, securityID: id) }
                }
            }
            Divider()
        }
        if !ids.isEmpty {
            Button("Update Quotes") { store.updateQuotes(only: ids) }
                .disabled(!MarketAccess.isOnline(store) || store.isUpdatingQuotes)
            Menu("Add to Watchlist") {
                ForEach(store.file.watchlists) { list in
                    let containsAll = ids.allSatisfy(list.securityIDs.contains)
                    Button {
                        if containsAll { store.removeSecurities(ids, fromWatchlist: list.id) } else { store.addSecurities(ids, toWatchlist: list.id) }
                    } label: {
                        if containsAll { Label(list.name, systemImage: "checkmark") } else { Text(list.name) }
                    }
                }
                if let newWatchlist {
                    if !store.file.watchlists.isEmpty { Divider() }
                    Button("New Watchlist…") { newWatchlist("") }
                }
            }
            if case .watchlist(let listID) = filter, let list = store.file.watchlists.first(where: { $0.id == listID }) {
                Button("Remove from “\(list.name)”") { store.removeSecurities(ids, fromWatchlist: listID) }
            }
            Divider()
            if let id = single {
                Button(store.isBenchmark(id) ? "Stop Using as Benchmark" : "Use as Benchmark") { store.toggleBenchmark(id) }
            }
            let allRetired = !securities.isEmpty && securities.allSatisfy(\.isRetired)
            Button(allRetired ? "Reactivate" : "Retire") { store.setRetired(ids, !allRetired) }
            if let id = single {
                Button("Duplicate") {
                    if let new = store.duplicateSecurity(id) { selectNew?(new) }
                }
            }
            Divider()
            Button("Copy") { Pasteboard.copy(store.securitiesTSV(ids)) }
            if let id = single {
                Button("Export Quotes…") { store.present(.export(ExportRequest(.quotes(securityID: id)))) }
            }
            Divider()
            Button("Delete…", role: .destructive) { store.confirmDeleteSecurities(ids) }
        }
    }
}

/// Shown instead of the detail when several securities are selected: what is selected and the
/// actions that apply to all of them.
struct MultiSelectionView: View {
    @Environment(PortfolioStore.self) private var store
    let ids: Set<UUID>
    let filter: SecurityFilter

    var body: some View {
        let securities = store.file.securities.filter { ids.contains($0.id) }
        let usage = store.usage(ofSecurities: ids)
        let allRetired = securities.allSatisfy(\.isRetired)
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(Fmt.integer(securities.count)) Securities Selected").font(.title3.weight(.semibold))
            Text(securities.prefix(6).map(\.name).joined(separator: ", ") + (securities.count > 6 ? " and \(securities.count - 6) more" : ""))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !usage.isUnused {
                Text("In use: \(usage.summary)").font(.callout).foregroundStyle(.secondary).numeric()
            }
            HStack(spacing: DS.Spacing.s) {
                Button("Update Quotes") { store.updateQuotes(only: ids) }
                    .disabled(!MarketAccess.isOnline(store) || store.isUpdatingQuotes)
                Menu("Add to Watchlist") {
                    ForEach(store.file.watchlists) { list in
                        Button(list.name) { store.addSecurities(ids, toWatchlist: list.id) }
                    }
                }
                .fixedSize()
                .disabled(store.file.watchlists.isEmpty)
                Button(allRetired ? "Reactivate" : "Retire") { store.setRetired(ids, !allRetired) }
                Button("Copy") { Pasteboard.copy(store.securitiesTSV(ids)) }
                Button("Delete…", role: .destructive) { store.confirmDeleteSecurities(ids) }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
