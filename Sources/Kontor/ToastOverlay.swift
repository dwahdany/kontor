import SwiftUI
import KontorUI

/// Stack of transient notifications at the bottom of the window.
struct ToastOverlay: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            ForEach(store.toasts) { toast in
                ToastView(toast: toast) { store.dismissToast(toast.id) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, DS.Spacing.xl)
        .animation(DS.Motion.standard(reduceMotion), value: store.toasts)
    }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: toast.symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(toast.title).font(.callout.weight(.medium))
                if let message = toast.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, DS.Spacing.xs)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: 440)
        .fixedSize(horizontal: true, vertical: false)
        .glassPanel(radius: DS.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var tint: Color {
        switch toast.style {
        case .info: .accentColor
        case .success: DS.Colors.green
        case .warning: DS.Colors.warning
        case .error: DS.Colors.red
        }
    }
}
