// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KontorSampleData",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "KontorSampleData", targets: ["KontorSampleData"])],
    dependencies: [.package(path: "../Model")],
    targets: [
        .target(name: "KontorSampleData", dependencies: [.product(name: "KontorModel", package: "Model")]),
        .testTarget(
            name: "KontorSampleDataTests",
            dependencies: ["KontorSampleData", .product(name: "KontorModel", package: "Model")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
