import XCTest
@testable import CampCore

final class RigDraftTests: XCTestCase {
    func testRVsRequireYearMakeModelAndLengthButTentsDoNot() throws {
        var rig = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries NB19.5", year: 2024)
        XCTAssertThrowsError(try rig.validateDetails()) { XCTAssertEqual($0 as? CampError, .incompleteRig) }
        rig.lengthFeet = 23.5
        XCTAssertNoThrow(try rig.validateDetails())
        rig.model = "   "
        XCTAssertFalse(rig.hasRequiredDetails)
        XCTAssertTrue(RigDraft(type: .tent, equipment: .none).hasRequiredDetails)
        XCTAssertTrue(RigDraft(type: .carCamping, equipment: .none).hasRequiredDetails)
    }

    func testRigDetailRangesAreEnforcedOnSave() {
        let valid = RigDraft(type: .fifthWheel, make: "Jayco", model: "Eagle", year: 2025, lengthFeet: 38, slideCount: 4, axleCount: 2, hasBunkhouse: true)
        XCTAssertNoThrow(try valid.validateDetails())
        var none = valid; none.slideCount = 0
        XCTAssertNoThrow(try none.validateDetails(), "0 records an explicit 'no slide-outs'")
        func changed(_ change: (inout RigDraft) -> Void) -> RigDraft { var rig = valid; change(&rig); return rig }
        for broken in [changed { $0.year = 1800 }, changed { $0.lengthFeet = 0 }, changed { $0.lengthFeet = .infinity },
                       changed { $0.slideCount = -1 }, changed { $0.slideCount = 9 }, changed { $0.axleCount = 0 }, changed { $0.axleCount = 9 }] {
            XCTAssertThrowsError(try broken.validateDetails()) { XCTAssertEqual($0 as? CampError, .invalidRigDetails) }
        }
    }

    func testDetailSummaryListsOnlyEnteredFacts() {
        XCTAssertEqual(RigDraft(year: 2024, lengthFeet: 19.5, slideCount: 1, axleCount: 1, hasBunkhouse: true).detailSummary,
                       "2024 · 19.5 ft · 1 slide · 1 axle · Bunkhouse")
        XCTAssertEqual(RigDraft(lengthFeet: 38, slideCount: 3, axleCount: 2, hasBunkhouse: false).detailSummary, "38 ft · 3 slides · 2 axles")
        XCTAssertEqual(RigDraft().detailSummary, "")
        XCTAssertEqual(RigDraft(make: "Jayco", model: "Eagle").displayName, "Jayco Eagle")
        XCTAssertEqual(RigDraft(type: .tent).displayName, "Tent")
    }

    func testBlankFormHidesTheErrorUntilTheOwnerStartsTyping() {
        var rig = RigDraft(type: .fifthWheel)
        XCTAssertNil(rig.visibleDetailsProblem)
        XCTAssertEqual(rig.detailsProblem, CampError.incompleteRig.errorDescription)
        rig.make = "Jayco"
        XCTAssertEqual(rig.visibleDetailsProblem, CampError.incompleteRig.errorDescription)
        rig.model = "Eagle"; rig.year = 1800; rig.lengthFeet = 38
        XCTAssertEqual(rig.visibleDetailsProblem, CampError.invalidRigDetails.errorDescription)
        rig.year = 2025
        XCTAssertNil(rig.visibleDetailsProblem)
    }

    func testSlideCountDrivesSlideOutStepsOnlyWhenSpecified() {
        var rig = RigDraft(type: .travelTrailer, equipment: Equipment(slideOuts: true))
        rig.setSlideCount(nil)
        XCTAssertTrue(rig.equipment.slideOuts, "Not specified leaves an existing answer alone")
        rig.setSlideCount(0)
        XCTAssertFalse(rig.equipment.slideOuts)
        XCTAssertFalse(ChecklistFactory.template(for: rig).setup.contains { $0.title == "Prepare and extend slides" })
        rig.setSlideCount(2)
        XCTAssertEqual(rig.slideCount, 2); XCTAssertTrue(rig.equipment.slideOuts)
        XCTAssertTrue(ChecklistFactory.template(for: rig).setup.contains { $0.title == "Prepare and extend slides" })
    }

    func testChangingRigTypeClearsTypeSpecificDetailsButKeepsThePhoto() {
        var rig = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, floorplan: "NB19.5",
                           emoji: "🏕️", photo: Data([1, 2, 3]), equipment: Equipment(slideOuts: true),
                           lengthFeet: 19.5, slideCount: 1, axleCount: 1, hasBunkhouse: true)
        rig.type = .tent
        rig.resetDetailsForType()
        XCTAssertEqual(rig.make, ""); XCTAssertEqual(rig.model, ""); XCTAssertEqual(rig.floorplan, "")
        XCTAssertNil(rig.year); XCTAssertNil(rig.lengthFeet); XCTAssertNil(rig.slideCount)
        XCTAssertNil(rig.axleCount); XCTAssertNil(rig.hasBunkhouse)
        XCTAssertEqual(rig.equipment, .none); XCTAssertEqual(rig.emoji, RigType.tent.defaultEmoji)
        XCTAssertEqual(rig.photo, Data([1, 2, 3]))
        rig.type = .motorhome
        rig.resetDetailsForType()
        XCTAssertEqual(rig.equipment, Equipment())
    }

    func testVINIsOptionalNormalizedAndValidatedWhenEntered() {
        var rig = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)
        XCTAssertNoThrow(try rig.validateDetails(), "A VIN is optional")
        rig.vin = " 1hgcm-826 33a004352 "
        XCTAssertEqual(RigDraft.normalizedVIN(rig.vin), "1HGCM82633A004352")
        XCTAssertNoThrow(try rig.validateDetails(), "Spaces, dashes, and lowercase are normalized before checking")
        XCTAssertEqual(rig.normalized.vin, "1HGCM82633A004352")
        for bad in ["1HGCM82633A00435", "1HGCM82633A0043521", "1HGCM82633A00435O", "1HGCM82633A00435I", "1HGCM82633A00435Q", "1HGCM82633A00435*"] {
            rig.vin = bad
            XCTAssertThrowsError(try rig.validateDetails(), bad) { XCTAssertEqual($0 as? CampError, .invalidVIN) }
        }
        rig.vin = "Ö1HGCM82633A00435"
        XCTAssertEqual(rig.registrationProblem, CampError.invalidVIN.errorDescription, "Non-ASCII characters are rejected")
    }

    func testPre1981RigsAcceptShorterSerialsAsTheirVIN() {
        let vintage = RigDraft(type: .travelTrailer, make: "Airstream", model: "Bambi", year: 1964, lengthFeet: 16, vin: "164B1234")
        XCTAssertNoThrow(try vintage.validateDetails())
        var modern = vintage; modern.year = 1981
        XCTAssertThrowsError(try modern.validateDetails()) { XCTAssertEqual($0 as? CampError, .invalidVIN) }
        var noYear = RigDraft(type: .carCamping, equipment: .none, vin: "164B1234")
        XCTAssertEqual(noYear.registrationProblem, CampError.invalidVIN.errorDescription, "Without a year, the standard VIN applies")
        noYear.vin = "1HGCM82633A004352"
        XCTAssertNil(noYear.registrationProblem)
    }

    func testPlateIsNormalizedAndLimitedInLength() {
        var rig = RigDraft(type: .camperVan, make: "Winnebago", model: "Solis", year: 2023, lengthFeet: 21,
                           licensePlate: "  8abc   123 ", plateRegion: "  CA ")
        XCTAssertNoThrow(try rig.validateDetails())
        XCTAssertEqual(rig.normalized.licensePlate, "8ABC 123")
        XCTAssertEqual(rig.normalized.plateRegion, "CA")
        XCTAssertEqual(rig.normalized.plateSummary, "8ABC 123 · CA")
        XCTAssertEqual(RigDraft(plateRegion: "CA").plateSummary, "CA")
        XCTAssertEqual(RigDraft().plateSummary, "")
        rig.licensePlate = String(repeating: "A", count: RigDraft.maxPlateLength)
        XCTAssertNoThrow(try rig.validateDetails())
        rig.licensePlate += "A"
        XCTAssertThrowsError(try rig.validateDetails()) { XCTAssertEqual($0 as? CampError, .invalidPlate) }
    }

    func testOnlyARegistrationProblemIsReportedAsOne() {
        var rig = RigDraft(type: .fifthWheel, vin: "TOO SHORT")
        XCTAssertEqual(rig.detailsProblem, CampError.incompleteRig.errorDescription, "Missing required details come first")
        XCTAssertEqual(rig.registrationProblem, CampError.invalidVIN.errorDescription)
        XCTAssertNotNil(rig.visibleDetailsProblem, "Typing a VIN counts as starting the form")
        rig.make = "Jayco"; rig.model = "Eagle"; rig.year = 2025; rig.lengthFeet = 38
        XCTAssertEqual(rig.detailsProblem, rig.registrationProblem)
        XCTAssertFalse(rig.hasRequiredDetails, "An invalid VIN blocks saving")
        let car = RigDraft(type: .carCamping, equipment: .none, licensePlate: "ABC123")
        XCTAssertTrue(car.hasStartedDetails && car.hasRequiredDetails)
    }

    func testTentsHaveNoRegistrationAndChangingTypeClearsIt() {
        XCTAssertFalse(RigType.tent.hasRegistration)
        XCTAssertTrue(RigType.allCases.filter { $0 != .tent }.allSatisfy(\.hasRegistration))
        var rig = RigDraft(type: .travelTrailer, vin: "1HGCM82633A004352", licensePlate: "ABC123", plateRegion: "OR")
        rig.type = .motorhome
        rig.resetDetailsForType()
        XCTAssertEqual(rig.vin, ""); XCTAssertEqual(rig.licensePlate, ""); XCTAssertEqual(rig.plateRegion, "")
        let tent = RigDraft(type: .tent, equipment: .none, vin: "1HGCM82633A004352", licensePlate: "ABC123", plateRegion: "OR").normalized
        XCTAssertEqual(tent.vin, ""); XCTAssertEqual(tent.licensePlate, ""); XCTAssertEqual(tent.plateRegion, "")
    }

    func testExportedRigIncludesRegistrationButNotThePhoto() throws {
        let rig = RigDraft(type: .camperVan, photo: Data([1, 2, 3]), vin: "1HGCM82633A004352", licensePlate: "ABC123", plateRegion: "OR")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(rig), encoding: .utf8))
        for key in ["\"vin\"", "\"licensePlate\"", "\"plateRegion\"", "1HGCM82633A004352"] { XCTAssertTrue(json.contains(key), key) }
        XCTAssertFalse(json.contains("\"photo\""))
    }

    func testYearAndLengthTextParsing() {
        XCTAssertEqual(RigDraft.parseYear("2024"), 2024)
        XCTAssertEqual(RigDraft.parseYear(" 20a24 "), 2024)
        XCTAssertEqual(RigDraft.parseYear("202456"), 2024)
        XCTAssertNil(RigDraft.parseYear(""))
        XCTAssertNil(RigDraft.parseYear("٢٠٢٤"), "Non-ASCII digits are rejected")
        XCTAssertEqual(RigDraft.parseLength("19.5"), 19.5)
        XCTAssertEqual(RigDraft.parseLength(" 23,5 "), 23.5)
        for bad in ["", "abc", "0", "-3", "inf", "nan", "1e999"] { XCTAssertNil(RigDraft.parseLength(bad), bad) }
        let rig = RigDraft(year: 2024, lengthFeet: 19.5)
        XCTAssertEqual(rig.yearText, "2024"); XCTAssertEqual(rig.lengthText, "19.5")
        XCTAssertEqual(RigDraft.parseLength(rig.lengthText), rig.lengthFeet, "Displayed text parses back to the stored value")
        XCTAssertEqual(RigDraft().yearText, ""); XCTAssertEqual(RigDraft().lengthText, "")
    }

    func testRigEquipmentFiltersBothPhasesAndTentNeverGetsRVProcedures() {
        func titles(_ rig: RigDraft) -> String {
            let template = ChecklistFactory.template(for: rig)
            return (template.setup + template.teardown).map(\.title).joined(separator: " ").lowercased()
        }
        let bare = titles(RigDraft(type: .motorhome, equipment: .none))
        let equipped = titles(RigDraft(type: .travelTrailer, equipment: Equipment(slideOuts: true)))
        let tent = titles(RigDraft(type: .tent, equipment: Equipment(slideOuts: true)))
        for absent in ["shore power", "slides", "propane", "unhitch"] { XCTAssertFalse(bare.contains(absent), absent) }
        for present in ["shore power", "slides", "unhitch"] { XCTAssertTrue(equipped.contains(present), present) }
        XCTAssertTrue(tent.contains("tent"))
        for absent in ["hitch", "slides", "shore power", "leveling", "wastewater"] {
            XCTAssertFalse(tent.contains(absent), "Tent contains RV instruction: \(absent)")
        }
        let car = ChecklistFactory.template(for: RigDraft(type: .carCamping))
        XCTAssertFalse(car.setup.contains { $0.title == "Pitch and secure your tent" })
        XCTAssertTrue(car.setup.contains { $0.title == "Prepare your sleeping space" })
        XCTAssertTrue((car.setup + car.teardown).allSatisfy { $0.status == .pending && $0.hasTitle })
    }
}
