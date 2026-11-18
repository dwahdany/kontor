// swift-tools-version: 6.4
import PackageDescription

/// One library target per screen. Feature targets depend on KontorUI + KontorModel only — never on
/// each other. Cross-feature needs go through KontorUI (routes, sheet requests, the feature registry).
let features = [
    "Dashboard", "Holdings", "Performance", "Earnings", "Trades", "Allocation",
    "Securities", "Transactions", "Accounts", "Plans", "Import",
]

let model: Target.Dependency = .product(name: "KontorModel", package: "Model")

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
    ],
    targets: [
        .target(
            name: "KontorUI",
            dependencies: [model],
            path: "Sources/KontorUI",
            exclude: ["API.md"]
        ),
        .executableTarget(
            name: "Kontor",
            dependencies: ["KontorUI", model] + features.map { .target(name: "Feature\($0)") },
            path: "Sources/Kontor"
        ),
        .testTarget(
            name: "KontorUITests",
            dependencies: ["KontorUI", model],
            path: "Tests/KontorUITests"
        ),
    ] + features.map { name in
        .target(
            name: "Feature\(name)",
            dependencies: ["KontorUI", model],
            path: "Sources/Features/\(name)"
        )
    },
    swiftLanguageModes: [.v6]
)
