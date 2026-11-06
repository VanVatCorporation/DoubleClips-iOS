import Foundation
import UniformTypeIdentifiers

// MARK: - Formats iOS can't open, and where their playable copy lives
//
// AVFoundation (the player, the reader and the exporter) only opens MP4 / MOV / M4V and friends. A project that holds an .mkv, .avi,
// .webm, .flv, .wmv ... would draw black. So such a file is converted ONCE (FFmpeg, see FFmpegBackend / ConvertManager) into a normal
// MP4 (or M4A for audio) next to it in the project's Clips folder:
//
//      <clipName>.converted.mp4          e.g.  holiday.mkv.converted.mp4      (audio: <clipName>.converted.m4a)
//
// The clip keeps its ORIGINAL clipName (so the desktop and Android still see the file they know); `Clip.mediaURL` hands out the converted
// copy as soon as it exists, so the preview, thumbnails, waveform and export all use it without knowing. Same name on every platform.

enum MediaCompat {

    /// Video containers AVFoundation can't read.
    static let unsupportedVideo: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "asf", "ogv", "divx", "mpg", "mpeg", "vob",
                                                "ts", "m2ts", "mts", "mxf", "rm", "rmvb"]
    /// Audio files AVFoundation can't read.
    static let unsupportedAudio: Set<String> = ["ogg", "oga", "opus", "wma", "mka", "ape", "wv", "dts"]

    /// The name of the converted copy of `fileName`, or nil when the file doesn't need one.
    static func convertedName(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if unsupportedVideo.contains(ext) { return fileName + ".converted.mp4" }
        if unsupportedAudio.contains(ext) { return fileName + ".converted.m4a" }
        return nil
    }

    static func needsConversion(_ fileName: String) -> Bool { convertedName(for: fileName) != nil }

    /// True for the copies themselves (hidden from the Project Files list: they are caches, like a download's temp file).
    static func isConvertedCopy(_ fileName: String) -> Bool {
        fileName.contains(".converted.") && (fileName.hasSuffix(".mp4") || fileName.hasSuffix(".m4a") || fileName.hasSuffix(".partial"))
    }

    /// The file to OPEN for `url`: its converted copy when it needs one and the copy exists, else `url` itself.
    static func playableURL(_ url: URL) -> URL {
        guard let name = convertedName(for: url.lastPathComponent) else { return url }
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: copy.path) ? copy : url
    }

    /// What the media pickers accept: the usual types plus the containers above (Files doesn't know most of them).
    static let importTypes: [UTType] = {
        var types: [UTType] = [.audiovisualContent, .image, .movie, .audio]
        for ext in unsupportedVideo.union(unsupportedAudio).sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}
