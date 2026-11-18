// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KontorInterchange",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "KontorInterchange", targets: ["KontorInterchange"])],
    dependencies: [.package(path: "../Model")],
    targets: [
        .target(
            name: "KontorInterchange",
            dependencies: [.product(name: "KontorModel", package: "Model")]
        ),
        .testTarget(
            name: "KontorInterchangeTests",
            dependencies: ["KontorInterchange", .product(name: "KontorModel", package: "Model")],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
