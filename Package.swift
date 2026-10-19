// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CampCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CampCore", targets: ["CampCore"]), .library(name: "CampPersistence", targets: ["CampPersistence"])],
    targets: [
        .target(name: "CampCore"),
        .target(name: "CampPersistence", dependencies: ["CampCore"]),
        .testTarget(name: "CampPersistenceTests", dependencies: ["CampPersistence", "CampCore"]),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"])
    ]
)
