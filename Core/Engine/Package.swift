// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KontorEngine",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "KontorEngine", targets: ["KontorEngine"])],
    dependencies: [.package(path: "../Model")],
    targets: [
        .target(name: "KontorEngine", dependencies: [.product(name: "KontorModel", package: "Model")]),
        .testTarget(
            name: "KontorEngineTests",
            dependencies: ["KontorEngine", .product(name: "KontorModel", package: "Model")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
