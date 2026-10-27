import SwiftUI
import CampCore
import CampPersistence

extension TripDetails {
    var dateSummary: String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = planningTimeZone
        return arrival.formatted(style) + " – " + departure.formatted(style)
    }
}

/// A photo from the library, decoded as a bounded thumbnail off the main thread.
struct LocalPhoto: View {
    let data: Data?
    var maximumDimension = 512
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill).overlay {
                    VStack {
                        Image(systemName: data == nil ? "icloud.and.arrow.down" : "photo")
                        if data == nil { Text("Not on this device yet").font(.caption2) }
                    }.foregroundStyle(.secondary)
                }.accessibilityLabel(data == nil ? "Photo not downloaded yet" : "Loading photo")
            }
        }
        .task(id: data) {
            guard let data, let jpeg = await PhotoImport.thumbnail(data, maximumDimension: maximumDimension) else { thumbnail = nil; return }
            thumbnail = UIImage(data: jpeg)
        }
    }
}

struct RigImage: View {
    let type: RigType
    let emoji: String
    let photo: Data?
    var size: CGFloat = 64
    init(rig: Rig, size: CGFloat = 64) { self.init(type: rig.type, emoji: rig.emoji, photo: rig.photoData, size: size) }
    init(type: RigType, emoji: String, photo: Data?, size: CGFloat = 64) {
        self.type = type; self.emoji = emoji; self.photo = photo; self.size = size
    }
    var body: some View {
        Group {
            if photo != nil {
                LocalPhoto(data: photo, maximumDimension: 256)
            } else {
                ZStack {
                    Color(.tertiarySystemGroupedBackground)
                    Text(emoji.isEmpty ? type.defaultEmoji : emoji).font(.system(size: size * 0.55))
                }
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Your \(type.title.lowercased())")
    }
}

struct SaveStatus: View {
    @Environment(LibraryController.self) private var library
    var body: some View {
        Label(library.saveFailure == nil ? "Saved on this device" : "Changes need saving",
              systemImage: library.saveFailure == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(library.saveFailure == nil ? Color.secondary : .orange)
            .accessibilityIdentifier("localSaveStatus")
    }
}

struct ProgressSummary: View {
    let steps: [ChecklistStep]
    var finished: Int { steps.filter(\.isFinished).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(finished) of \(steps.count) finished").font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: Double(finished), total: Double(max(1, steps.count)))
                .accessibilityLabel("Checklist progress")
            let skipped = steps.filter { $0.status == .skipped }.count
            if skipped > 0 { Text("Includes \(skipped) skipped").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
