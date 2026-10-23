// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CampCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CampCore", targets: ["CampCore"]),
        .library(name: "Campgrounds", targets: ["Campgrounds"]),
        .library(name: "DocumentVault", targets: ["DocumentVault"]),
        .library(name: "CampPersistence", targets: ["CampPersistence"])
    ],
    dependencies: [
        // Apple's open-source CryptoKit API, used only where CryptoKit itself is unavailable (Linux CI).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
    ],
    targets: [
        /// The rig and trip rules shared by the models and the forms' drafts, checklists, and policies. Foundation only.
        .target(name: "CampCore"),
        /// Camp Finder: the Apple Maps place model, links, and result merging. Foundation only, so it tests on Linux.
        .target(name: "Campgrounds", dependencies: ["CampCore"]),
        /// Document types and import policy, SHA-256 digests, and AES-GCM sealing.
        .target(name: "DocumentVault", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
        ]),
        /// The SwiftData models, CloudKit mirroring, library rules, and export. Apple-only.
        .target(name: "CampPersistence", dependencies: ["CampCore", "DocumentVault"]),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"]),
        .testTarget(name: "CampgroundsTests", dependencies: ["Campgrounds", "CampCore"]),
        .testTarget(name: "DocumentVaultTests", dependencies: ["DocumentVault"]),
        .testTarget(name: "CampPersistenceTests", dependencies: ["CampPersistence", "CampCore", "DocumentVault"])
    ]
)
