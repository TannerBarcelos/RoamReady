import Foundation

public enum Experience: String, Codable, CaseIterable, Identifiable, Sendable {
    case new, comfortable, experienced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .new: "Just getting started"
        case .comfortable: "A few trips under my belt"
        case .experienced: "Experienced camper"
        }
    }
}

/// The owner's details. Rigs are separate records in `AppState.rigs`.
public struct CamperProfile: Codable, Equatable, Sendable {
    public var name: String
    public var experience: Experience
    public init(name: String = "", experience: Experience = .new) {
        self.name = name; self.experience = experience
    }
}
