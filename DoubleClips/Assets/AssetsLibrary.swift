import Foundation
import AVFoundation
import CoreText
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - What a downloaded asset becomes
//
//   effect  -> installed (Application Support/assets/effects/<id>.json) and registered at every launch, like a built-in effect style
//   pack    -> an animation pack, through the same strict installer as Settings > Animation packs
//   font    -> copied into a project's Fonts folder (registered, listed by the text editor)
//   video / image / audio -> copied into a project's Clips folder (Project Files)
//
// Everything downloaded is untrusted: effects and packs go through their normal parsers (which validate everything and register nothing when
// a file is bad), fonts through the font check, and nothing is run.

struct AssetInstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AssetLibrary {

    private static var effectsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("assets", isDirectory: true).appendingPathComponent("effects", isDirectory: true)
    }

    /// Installs a downloaded effect style; returns its name.
    static func installEffect(from file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        guard data.count <= 256 * 1024 else { throw AssetInstallError(L("This effect file is too big.")) }
        guard let text = String(data: data, encoding: .utf8) else { throw AssetInstallError(L("This isn't an effect file.")) }
        let style = try EffectStyleLoader.parse(text, source: "community asset")
        let target = effectsDirectory.appendingPathComponent("\(style.id).json")
        // An id that is a built-in effect (or came from somewhere else) is never replaced by a download.
        if EffectStyleLoader.get(style.id) != nil, !FileManager.default.fileExists(atPath: target.path) {
            throw AssetInstallError(L("An effect with this id already exists."))
        }
        try FileManager.default.createDirectory(at: effectsDirectory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try EffectStyleLoader.register(text, source: "community asset")
        return style.name
    }

    /// Registers the installed effects (called once the built-in ones are loaded). Returns one line per bad file.
    @discardableResult
    static func loadInstalledEffects() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: effectsDirectory.path) else { return [] }
        var problems: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            do {
                let text = try String(contentsOf: effectsDirectory.appendingPathComponent(name), encoding: .utf8)
                try EffectStyleLoader.register(text, source: "community asset")
            } catch {
                problems.append("installed effect \(name): \(error.localizedDescription)")
            }
        }
        return problems
    }

    /// Installs an animation pack (zip); returns its name.
    static func installPack(from file: URL) throws -> String {
        try ClipAnimationStore.importPack(from: file).pack.name
    }

    /// Copies the file into the project: fonts into Fonts (and registers them), media into Clips. Returns what to tell the user.
    static func add(_ file: URL, kind: AssetKind, to project: ProjectData) throws -> String {
        switch kind {
        case .font:
            let faces = try ProjectFonts.importFont(from: file, projectPath: project.projectPath)
            return faces.first?.title ?? file.lastPathComponent
        case .video, .image, .audio:
            let dir = IOHelper.combinePath(project.projectPath, Constants.DEFAULT_CLIP_DIRECTORY)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let base = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
            var name = file.lastPathComponent
            var n = 1
            while FileManager.default.fileExists(atPath: IOHelper.combinePath(dir, name)) {
                name = "\(base) (\(n)).\(ext)"
                n += 1
            }
            try FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: IOHelper.combinePath(dir, name)))
            return name
        case .effect, .pack:
            throw AssetInstallError(L("This kind is installed in the app, not added to a project."))
        }
    }

    /// Every project on this phone, newest first (what the project picker lists).
    static func projects() -> [ProjectData] {
        IOHelper.createEmptyDirectories(Constants.DEFAULT_PROJECT_DIRECTORY)
        var list: [ProjectData] = []
        for dir in IOHelper.listFiles(Constants.DEFAULT_PROJECT_DIRECTORY, options: .directories) {
            if let data = ProjectData.loadProperties(from: dir.path) { list.append(data) }
        }
        return list.sorted { $0.projectTimestamp > $1.projectTimestamp }
    }
}

// MARK: - The small preview picture sent with a post

/// A JPEG of at most 200 KB that stands for the asset in the tab: the image itself, a frame of a video, a sample line in a font.
/// Nil for kinds without a picture (the tab then shows the kind's icon).
enum AssetPreviewMaker {
    static let maxBytes = 200_000

    static func jpeg(for file: URL, kind: AssetKind) async -> Data? {
        switch kind {
        case .image: return encode(downsample(file, edge: 640))
        case .video: return encode(await videoFrame(file))
        case .font: return encode(fontSample(file))
        case .audio, .effect, .pack: return nil
        }
    }

    /// A picture the user picked (from Photos), shrunk to fit.
    static func jpeg(from image: UIImage) -> Data? { encode(image.cgImage.map { shrink($0, edge: 640) } ?? nil) }

    private static func downsample(_ url: URL, edge: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ] as CFDictionary)
    }

    private static func shrink(_ image: CGImage, edge: CGFloat) -> CGImage? {
        let scale = min(1, edge / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let at = CMTime(seconds: seconds.isFinite && seconds > 0 ? min(1, seconds / 10) : 0, preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }

    /// "Aa Bb Cc / 0123456789" in the font on a plain card.
    private static func fontSample(_ url: URL) -> CGImage? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first else { return nil }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)      // "already registered" is fine
        error?.release()
        guard let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else { return nil }
        let size = CGSize(width: 640, height: 360)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(white: 0.97, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let big = UIFont(name: name, size: 120) ?? .systemFont(ofSize: 120)
            let small = UIFont(name: name, size: 44) ?? .systemFont(ofSize: 44)
            ("Aa Bb" as NSString).draw(at: CGPoint(x: 36, y: 40), withAttributes: [.font: big, .foregroundColor: UIColor.black])
            ("0123456789 ABC xyz" as NSString).draw(at: CGPoint(x: 36, y: 240), withAttributes: [.font: small, .foregroundColor: UIColor.darkGray])
        }
        return image.cgImage
    }

    /// JPEG under the cap: quality steps down, then the picture gets smaller.
    private static func encode(_ image: CGImage?) -> Data? {
        guard var image else { return nil }
        for _ in 0..<4 {
            for quality in [0.82, 0.65, 0.5, 0.35] as [CGFloat] {
                let out = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), out.length <= maxBytes { return out as Data }
            }
            guard let smaller = shrink(image, edge: CGFloat(max(image.width, image.height)) * 0.7) else { return nil }
            image = smaller
        }
        return nil
    }
}
