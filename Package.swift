// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwelveCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "TwelveCore", targets: ["TwelveCore"])],
    targets: [
        .target(name: "TwelveCore", path: "Core"),
        .testTarget(name: "TwelveCoreTests", dependencies: ["TwelveCore"], path: "Tests")
    ]
)
