// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EOFCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EOFCore", targets: ["EOFCore"])],
    dependencies: [
        // The swift-6.4.2-RELEASE tag. Pinned by revision because the package depends on a branch of swift-cmark.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", revision: "bc55d614bc8608d74cdc18d3aa6413bd8661e444"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", exact: "4.9.1"),
    ],
    targets: [
        .target(name: "EOFCore", dependencies: [.product(name: "Markdown", package: "swift-markdown"), .product(name: "SWCompression", package: "SWCompression")]),
        .testTarget(name: "EOFCoreTests", dependencies: ["EOFCore"]),
    ]
)
