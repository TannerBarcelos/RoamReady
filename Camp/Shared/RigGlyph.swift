import SwiftUI
import CampCore

/// Inline rig artwork uses template assets so it scales with text and inherits the app tint.
struct RigGlyph: View {
    let type: RigType
    @ScaledMetric(relativeTo: .body) private var size = 24

    private var assetName: String {
        switch type {
        case .travelTrailer: "RigTravelTrailer"
        case .fifthWheel: "RigFifthWheel"
        case .motorhome: "RigMotorhome"
        case .camperVan: "RigCamperVan"
        case .truckCamper: "RigTruckCamper"
        case .popUp: "RigPopUpCamper"
        case .carCamping: "RigCarCamping"
        case .tent: "RigTent"
        }
    }

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }
}
