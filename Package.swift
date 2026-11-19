// swift-tools-version: 6.4
import PackageDescription

// MARK: Feature selection (build isolation)
//
// One library target per screen. `KONTOR_FEATURES` selects which of them are part of the package:
//
//   (unset) or "all"            every feature (the default; what CI and releases build)
//   KONTOR_FEATURES=Holdings    only FeatureHoldings — every other screen shows the placeholder
//   KONTOR_FEATURES=Holdings,Transactions
//   KONTOR_FEATURES=none        the bare shell
//
// Features that are not listed are not even declared as targets, so their sources are never
// compiled: `swift build`, `swift test` and the app work no matter what state the other features
// are in. The shell's `FeatureCatalog` uses `#if canImport(FeatureX)` to register what is linked.
// Use a scratch path per selection (`swift build --scratch-path .build-holdings`) — Scripts/shot.sh
// and Scripts/bundle.sh do that for you.
let allFeatures = [
    "Dashboard", "Holdings", "Performance", "Earnings", "Trades", "Allocation",
    "Securities", "Transactions", "Accounts", "Plans", "Import",
]

let features: [String] = {
    guard let raw = Context.environment["KONTOR_FEATURES"] else { return allFeatures }
    let requested = raw.split(separator: ",").map { $0.filter { !$0.isWhitespace }.lowercased() }.filter { !$0.isEmpty }
    if requested.contains("all") { return allFeatures }
    let unknown = requested.filter { name in name != "none" && !allFeatures.contains { $0.lowercased() == name } }
    precondition(unknown.isEmpty, "KONTOR_FEATURES: unknown feature(s) \(unknown) — expected a comma-separated subset of \(allFeatures), \"all\" or \"none\"")
    return allFeatures.filter { requested.contains($0.lowercased()) }
}()

// MARK: Dependencies

let model: Target.Dependency = .product(name: "KontorModel", package: "Model")
let engine: Target.Dependency = .product(name: "KontorEngine", package: "Engine")
let marketData: Target.Dependency = .product(name: "KontorMarketData", package: "MarketData")
let interchange: Target.Dependency = .product(name: "KontorInterchange", package: "Interchange")
let sampleData: Target.Dependency = .product(name: "KontorSampleData", package: "SampleData")

/// Every feature: KontorUI (which re-exports KontorModel and KontorEngine) + the two explicitly.
/// Extra core packages per feature are listed here — features never depend on each other.
func dependencies(ofFeature name: String) -> [Target.Dependency] {
    var result: [Target.Dependency] = ["KontorUI", model, engine]
    switch name {
    case "Import": result.append(interchange)
    case "Securities": result.append(marketData)
    default: break
    }
    return result
}

let package = Package(
    name: "Kontor",
    defaultLocalization: "en",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Kontor", targets: ["Kontor"]),
        .library(name: "KontorUI", targets: ["KontorUI"]),
    ],
    dependencies: [
        .package(path: "Core/Model"),
        .package(path: "Core/Engine"),
        .package(path: "Core/MarketData"),
        .package(path: "Core/Interchange"),
        .package(path: "Core/SampleData"),
    ],
    targets: [
        .target(
            name: "KontorUI",
            dependencies: [model, engine, marketData, sampleData],
            path: "Sources/KontorUI",
            exclude: ["API.md"]
        ),
        .executableTarget(
            name: "Kontor",
            dependencies: ["KontorUI", model, engine, marketData, interchange, sampleData]
                + features.map { .target(name: "Feature\($0)") },
            path: "Sources/Kontor"
        ),
        .testTarget(
            name: "KontorUITests",
            dependencies: ["KontorUI", model, engine, marketData, sampleData],
            path: "Tests/KontorUITests"
        ),
    ] + features.flatMap { name -> [Target] in
        [
            .target(
                name: "Feature\(name)",
                dependencies: dependencies(ofFeature: name),
                path: "Sources/Features/\(name)"
            ),
            // Each feature owns Tests/Feature<Name>Tests as well.
            .testTarget(
                name: "Feature\(name)Tests",
                dependencies: [.target(name: "Feature\(name)"), sampleData] + dependencies(ofFeature: name),
                path: "Tests/Feature\(name)Tests"
            ),
        ]
    },
    swiftLanguageModes: [.v6]
)
