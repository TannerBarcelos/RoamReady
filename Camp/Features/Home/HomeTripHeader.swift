import SwiftUI
import CampCore
import CampPersistence

/// The trip and its saved campsite photo stay together in Home's native navigation row.
struct HomeTripHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let trip: Trip

    var body: some View {
        Group {
            if trip.coverPhotoData == nil {
                details.frame(maxWidth: .infinity, alignment: .leading)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    photo.frame(height: 120)
                    details
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    details.frame(maxWidth: .infinity, alignment: .leading)
                    photo.frame(width: 88, height: 100)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.campgroundName)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(trip.dateSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !trip.siteNumber.isEmpty {
                Label("Site \(trip.siteNumber)", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            SaveStatus()
        }
    }

    private var photo: some View {
        Color.clear
            .overlay {
                if let data = trip.coverPhotoData {
                    LocalPhoto(data: data)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

struct HomeChecklistSummary: View {
    let phase: ChecklistPhase
    let steps: [ChecklistStep]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checklist")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(phase.title) checklist").font(.headline)
                ProgressSummary(steps: steps)
            }
        }
        .padding(.vertical, 6)
    }
}
