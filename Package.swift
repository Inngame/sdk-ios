// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inngame",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Inngame", targets: ["Inngame"])],
    targets: [
        .target(name: "Inngame", path: "Sources/Inngame"),
        .testTarget(name: "InngameTests", dependencies: ["Inngame"], path: "Tests/InngameTests"),
    ]
)
