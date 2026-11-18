import SwiftUI
import KontorModel

/// Design tokens. Use these instead of literal numbers so screens stay visually consistent.
public enum DS {
    /// Spacing scale (points).
    public enum Spacing {
        /// 2 — hairline gaps inside compound labels.
        public static let xxs: CGFloat = 2
        /// 4 — icon ↔ text, tight stacks.
        public static let xs: CGFloat = 4
        /// 8 — default gap between related controls.
        public static let s: CGFloat = 8
        /// 12 — inside cards, between rows of a form.
        public static let m: CGFloat = 12
        /// 16 — card padding, gap between cards.
        public static let l: CGFloat = 16
        /// 24 — screen margins, gap between sections.
        public static let xl: CGFloat = 24
        /// 32 — large separations, empty states.
        public static let xxl: CGFloat = 32
    }

    /// Corner radii (continuous corners).
    public enum Radius {
        /// 4 — chips, tags.
        public static let small: CGFloat = 4
        /// 8 — controls, list rows.
        public static let control: CGFloat = 8
        /// 14 — cards and panels.
        public static let card: CGFloat = 14
        /// 20 — floating panels (command palette, toasts).
        public static let panel: CGFloat = 20
    }

    /// Standard sizes.
    public enum Size {
        /// Default row height of dense tables.
        public static let tableRow: CGFloat = 26
        /// Height of a sparkline inside a table row.
        public static let sparkline = CGSize(width: 72, height: 20)
        /// Maximum width of readable content columns (forms, empty states).
        public static let readableWidth: CGFloat = 560
        /// Minimum width of a dashboard card.
        public static let cardMinWidth: CGFloat = 220
    }

    /// Animation presets. Use `DS.Motion.standard(reduceMotion)` to honour Reduce Motion.
    public enum Motion {
        public static let quick: Animation = .snappy(duration: 0.18)
        public static let regular: Animation = .smooth(duration: 0.28)
        /// `nil` (no animation) when the user enabled Reduce Motion.
        public static func standard(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : regular }
    }
}

// MARK: - Color

extension Color {
    /// Creates a color from `#RRGGBB`, `#RRGGBBAA` or `#RGB` (the leading `#` is optional).
    /// Invalid strings produce the system gray so that broken data never crashes a chart.
    public init(hex: String) {
        if let c = Self.components(hex: hex) {
            self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        } else {
            self.init(.sRGB, red: 0.556, green: 0.556, blue: 0.576, opacity: 1)
        }
    }

    /// A color that resolves to `light` or `dark` with the effective appearance.
    public init(light: String, dark: String) {
        let l = NSColor(Color(hex: light)), d = NSColor(Color(hex: dark))
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil ? d : l
        })
    }

    static func components(hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var digits = [UInt8]()
        for c in hex.utf8 where c != 0x23 && c != 0x20 {
            switch c {
            case 0x30...0x39: digits.append(c - 0x30)
            case 0x41...0x46: digits.append(c - 0x41 + 10)
            case 0x61...0x66: digits.append(c - 0x61 + 10)
            default: return nil
            }
        }
        func byte(_ i: Int) -> Double { Double(digits[i] * 16 + digits[i + 1]) / 255 }
        switch digits.count {
        case 3: return (Double(digits[0]) / 15, Double(digits[1]) / 15, Double(digits[2]) / 15, 1)
        case 6: return (byte(0), byte(2), byte(4), 1)
        case 8: return (byte(0), byte(2), byte(4), byte(6))
        default: return nil
        }
    }

    /// `#RRGGBB` of this color in sRGB (for storing in `Classification.color`).
    public var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func h(_ v: CGFloat) -> String {
            let s = String(Int((max(0, min(1, v)) * 255).rounded()), radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + h(c.redComponent) + h(c.greenComponent) + h(c.blueComponent)
    }
}

extension DS {
    /// Semantic colors. Color is reserved for meaning — text and chrome use the system label colors.
    public enum Colors {
        /// Positive polarity in the "green is up" convention.
        public static let green = Color(light: "#1A8F3C", dark: "#30D158")
        /// Negative polarity in the "green is up" convention.
        public static let red = Color(light: "#D32F2F", dark: "#FF5A52")
        /// Unchanged / not applicable.
        public static let neutral = Color.secondary
        /// Warnings (stale quotes, missing data).
        public static let warning = Color(light: "#B26A00", dark: "#FFB340")
        /// Subtle fill behind cards on top of the window background.
        public static let cardFill = Color(nsColor: .controlBackgroundColor)
        /// Hairline borders and separators.
        public static let hairline = Color(nsColor: .separatorColor)
        /// Benchmark / comparison series in charts.
        public static let benchmark = Color(light: "#8A8A8E", dark: "#98989D")
    }
}

/// Which color means "up". Western markets use green for gains; East Asian markets use red.
public enum GainStyle: String, CaseIterable, Identifiable, Sendable {
    case greenUp
    case redUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .greenUp: "Green for gains, red for losses"
        case .redUp: "Red for gains, green for losses"
        }
    }

    public var gain: Color { self == .greenUp ? DS.Colors.green : DS.Colors.red }
    public var loss: Color { self == .greenUp ? DS.Colors.red : DS.Colors.green }

    /// The color for a signed value: gain, loss or neutral for zero.
    public func color(for value: Double) -> Color {
        value > 0 ? gain : value < 0 ? loss : DS.Colors.neutral
    }
    public func color(forMinor minor: Int64) -> Color {
        minor > 0 ? gain : minor < 0 ? loss : DS.Colors.neutral
    }

    /// The default for the user's region (red-up in mainland China, Japan, Korea, Taiwan).
    public static var regionDefault: GainStyle {
        switch Locale.current.region?.identifier {
        case "CN", "JP", "KR", "TW": .redUp
        default: .greenUp
        }
    }
}

extension EnvironmentValues {
    /// The user's gain/loss color convention (Settings ▸ General). Injected by the shell.
    @Entry public var gainStyle: GainStyle = .greenUp
}

/// Categorical colors for charts and allocation categories.
///
/// The eight hues are colorblind-validated *in this order* (adjacent slots stay distinguishable under
/// protanopia/deuteranopia/tritanopia) and each has a light and a dark step. Assign slots by entity
/// in fixed order; never cycle past eight — fold the rest into "Other" (`CategoryPalette.other`).
public enum CategoryPalette {
    private static let slots: [(light: String, dark: String)] = [
        ("#2A78D6", "#3987E5"), // blue
        ("#EB6834", "#D95926"), // orange
        ("#1BAF7A", "#199E70"), // aqua
        ("#EDA100", "#C98500"), // yellow
        ("#E87BA4", "#D55181"), // magenta
        ("#008300", "#0CA30C"), // green
        ("#6250D6", "#9085E9"), // violet
        ("#E34948", "#E66767"), // red
    ]

    /// Number of distinct categorical colors.
    public static let count = slots.count

    /// All colors in assignment order (adaptive to light/dark).
    public static let colors: [Color] = slots.map { Color(light: $0.light, dark: $0.dark) }

    /// The color for the n-th category. Indices past the palette return ``other``.
    public static func color(_ index: Int) -> Color {
        index >= 0 && index < colors.count ? colors[index] : other
    }

    /// Neutral gray for "Other" / unclassified.
    public static let other = Color(light: "#9A9AA0", dark: "#7C7C82")

    /// The light-appearance hex value of a slot — for persisting a default into `Classification.color`.
    public static func hex(_ index: Int) -> String {
        index >= 0 && index < slots.count ? slots[index].light : "#9A9AA0"
    }
}

// MARK: - Typography

extension Font {
    /// The hero number of a tile (rounded, tabular digits).
    public static let kontorHero = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    /// Secondary large number.
    public static let kontorValue = Font.system(size: 17, weight: .medium).monospacedDigit()
    /// Numbers in tables and rows.
    public static let kontorNumber = Font.body.monospacedDigit()
    /// Small uppercase-ish captions above values.
    public static let kontorCaption = Font.caption.weight(.medium)
}

extension View {
    /// Tabular digits for any text that shows numbers (so columns line up and values don't jitter).
    public func numeric() -> some View { monospacedDigit() }
}

/// Parses `#RGB` / `#RRGGBB` / `#RRGGBBAA` into sRGB components (0…1); nil if malformed.
public func hexComponents(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    Color.components(hex: hex)
}
