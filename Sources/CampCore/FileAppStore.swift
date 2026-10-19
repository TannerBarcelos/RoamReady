import Foundation

/// Serializes access to a single local store. Keep one instance per store directory.
/// A missing file is a first launch; an unreadable or invalid file is always an error.
public actor FileAppStore {
    public static let schemaVersion = 1
    public nonisolated let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("camp-state.json", isDirectory: false)
    }

    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppState() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header = try decoder.decode(Header.self, from: data)
        switch header.schemaVersion {
        case Self.schemaVersion:
            return try decoder.decode(Envelope.self, from: data).state.validated()
        case 0:
            // Prototype v0 stored the state fields at the top level. Migration is
            // in-memory; the existing file is only replaced on an explicit save.
            let legacy = try decoder.decode(LegacyEnvelope.self, from: data)
            return try AppState(profile: legacy.profile, trips: legacy.trips, templates: legacy.templates).validated()
        default:
            throw CampError.unsupportedSchema(header.schemaVersion)
        }
    }

    public func save(_ state: AppState) throws {
        _ = try state.validated()
        // Do not replace an unreadable, corrupted, or newer-version archive with
        // an empty/default state if the caller previously encountered a load error.
        if FileManager.default.fileExists(atPath: fileURL.path) { _ = try load() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, state: state))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Foundation writes a temporary sibling and renames it over the destination.
        // Encoding, validation, directory, and disk errors all propagate to callers.
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Header: Decodable { let schemaVersion: Int }
    private struct Envelope: Codable { let schemaVersion: Int; let state: AppState }
    private struct LegacyEnvelope: Decodable {
        let schemaVersion: Int
        let profile: CamperProfile?
        let trips: [Trip]
        let templates: ChecklistTemplates?
    }
}
