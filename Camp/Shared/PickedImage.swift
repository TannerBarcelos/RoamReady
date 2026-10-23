import CoreTransferable
import UniformTypeIdentifiers
import DocumentVault

/// Photos grants a temporary file URL. Own a bounded copy before the transfer callback returns.
struct PickedImage: Transferable, Sendable {
    let file: ImportFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImage(file: try ImportFile(copying: received.file, maximumByteCount: DocumentPolicy.maximumByteCount))
        }
    }
}
