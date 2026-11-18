import SwiftUI
import KontorModel
import KontorUI

/// App-level preferences (⌘,). Stored in UserDefaults via `AppPreferences.Key`; document-level
/// settings live in the file and are edited in Portfolio ▸ Portfolio Settings….
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Market Data", systemImage: "chart.line.uptrend.xyaxis") { MarketDataSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .scenePadding()
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppPreferences.Key.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(AppPreferences.Key.gainStyle) private var gainStyle = GainStyle.regionDefault.rawValue
    @AppStorage(AppPreferences.Key.defaultCurrency) private var defaultCurrency = AppPreferences.defaultCurrency
    @AppStorage(AppPreferences.Key.showWelcomeAtLaunch) private var showWelcome = true

    private var style: GainStyle { GainStyle(rawValue: gainStyle) ?? .greenUp }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Gains and Losses", selection: $gainStyle) {
                    ForEach(GainStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Preview") {
                    HStack(spacing: DS.Spacing.l) {
                        DeltaLabel(fraction: 0.0234, amount: Money(minor: 123_456, currency: defaultCurrency))
                        DeltaLabel(fraction: -0.0118, amount: Money(minor: -61_020, currency: defaultCurrency))
                    }
                    .environment(\.gainStyle, style)
                }
            }
            Section {
                LabeledContent("Default Currency") {
                    CurrencyPicker(selection: $defaultCurrency)
                        .frame(width: 180)
                }
                Toggle("Show welcome window at launch", isOn: $showWelcome)
            } header: {
                Text("New Portfolios")
            }
            Section {
                LabeledContent("Amount", value: Fmt.money(Money(minor: 123_456_789, currency: defaultCurrency)))
                LabeledContent("Compact", value: Fmt.compactMoney(Money(minor: 123_456_789, currency: defaultCurrency)))
                LabeledContent("Percentage", value: Fmt.percent(0.07342, signed: true))
                LabeledContent("Shares", value: Fmt.shares(Shares(raw: 123_456_780_000)))
                LabeledContent("Date", value: "\(Fmt.day(.today))  ·  \(Fmt.day(.today, style: .medium))")
            } header: {
                Text("Number Formats")
            } footer: {
                Text("Formats follow the region set in System Settings ▸ General ▸ Language & Region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .formStyle(.grouped)
    }
}

struct MarketDataSettings: View {
    @AppStorage(AppPreferences.Key.autoUpdateQuotes) private var autoUpdate = true
    @AppStorage(AppPreferences.Key.periodicUpdate) private var periodic = false

    var body: some View {
        Form {
            Section {
                Toggle("Update quotes when a portfolio opens", isOn: $autoUpdate)
                Toggle("Keep updating while Kontor is open", isOn: $periodic)
                    .disabled(!autoUpdate)
            } header: {
                Text("Quotes and Exchange Rates")
            } footer: {
                Text("Kontor only contacts the quote providers you configure per security. No portfolio data leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @AppStorage(AppPreferences.Key.prettyPrintFiles) private var prettyPrint = false
    @State private var didReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Write human-readable files", isOn: $prettyPrint)
            } header: {
                Text("File Format")
            } footer: {
                Text("Kontor files are plain JSON. Indented files are larger but produce clean diffs in version control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reset") {
                LabeledContent("Preferences") {
                    Button(didReset ? "Restored" : "Restore Defaults") {
                        for key in [
                            AppPreferences.Key.appearance, AppPreferences.Key.gainStyle, AppPreferences.Key.defaultCurrency,
                            AppPreferences.Key.autoUpdateQuotes, AppPreferences.Key.periodicUpdate,
                            AppPreferences.Key.prettyPrintFiles, AppPreferences.Key.showWelcomeAtLaunch,
                        ] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                        didReset = true
                    }
                    .disabled(didReset)
                }
            }
        }
        .formStyle(.grouped)
    }
}
