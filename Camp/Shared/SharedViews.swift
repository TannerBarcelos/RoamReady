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
    var contentMode: ContentMode = .fill
    var allowsRetry = false
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    private struct LoadRequest: Equatable {
        let data: Data?
        let maximumDimension: Int
        let attempt: Int
    }

    var body: some View {
        // A stable container keeps the loading task alive when the placeholder becomes an image.
        ZStack {
            Color(.tertiarySystemFill)
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: contentMode)
                    .accessibilityLabel("Photo")
                    .accessibilityIdentifier("localPhotoImage")
            } else if data == nil {
                VStack {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("Not on this device yet").font(.caption2)
                }.foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Photo not downloaded yet")
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityLabel("Couldn’t load photo")
                        .accessibilityHidden(allowsRetry)
                    if allowsRetry {
                        Text("Couldn’t load photo").font(.callout)
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.tint)
                    }
                }.foregroundStyle(.secondary)
                    .accessibilityIdentifier("localPhotoFailure")
            } else {
                ProgressView().accessibilityLabel("Loading photo")
                    .accessibilityIdentifier("localPhotoLoading")
            }
        }
        .task(id: LoadRequest(data: data, maximumDimension: maximumDimension, attempt: attempt)) {
            thumbnail = nil
            failed = false
            guard let data else { return }
            let jpeg = await PhotoImport.thumbnail(data, maximumDimension: maximumDimension)
            // Downsampling runs detached; cancellation must be checked before updating a reused view.
            guard !Task.isCancelled else { return }
            thumbnail = jpeg.flatMap { UIImage(data: $0) }
            failed = thumbnail == nil
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
                    Canvas { context, canvasSize in
                        let symbol = Text(emoji.isEmpty ? type.defaultEmoji : emoji)
                            .font(.system(size: size * 0.55))
                        context.draw(symbol, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
                    }
                }
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 14))
        // Expose photos and emoji as one labeled thumbnail to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your \(type.title.lowercased())")
        .accessibilityAddTraits(.isImage)
    }
}

struct SaveStatus: View {
    @Environment(LibraryController.self) private var library
    var body: some View {
        if library.saveFailure != nil {
            Label("Changes need saving", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("localSaveStatus")
        }
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

/// Let list rows measure the full title at accessibility text sizes.
struct WrappingLabel: View {
    @ScaledMetric(relativeTo: .body) private var iconWidth = 28
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.body).foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}
