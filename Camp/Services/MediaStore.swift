import Foundation
import UIKit
import ImageIO

struct MediaStore: Sendable {
    let directory: URL

    func url(for filename: String) -> URL? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."), !filename.contains("/"), filename.hasSuffix(".jpg") else { return nil }
        return directory.appendingPathComponent(filename)
    }

    /// Decode a bounded thumbnail rather than expanding a full-resolution camera image.
    func importPhoto(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2560,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary),
                  let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
                throw CampUIError.unreadablePhoto
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = UUID().uuidString + ".jpg"
            try encoded.write(to: directory.appendingPathComponent(filename),
                              options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return filename
        }.value
    }
}
