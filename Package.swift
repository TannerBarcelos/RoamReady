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
        /// Rigs, trips, checklists, saved campgrounds, and the rules that govern them. Foundation only.
        .target(name: "CampCore"),
        /// Federal campground snapshot, site shards, filters, and the future provider-proxy client.
        .target(name: "Campgrounds", dependencies: ["CampCore"]),
        /// Document types, policy, the repository contract, SHA-256 digests, and the chunk cipher.
        .target(name: "DocumentVault", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
        ]),
        /// Core Data + CloudKit mirroring. The record projection is portable; the store is Apple-only.
        .target(name: "CampPersistence", dependencies: ["CampCore", "DocumentVault"]),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"]),
        .testTarget(name: "CampgroundsTests", dependencies: ["Campgrounds", "CampCore"]),
        .testTarget(name: "DocumentVaultTests", dependencies: ["DocumentVault"]),
        .testTarget(name: "CampPersistenceTests", dependencies: ["CampPersistence", "CampCore", "DocumentVault"])
    ]
)
