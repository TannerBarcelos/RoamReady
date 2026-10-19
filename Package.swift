// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CampCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CampCore", targets: ["CampCore"])],
    targets: [
        .target(name: "CampCore"),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"])
    ]
)
