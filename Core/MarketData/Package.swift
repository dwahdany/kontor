// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KontorMarketData",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "KontorMarketData", targets: ["KontorMarketData"])],
    dependencies: [.package(path: "../Model")],
    targets: [
        .target(
            name: "KontorMarketData",
            dependencies: [.product(name: "KontorModel", package: "Model")]
        ),
        .testTarget(
            name: "KontorMarketDataTests",
            dependencies: ["KontorMarketData", .product(name: "KontorModel", package: "Model")],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
