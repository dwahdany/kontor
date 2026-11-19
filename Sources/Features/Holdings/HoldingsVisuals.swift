import SwiftUI
import KontorUI

/// Treemap of the displayed holdings: area = market value, color = TTWROR of the period.
struct HoldingsTreemapCard: View {
    let display: HoldingsDisplay
    let currency: CurrencyCode
    let periodTitle: String
    let isLoading: Bool
    let pinnedID: String?
    @Bindable var state: HoldingsViewState

    var body: some View {
        Card(padding: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    Text("Weight and Return").font(.headline)
                    Text("Area: market value · Color: TTWROR, \(periodTitle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HelpButton(.ttwror)
                    Spacer(minLength: 0)
                }
                TreemapChart(display.treemap, format: .money(currency), coloring: .performance(limit: nil), title: "Holdings by market value, colored by period return")
                    .selection(state.selection.count == 1 ? state.selection.first : nil) { id in
                        // Expands the row's group and scrolls the table to it.
                        if let id { state.reveal(id) } else { state.selection = [] }
                    }
                    .loading(isLoading)
                    .emptyMessage("No holdings with a positive value")
                    .pinnedHover(pinnedID)
                    .frame(height: 220)
            }
        }
    }
}

/// How much of the portfolio sits in its largest positions: one stacked bar plus key shares.
struct HoldingsConcentrationCard: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let concentration: HoldingsDisplay.Concentration
    let currency: CurrencyCode
    let pinnedID: String?
    @Bindable var state: HoldingsViewState
    @State private var hovered: String?

    private var highlighted: String? { hovered ?? pinnedID }

    var body: some View {
        Card(padding: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.l) {
                    Text("Concentration").font(.headline)
                    Spacer(minLength: 0)
                    figure("Largest position", concentration.largest)
                    figure("Top 5", concentration.topFive)
                    figure("Top 10", concentration.topTen)
                }
                if concentration.segments.isEmpty {
                    Text("No holdings with a positive value")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    bar
                    legend
                }
            }
        }
    }

    private func figure(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(Fmt.percent(value, decimals: 1)).font(.kontorValue)
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let segments = concentration.segments
            let available = max(0, proxy.size.width - gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let width = max(1, available * segment.share)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(of: segment, index: index))
                        .opacity(highlighted == nil || highlighted == segment.id ? 1 : 0.35)
                        .overlay {
                            // Rank inside the segment: identity without relying on color.
                            if segment.rowID != nil, width >= 26 {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.semibold))
                                    .numeric()
                                    .foregroundStyle(index < CategoryPalette.count ? Color.white : Color.primary)
                            }
                        }
                        .frame(width: width)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = segment.id } else if hovered == segment.id { hovered = nil }
                        }
                        .onTapGesture {
                            if let rowID = segment.rowID { state.reveal(rowID) }
                        }
                        .help("\(segment.name): \(Fmt.money(minor: segment.value, currency: currency)) · \(Fmt.percent(segment.share, decimals: 1))")
                }
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Concentration bar")
        .accessibilityValue(concentration.segments.map { "\($0.name) \(Fmt.percent($0.share, decimals: 1))" }.joined(separator: ", "))
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: DS.Spacing.l, alignment: .leading)], alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(Array(concentration.segments.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: DS.Spacing.xs + 2) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color(of: segment, index: index))
                        .frame(width: 9, height: 9)
                    if segment.rowID != nil {
                        Text("\(index + 1)").numeric().foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                    }
                    Text(segment.name).lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(Fmt.percent(segment.share, decimals: 1)).numeric().foregroundStyle(.secondary)
                }
                .font(.callout)
                .fontWeight(highlighted == segment.id ? .semibold : .regular)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = segment.id } else if hovered == segment.id { hovered = nil }
                }
                .onTapGesture {
                    if let rowID = segment.rowID { state.reveal(rowID) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(of segment: HoldingsDisplay.Segment, index: Int) -> Color {
        if let colorIndex = segment.colorIndex { return CategoryPalette.color(colorIndex) }
        if segment.id == "cash" { return ChartColors.neutral.opacity(0.3) }
        return segment.rowID != nil ? CategoryPalette.other : CategoryPalette.other.opacity(0.6)
    }
}
