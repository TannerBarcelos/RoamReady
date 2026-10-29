// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CampCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CampCore", targets: ["CampCore"]),
        .library(name: "Campgrounds", targets: ["Campgrounds"]),
        .library(name: "DocumentVault", targets: ["DocumentVault"]),
        .library(name: "CampPersistence", targets: ["CampPersistence"]),
        .library(name: "DocumentSearch", targets: ["DocumentSearch"]),
        .executable(name: "assistant-eval", targets: ["assistant-eval"])
    ],
    targets: [
        /// The rig and trip rules shared by the models and the forms' drafts, checklists, and policies. Foundation only.
        .target(name: "CampCore"),
        /// Camp Finder: the Apple Maps place model, links, and result merging. Foundation only.
        .target(name: "Campgrounds", dependencies: ["CampCore"]),
        /// Document types and import policy, SHA-256 digests, and AES-GCM sealing.
        .target(name: "DocumentVault"),
        /// The SwiftData models, CloudKit mirroring, library rules, and export.
        .target(name: "CampPersistence", dependencies: ["CampCore", "DocumentVault"]),
        /// The vendored sqlite-vec amalgamation (see PROVENANCE.md), built against the system SQLite.
        .target(
            name: "CSQLiteVec",
            exclude: ["PROVENANCE.md", "LICENSE-MIT", "LICENSE-APACHE", "sqlite-vec.h"],
            cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        /// The document Assistant's search index: its own disposable SQLite file with FTS5 and sqlite-vec.
        .target(name: "DocumentSearch", dependencies: ["CSQLiteVec", "CampCore"]),
        /// The Assistant's retrieval eval: a versioned synthetic corpus, the runner, and JSON and Markdown reports.
        .target(name: "AssistantEval", dependencies: ["DocumentSearch", "CampCore"], resources: [.copy("Corpus")]),
        /// The manual command for the same eval with Apple's embeddings. Reports "not run" when they're unavailable.
        .executableTarget(name: "assistant-eval", dependencies: ["AssistantEval", "DocumentSearch"]),
        .testTarget(name: "CampCoreTests", dependencies: ["CampCore"]),
        .testTarget(name: "CampgroundsTests", dependencies: ["Campgrounds", "CampCore"]),
        .testTarget(name: "DocumentVaultTests", dependencies: ["DocumentVault"]),
        .testTarget(name: "DocumentSearchTests", dependencies: ["DocumentSearch", "CampCore"]),
        /// Synthetic retrieval eval cases: search, relevance, and evidence validation together. No private documents.
        .testTarget(name: "DocumentAssistantEvalTests", dependencies: ["DocumentSearch", "CampCore", "AssistantEval"]),
        .testTarget(name: "CampPersistenceTests", dependencies: ["CampPersistence", "CampCore", "DocumentVault"])
    ]
)
