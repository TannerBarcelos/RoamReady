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
