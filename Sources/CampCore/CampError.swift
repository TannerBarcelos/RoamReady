import Foundation

public enum CampError: Error, LocalizedError, Equatable, Sendable {
    case missingCampground, invalidDates, invalidCoordinates, emptyChecklistTitle
    case unsupportedSchema(Int), incompleteRig, invalidRigDetails, invalidVIN, invalidPlate
    case invalidBookingLink, invalidCheckTimes, invalidBookingAmount, invalidSiteLength
    case rigLimitReached, rigInUse, rigArchived, rigUnavailable
    case missingDishName, missingItemName, missingMealName, mealUnavailable
    public var errorDescription: String? {
        switch self {
        case .missingCampground: "Enter a campground or destination name."
        case .invalidDates: "Departure must be on or after arrival."
        case .invalidCoordinates: "The campground coordinates are invalid."
        case .emptyChecklistTitle: "Every checklist step needs a title."
        case .unsupportedSchema(let version): "This data uses an unsupported format (version \(version)). Update the app before opening it."
        case .incompleteRig: "Enter your rig’s year, make, model, and length."
        case .invalidRigDetails: "Check your rig details. Year, length, slides, or axles are outside the supported range."
        case .invalidVIN: "Check the VIN. It’s 17 letters and numbers, without I, O, or Q."
        case .invalidPlate: "Check the license plate. It can be up to \(RigDraft.maxPlateLength) characters."
        case .invalidBookingLink: "The booking link must be a secure web address starting with https://."
        case .invalidCheckTimes: "Check-out must be after check-in."
        case .invalidBookingAmount: "Costs must be zero or more."
        case .invalidSiteLength: "Enter the site’s length limit in feet, between 1 and 200."
        case .rigLimitReached: RigPolicy.maxActiveRigs == 1
            ? "You already have an active rig. Replace or archive it first."
            : "You already have \(RigPolicy.maxActiveRigs) active rigs. Archive one first."
        case .rigInUse: "Trips use this rig, so it can't be deleted. Archive it instead; past trips keep showing it."
        case .rigArchived: "Archived rigs can't be used for new trips."
        case .rigUnavailable: "This trip's rig isn't available on this device yet."
        case .missingDishName: "Enter a name for this dish."
        case .missingItemName: "Enter a name for this item."
        case .missingMealName: "Enter a name for this meal."
        case .mealUnavailable: "This meal isn’t on the trip anymore. It may have been removed on another device."
        }
    }
}
