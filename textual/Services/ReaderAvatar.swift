import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ReaderAvatarTransport: Sendable {
    func uploadAvatar(userID: UUID, path: String, data: Data) async throws
    func downloadAvatar(path: String) async throws -> Data
}

enum ReaderAvatar {
    static let bucket = "textual-avatars"
    static let maximumBytes = 2 * 1024 * 1024

    static func path(userID: UUID) -> String {
        "\(userID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
    }

    static func isValid(path: String, userID: UUID? = nil) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, let owner = UUID(uuidString: String(components[0])),
              components[1].hasSuffix(".jpg"),
              let photo = UUID(uuidString: String(components[1].dropLast(4))),
              path == "\(owner.uuidString.lowercased())/\(photo.uuidString.lowercased()).jpg" else { return false }
        return userID == nil || owner == userID
    }

    enum PhotoError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: "That photo couldn’t be opened. Try another one."
            case .tooLarge: "That photo is a little too big. Try one smaller than 25 MB."
            }
        }
    }
}

/// Decode away from the UI, resize, and write fresh pixels without EXIF/location metadata.
actor ReaderAvatarProcessor {
    static let shared = ReaderAvatarProcessor()

    func prepare(_ data: Data) throws -> Data {
        guard data.count <= 25 * 1024 * 1024 else { throw ReaderAvatar.PhotoError.tooLarge }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ReaderAvatar.PhotoError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ReaderAvatar.PhotoError.invalid
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= ReaderAvatar.maximumBytes else {
            throw ReaderAvatar.PhotoError.invalid
        }
        try Task.checkCancellation()
        return output as Data
    }
}
