import Foundation
import AVFoundation
import UIKit
import ImageIO

// MARK: - Project library (the files in <project>/Clips)
//
// Android: ProjectFilesEditSpecificAreaScreen lists <project>/Clips, taps add the file to the
// selected track, long-press offers Rename / Delete / Swap (swap is only a TODO there), and a
// hex field creates a solid-colour image with ffmpeg.
//
// This file is the non-UI half on iOS: what kind of file something is, how to read its duration
// and size, and the file operations (import, rename, replace, delete, solid colour). Nothing here
// touches the timeline; EditingView+ProjectFiles.swift does that part, so a rename or delete
// always updates the clips that use the file in the same step.
//
// Proxies: Android keeps a preview proxy per clip in <project>/PreviewClips, named with the same
// base name as the clip file (clip.mp4 -> clip.mp4 / clip.wav ...). iOS doesn't create them, but
// projects that came from Android carry them, so rename/delete/replace keep them in step.

// MARK: Kinds

enum MediaKind: String {
    case video, image, audio, other
    
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "3g2", "mkv", "webm", "avi"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus"]
    
    init(pathExtension: String) {
        let ext = pathExtension.lowercased()
        if MediaKind.videoExtensions.contains(ext) { self = .video }
        else if MediaKind.imageExtensions.contains(ext) { self = .image }
        else if MediaKind.audioExtensions.contains(ext) { self = .audio }
        else { self = .other }
    }
    
    init(url: URL) { self.init(pathExtension: url.pathExtension) }
    
    var title: String {
        switch self {
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        case .other: return "File"
        }
    }
    
    var symbol: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .other: return "questionmark.square.dashed"
        }
    }
}

// MARK: Probing

struct MediaInfo {
    var kind: MediaKind
    var duration: Float       // seconds; 3 for still images (Android's default)
    var width: Int            // oriented size; 0 for audio
    var height: Int
    var hasAudio: Bool
}

enum MediaProbe {
    
    /// Reads kind, duration, oriented size and whether there is audio. Never throws: anything that
    /// can't be read falls back to the same defaults the importer always used (3 s, 1920x1080).
    static func probe(_ url: URL) async -> MediaInfo {
        var kind = MediaKind(url: url)
        
        if kind == .image {
            let size = imageSize(url)
            return MediaInfo(kind: .image, duration: 3, width: size.width, height: size.height, hasAudio: false)
        }
        
        let asset = AVURLAsset(url: url)
        var duration: Float = 3
        var width = 0, height = 0
        var hasVideo = false, hasAudio = false
        
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            duration = Float(d.seconds)
        }
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video), let track = videoTracks.first {
            hasVideo = true
            if let size = try? await track.load(.naturalSize) {
                // naturalSize ignores the rotation flag: a portrait iPhone video would be stored
                // sideways. Apply preferredTransform.
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let oriented = size.applying(transform)
                width = Int(abs(oriented.width))
                height = Int(abs(oriented.height))
            }
        }
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty {
            hasAudio = true
        }
        
        // Trust the content over the extension: an .mp4 that only holds audio is audio, and a
        // container with an unknown extension is whatever it actually contains.
        if kind == .other { kind = hasVideo ? .video : (hasAudio ? .audio : .other) }
        if kind == .video && !hasVideo && hasAudio { kind = .audio }
        
        if kind == .video && (width <= 0 || height <= 0) { width = 1920; height = 1080 }
        if kind == .audio { width = 0; height = 0; hasAudio = true }
        return MediaInfo(kind: kind, duration: duration, width: width, height: height, hasAudio: hasAudio)
    }
    
    /// Pixel size with the EXIF orientation applied (a portrait phone photo is stored landscape).
    static func imageSize(_ url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return (1920, 1080) }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }
}

// MARK: Items

struct ProjectFileItem: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let url: URL
    let kind: MediaKind
    let bytes: Int64
    let modified: Date
    /// Seconds, for video and audio. Filled in after the list appears (reading it opens each file).
    var duration: Double?
}

enum ProjectLibraryError: LocalizedError {
    case emptyName
    case nameTaken(String)
    case missing(String)
    case sameFile
    case io(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyName: return "The name can't be empty."
        case .nameTaken(let name): return "There is already a file called \"\(name)\"."
        case .missing(let name): return "\"\(name)\" is no longer in the project."
        case .sameFile: return "That is the file already in the project."
        case .io(let message): return message
        }
    }
}

// MARK: File operations

enum ProjectLibrary {
    
    static func clipsDirectory(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY, isDirectory: true)
    }
    
    static func previewDirectory(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(Constants.DEFAULT_PREVIEW_CLIP_DIRECTORY, isDirectory: true)
    }
    
    /// Every media file in Clips (sub-folders and non-media files are not part of the library).
    static func scan(projectPath: String) -> [ProjectFileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: clipsDirectory(projectPath), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        
        var items: [ProjectFileItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let kind = MediaKind(url: url)
            guard kind != .other else { continue }
            items.append(ProjectFileItem(name: url.lastPathComponent, url: url, kind: kind,
                                         bytes: Int64(values?.fileSize ?? 0),
                                         modified: values?.contentModificationDate ?? .distantPast,
                                         duration: nil))
        }
        return items
    }
    
    // MARK: Names
    
    /// Name for the rename field: trimmed, characters file systems reject replaced (the desktop's
    /// list), and the file's own extension kept. `typed` is the name WITHOUT extension, but a
    /// typed extension that matches is tolerated.
    static func validatedName(_ typed: String, extension ext: String) -> Result<String, ProjectLibraryError> {
        var stem = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, stem.lowercased().hasSuffix("." + ext.lowercased()) {
            stem = String(stem.dropLast(ext.count + 1))
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        stem = stem.components(separatedBy: forbidden).joined(separator: "_")
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") { stem.removeFirst() }
        guard !stem.isEmpty else { return .failure(.emptyName) }
        return .success(ext.isEmpty ? stem : "\(stem).\(ext)")
    }
    
    /// "name.ext" if free, otherwise "name (1).ext", "name (2).ext"...
    static func uniqueName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.appendingPathComponent(name).path) { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) { return candidate }
            index += 1
        }
    }
    
    // MARK: Import
    
    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.int64Value ?? -1
    }
    
    /// Copies a file into Clips and returns the name it has there. The same file imported again
    /// (same name AND same size) is reused; a DIFFERENT file with a name that is taken gets
    /// "name (1).ext" instead of silently standing in for the old one.
    /// The caller owns any security-scoped access to `url`.
    static func copyIn(_ url: URL, projectPath: String) throws -> String {
        let fm = FileManager.default
        let directory = clipsDirectory(projectPath)
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw ProjectLibraryError.io("Couldn't open the project's Clips folder: \(error.localizedDescription)") }
        
        let name = url.lastPathComponent
        let target = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) {
            if fileSize(target) == fileSize(url) { return name }
            let unique = uniqueName(name, in: directory)
            try copy(url, to: directory.appendingPathComponent(unique))
            return unique
        }
        try copy(url, to: target)
        return name
    }
    
    private static func copy(_ source: URL, to destination: URL) throws {
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw ProjectLibraryError.io("Couldn't copy \(source.lastPathComponent): \(error.localizedDescription)") }
    }
    
    // MARK: Rename / delete / replace
    
    /// Proxy files in PreviewClips that belong to a clip file (same base name, any extension).
    static func previewFiles(for name: String, projectPath: String) -> [URL] {
        let stem = (name as NSString).deletingPathExtension
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: previewDirectory(projectPath), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.deletingPathExtension().lastPathComponent == stem }
    }
    
    static func rename(from oldName: String, to newName: String, projectPath: String) throws {
        let fm = FileManager.default
        let directory = clipsDirectory(projectPath)
        let source = directory.appendingPathComponent(oldName)
        let target = directory.appendingPathComponent(newName)
        guard fm.fileExists(atPath: source.path) else { throw ProjectLibraryError.missing(oldName) }
        
        // APFS ignores case, so "clip.MP4" -> "clip.mp4" looks like an existing file: go through a
        // temporary name. Any other existing target is a real clash.
        let caseOnly = oldName.caseInsensitiveCompare(newName) == .orderedSame
        if !caseOnly, fm.fileExists(atPath: target.path) { throw ProjectLibraryError.nameTaken(newName) }
        
        let previews = previewFiles(for: oldName, projectPath: projectPath)
        do {
            if caseOnly {
                let temporary = directory.appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: source, to: temporary)
                try fm.moveItem(at: temporary, to: target)
            } else {
                try fm.moveItem(at: source, to: target)
            }
        } catch {
            throw ProjectLibraryError.io("Couldn't rename the file: \(error.localizedDescription)")
        }
        
        let newStem = (newName as NSString).deletingPathExtension
        for preview in previews {
            let renamed = preview.deletingLastPathComponent()
                .appendingPathComponent(newStem + (preview.pathExtension.isEmpty ? "" : "." + preview.pathExtension))
            try? fm.removeItem(at: renamed)         // a stale proxy of an older file with that name
            try? fm.moveItem(at: preview, to: renamed)
        }
    }
    
    static func delete(name: String, projectPath: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: clipsDirectory(projectPath).appendingPathComponent(name))
        for preview in previewFiles(for: name, projectPath: projectPath) { try? fm.removeItem(at: preview) }
    }
    
    /// Puts `url` in the project in place of `oldName` and returns the name clips should use now.
    /// - A file with the SAME name overwrites the old one (old proxies are dropped, they're stale).
    /// - A different name is imported like any file; the caller deletes the old file once the clips
    ///   point at the new one.
    static func replace(oldName: String, with url: URL, projectPath: String) throws -> String {
        let fm = FileManager.default
        let directory = clipsDirectory(projectPath)
        let oldURL = directory.appendingPathComponent(oldName)
        
        if url.standardizedFileURL.path == oldURL.standardizedFileURL.path { throw ProjectLibraryError.sameFile }
        
        if url.lastPathComponent.caseInsensitiveCompare(oldName) == .orderedSame {
            let temporary = directory.appendingPathComponent(".replace-\(UUID().uuidString)")
            try copy(url, to: temporary)
            do {
                if fm.fileExists(atPath: oldURL.path) { try fm.removeItem(at: oldURL) }
                try fm.moveItem(at: temporary, to: oldURL)
            } catch {
                try? fm.removeItem(at: temporary)
                throw ProjectLibraryError.io("Couldn't replace the file: \(error.localizedDescription)")
            }
            for preview in previewFiles(for: oldName, projectPath: projectPath) { try? fm.removeItem(at: preview) }
            return oldName
        }
        return try copyIn(url, projectPath: projectPath)
    }
    
    // MARK: Solid colour
    
    /// A solid-colour PNG named like Android's (solid_color_0.png, solid_color_1.png ...). Android
    /// renders 100x100 with ffmpeg; this is 1920x1080 so that, as an image clip, it fills a 16:9
    /// canvas without being scaled up (a flat PNG stays a few KB at any size).
    static func createSolidColorImage(_ color: UIColor, projectPath: String) throws -> String {
        let fm = FileManager.default
        let directory = clipsDirectory(projectPath)
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw ProjectLibraryError.io("Couldn't open the project's Clips folder: \(error.localizedDescription)") }
        
        var index = 0
        var name: String
        repeat {
            name = "solid_color_\(index).png"
            index += 1
        } while fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: Constants.SOLID_COLOR_IMAGE_WIDTH, height: Constants.SOLID_COLOR_IMAGE_HEIGHT)
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        do { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { throw ProjectLibraryError.io("Couldn't save the image: \(error.localizedDescription)") }
        return name
    }
}
