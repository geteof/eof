// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EOFCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EOFCore", targets: ["EOFCore"])],
    targets: [
        .target(name: "EOFCore"),
        .testTarget(name: "EOFCoreTests", dependencies: ["EOFCore"]),
    ]
)
