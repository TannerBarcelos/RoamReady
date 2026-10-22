import SwiftUI
import CampCore
import UIKit

extension Trip {
    var planningTimeZone: TimeZone { planningTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    var dateSummary: String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = planningTimeZone
        return arrival.formatted(style) + " – " + departure.formatted(style)
    }
    var setupFinished: Int { setup.filter(\.isFinished).count }
    var teardownFinished: Int { teardown.filter(\.isFinished).count }
}

struct RigImage: View {
    @Environment(CampStore.self) private var store
    let rig: Rig
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let filename = rig.photoFilename {
                LocalPhoto(filename: filename, maximumDimension: 256)
            } else {
                ZStack {
                    Color(.tertiarySystemGroupedBackground)
                    Text(rig.emoji.isEmpty ? rig.type.defaultEmoji : rig.emoji).font(.system(size: size * 0.55))
                }
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Your \(rig.type.title.lowercased())")
    }
}

struct SaveStatus: View {
    @Environment(CampStore.self) private var store
    var body: some View {
        Label {
            Text(store.isSaving ? "Saving on this iPhone…" : store.saveFailure == nil ? "Saved on this iPhone" : "Changes need saving")
        } icon: {
            Image(systemName: store.isSaving ? "arrow.trianglehead.2.clockwise" : store.saveFailure == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .font(.caption).foregroundStyle(store.saveFailure == nil ? Color.secondary : .orange)
        .accessibilityIdentifier("localSaveStatus")
    }
}

struct ProgressSummary: View {
    let items: [ChecklistItem]
    var finished: Int { items.filter(\.isFinished).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(finished) of \(items.count) finished").font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: Double(finished), total: Double(max(1, items.count)))
                .accessibilityLabel("Checklist progress")
            let skipped = items.filter { $0.status == .skipped }.count
            if skipped > 0 { Text("Includes \(skipped) skipped").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
