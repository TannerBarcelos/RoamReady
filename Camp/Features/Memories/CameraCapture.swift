import SwiftUI
import UIKit
import AVFoundation

enum CameraCaptureError: LocalizedError {
    case unavailable, permissionDenied, unreadableImage

    var errorDescription: String? {
        switch self {
        case .unavailable: "A camera isn’t available on this device. You can add a photo from your library instead."
        case .permissionDenied: "Allow camera access in Settings to take a photo. You can still add photos from your library."
        case .unreadableImage: "This photo couldn’t be saved. Please take it again."
        }
    }
}

@MainActor
enum CameraAccess {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    static func request() async throws {
        guard isAvailable else { throw CameraCaptureError.unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraCaptureError.permissionDenied }
        default: throw CameraCaptureError.permissionDenied
        }
    }
}

/// Presents Apple's camera after permission is granted. No network or photo-library permission is needed.
/// A nil result means the user cancelled; captured bytes enter the same local import path as library photos.
@MainActor
struct CameraCapture: UIViewControllerRepresentable {
    let completion: (Result<Data, CameraCaptureError>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let completion: (Result<Data, CameraCaptureError>?) -> Void
        private var completed = false

        init(completion: @escaping (Result<Data, CameraCaptureError>?) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.95) else {
                finish(.failure(.unreadableImage)); return
            }
            finish(.success(data))
        }

        private func finish(_ result: Result<Data, CameraCaptureError>?) {
            guard !completed else { return }
            completed = true
            completion(result)
        }
    }
}
