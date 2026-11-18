import SwiftUI
import KontorModel

/// Keys of app-level preferences (UserDefaults / `@AppStorage`). Document-level settings live in
/// `PortfolioFile.settings` instead.
///
/// ```swift
/// @AppStorage(AppPreferences.Key.gainStyle) private var gainStyle = GainStyle.regionDefault
/// ```
public enum AppPreferences {
    public enum Key {
        /// `GainStyle.rawValue`
        public static let gainStyle = "general.gainStyle"
        /// ISO code used for new portfolios.
        public static let defaultCurrency = "general.defaultCurrency"
        /// `AppearanceMode.rawValue`
        public static let appearance = "general.appearance"
        /// Bool — fetch quotes when a document opens.
        public static let autoUpdateQuotes = "marketData.autoUpdateOnOpen"
        /// Bool — also update on a timer while the app is running.
        public static let periodicUpdate = "marketData.periodicUpdate"
        /// Bool — write indented JSON (larger files, friendlier diffs).
        public static let prettyPrintFiles = "advanced.prettyPrintFiles"
        /// Bool — show the welcome window at launch.
        public static let showWelcomeAtLaunch = "general.showWelcomeAtLaunch"
    }

    /// The currency suggested for new portfolios: the stored preference or the region's currency.
    public static var defaultCurrency: CurrencyCode {
        UserDefaults.standard.string(forKey: Key.defaultCurrency) ?? Locale.current.currency?.identifier ?? "EUR"
    }

    /// The stored gain/loss color convention.
    public static var gainStyle: GainStyle {
        UserDefaults.standard.string(forKey: Key.gainStyle).flatMap(GainStyle.init(rawValue:)) ?? .regionDefault
    }

    public static var prettyPrintFiles: Bool { UserDefaults.standard.bool(forKey: Key.prettyPrintFiles) }
}

/// App appearance override.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
