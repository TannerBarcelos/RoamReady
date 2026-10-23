import Foundation
import ImageIO
import UIKit
import PhotosUI

/// Photos are stored in the library as resized JPEGs, so they sync with their trip or rig.
enum PhotoImport {
    /// Decode a thumbnail from the staged file, without loading the original into Data first.
    static func jpeg(from selection: PhotosPickerItem) async throws -> Data {
        guard let picked = try await selection.loadTransferable(type: PickedImage.self) else { throw CampUIError.unreadablePhoto }
        let jpeg = await Task.detached(priority: .userInitiated) {
            withExtendedLifetime(picked.file) {
                guard let source = CGImageSourceCreateWithURL(picked.file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2560,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return Data?.none }
                return UIImage(cgImage: image).jpegData(compressionQuality: 0.88)
            }
        }.value
        try Task.checkCancellation()
        guard let jpeg else { throw CampUIError.unreadablePhoto }
        return jpeg
    }

    /// A JPEG of at most 2560 pixels, decoded as a bounded thumbnail rather than at full resolution.
    static func jpeg(from data: Data) async throws -> Data {
        guard let jpeg = await thumbnail(data, maximumDimension: 2560, quality: 0.88) else { throw CampUIError.unreadablePhoto }
        return jpeg
    }

    /// A smaller JPEG for display. Only Sendable bytes cross the task boundary.
    static func thumbnail(_ data: Data, maximumDimension: Int, quality: CGFloat = 0.85) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: quality)
        }.value
    }

    /// A temporary file for sharing a photo.
    static func shareableFile(_ data: Data) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "RoamReady Photo.jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
