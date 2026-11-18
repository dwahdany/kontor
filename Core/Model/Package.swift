// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KontorModel",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "KontorModel", targets: ["KontorModel"])],
    targets: [
        .target(name: "KontorModel"),
        .testTarget(name: "KontorModelTests", dependencies: ["KontorModel"]),
    ],
    swiftLanguageModes: [.v6]
)
