import Foundation

public enum CampError: Error, LocalizedError, Equatable, Sendable {
    case missingCampground, invalidDates, invalidCoordinates, duplicateIdentifiers, emptyChecklistTitle
    case invalidPhotoFilename, unsupportedSchema(Int), incompleteRig, invalidRigDetails
    case invalidBookingLink, invalidCheckTimes, invalidBookingAmount
    case rigLimitReached, rigInUse, rigNotFound, rigArchived
    public var errorDescription: String? {
        switch self {
        case .missingCampground: "Enter a campground or destination name."
        case .invalidDates: "Departure must be on or after arrival."
        case .invalidCoordinates: "The campground coordinates are invalid."
        case .duplicateIdentifiers: "The saved data contains duplicate identifiers. Your existing file was not changed."
        case .emptyChecklistTitle: "Every checklist step needs a title."
        case .invalidPhotoFilename: "A photo reference is invalid. Your existing file was not changed."
        case .unsupportedSchema(let version): "This data uses an unsupported format (version \(version)). Update the app before opening it."
        case .incompleteRig: "Enter your rig’s year, make, model, and length."
        case .invalidRigDetails: "Check your rig details. Year, length, slides, or axles are outside the supported range."
        case .invalidBookingLink: "The booking link must be a secure web address starting with https://."
        case .invalidCheckTimes: "Check-out must be after check-in."
        case .invalidBookingAmount: "Costs must be zero or more."
        case .rigLimitReached: RigPolicy.maxActiveRigs == 1
            ? "You already have an active rig. Replace or archive it first."
            : "You already have \(RigPolicy.maxActiveRigs) active rigs. Archive one first."
        case .rigInUse: "Trips use this rig, so it can't be deleted. Archive it instead; past trips keep showing it."
        case .rigNotFound: "That rig is no longer available."
        case .rigArchived: "Archived rigs can't be used for new trips."
        }
    }
}
