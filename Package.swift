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
    targets: [
        /// The rig and trip rules shared by the models and the forms' drafts, checklists, and policies. Foundation only.
        .target(name: "CampCore"),
        /// Camp Finder: the Apple Maps place model, links, and result merging. Foundation only.
        .target(name: "Campgrounds", dependencies: ["CampCore"]),
        /// Document types and import policy, SHA-256 digests, and AES-GCM sealing.
        .target(name: "DocumentVault"),
        /// The SwiftData models, CloudKit mirroring, library rules, and export. Apple-only.
        .target(name: "CampPersistence", dependencies: ["CampCore", "DocumentVault"]),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"]),
        .testTarget(name: "CampgroundsTests", dependencies: ["Campgrounds", "CampCore"]),
        .testTarget(name: "DocumentVaultTests", dependencies: ["DocumentVault"]),
        .testTarget(name: "CampPersistenceTests", dependencies: ["CampPersistence", "CampCore", "DocumentVault"])
    ]
)
