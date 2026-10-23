import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image thumbnails, like the web Drive: the server has no thumbnail endpoint, so a thumbnail is the image itself loaded
/// inline. Every first load therefore spends the daily download allowance, so each one is shrunk and kept on disk
/// (Caches/VanVatDrive/thumbs): it is only ever downloaded once. Sign-out deletes the cache folder.
extension DriveClient {
    /// Bigger originals show their icon instead: loading them just for a thumbnail would eat the allowance.
    public static let thumbnailMaxSourceBytes: Int64 = 8 * 1024 * 1024
    private static let thumbnailEdge: CGFloat = 256
    private static let thumbnailExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"]

    public static func hasThumbnail(_ node: DriveNode) -> Bool {
        !node.isFolder && node.size > 0 && node.size <= thumbnailMaxSourceBytes
            && thumbnailExtensions.contains((node.name as NSString).pathExtension.lowercased())
    }

    /// JPEG data of the thumbnail (nil when the node is not a usable image). Throws when the server refuses, e.g. 429
    /// when today's download allowance is used up: the caller keeps the icon.
    public func thumbnailData(for node: DriveNode) async throws -> Data? {
        guard Self.hasThumbnail(node) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VanVatDrive", isDirectory: true).appendingPathComponent("thumbs", isDirectory: true)
        let file = dir.appendingPathComponent("\(node.id).jpg")
        if let cached = try? Data(contentsOf: file) { return cached }

        let req = try makeRequest("GET", "/files/\(node.id)/content", query: ["inline": "1"])
        let (tmp, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try check(response, nil)

        guard let jpeg = Self.downsample(tmp) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpeg.write(to: file, options: .atomic)
        return jpeg
    }

    private static func downsample(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,          // respect EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
