// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TesseraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TesseraCore", targets: ["TesseraCore"])],
    targets: [
        .target(name: "TesseraCore"),
        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
    ]
)
