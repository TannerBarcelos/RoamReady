import Foundation

/// Everything the owner keeps: trips, rigs, default checklists, the profile, and saved campgrounds.
/// A value type, so the UI edits a copy and the store persists the difference.
public struct LibrarySnapshot: Equatable, Sendable {
    public var state: AppState
    /// Saved campgrounds by campground ID.
    public var saved: [String: SavedCampground]
    public init(state: AppState = AppState(), saved: [String: SavedCampground] = [:]) { self.state = state; self.saved = saved }
}

public enum LibraryError: Error, LocalizedError {
    case invalidRecord, incompleteLibrary, missingAsset
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "A saved or synced record has an unsupported or invalid format. Update RoamReady before trying again."
        case .incompleteLibrary: "Some related records have not arrived yet. Your saved records are preserved."
        case .missingAsset: "The photo has not downloaded to this device yet."
        }
    }
}
