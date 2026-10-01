import Foundation
import UIKit
import AVFoundation

// MARK: - Project persistence
//
// iOS counterpart of Timeline.saveTimeline / loadTimeline (Android) and ProjectRepository's
// saveTimeline / loadTimeline / loadVideoSettings (desktop). The desktop's repository shape is
// used (load and save live in one place, separate from the view), with Android's save side
// effects: duration, timestamp and size written back to project.properties, preview.png
// regenerated, project.settings created if missing.
//
// On-disk layout (identical on all three platforms):
//   <project>/project.properties   ProjectData JSON
//   <project>/project.timeline     Timeline JSON (Gson @Expose fields only)
//   <project>/project.settings     VideoSettings JSON
//   <project>/preview.png          list thumbnail
//   <project>/Clips/<clipName>     media (clipName is ALWAYS relative — never store absolute paths)

extension EditingView.Timeline {
    
    /// Timeline.reloadTrackIndex(): a track's index is its position, and every clip follows it.
    /// (iOS's removeTrack only re-indexed the tracks, leaving clips pointing at stale rows.)
    func reloadTrackIndex() {
        for (index, track) in tracks.enumerated() {
            track.timelineIndex = index
            for clip in track.clips { clip.trackIndex = index }
        }
    }
    
    /// Timeline.prepareAfterLoad() (desktop) + loadTimeline() (Android), plus one repair:
    /// a clip without `originalDuration` would break trim/split maths, so derive it.
    func prepareAfterLoad() {
        reloadTrackIndex()
        for track in tracks {
            for clip in track.clips where clip.originalDuration <= 0 {
                clip.originalDuration = clip.startClipTrim + clip.duration + clip.endClipTrim
            }
            track.clips.sort { $0.startTime < $1.startTime }
        }
        recalculateDuration()
    }
}

extension EditingView.Clip {
    
    /// Clip.getAbsolutePath(projectPath): media always lives in <project>/Clips/<clipName>.
    func mediaURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY)
            .appendingPathComponent(clipName)
    }
}

extension EditingView {
    
    struct TimelineLoadResult {
        var timeline: Timeline
        var settings: VideoSettings
        /// Set when a timeline file existed but could not be read. The original was copied to a
        /// `.corrupt-<date>` backup first, so the auto-save can never overwrite the only copy.
        var recoveryNote: String?
    }
    
    /// Everything a save needs, captured on the main thread so the disk work can run elsewhere.
    struct TimelineSaveSnapshot {
        var project: ProjectData
        var settings: VideoSettings
        var timelineJSON: Data
        var durationSeconds: Float
        var thumbnail: ThumbnailSource?
    }
    
    enum ThumbnailSource {
        case video(URL, seconds: Double)
        case image(URL)
        
        var signature: String {
            switch self {
            case .video(let url, let s): return "v|\(url.path)|\(s)"
            case .image(let url): return "i|\(url.path)"
            }
        }
    }
    
    enum TimelineStore {
        
        private static let queue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.project-save", qos: .utility)
        /// Confined to `queue`: avoids re-decoding a video frame on every auto-save.
        private static var lastThumbnailSignature: [String: String] = [:]
        
        // MARK: Load
        
        static func load(project: ProjectData) -> TimelineLoadResult {
            let settings = VideoSettings.load(projectPath: project.projectPath)
            let path = IOHelper.combinePath(project.projectPath, Constants.DEFAULT_TIMELINE_FILENAME)
            
            // New project (or never saved): nothing to read. Android: fromJson("") -> null -> new Timeline().
            guard FileManager.default.fileExists(atPath: path),
                  let data = FileManager.default.contents(atPath: path),
                  !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
                return TimelineLoadResult(timeline: Timeline(), settings: settings, recoveryNote: nil)
            }
            
            do {
                let timeline = try JSONDecoder().decode(Timeline.self, from: data)
                timeline.prepareAfterLoad()
                return TimelineLoadResult(timeline: timeline, settings: settings, recoveryNote: nil)
            } catch {
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let backup = path + ".corrupt-" + stamp.string(from: Date())
                try? FileManager.default.copyItem(atPath: path, toPath: backup)
                print("[Project] Couldn't decode \(path): \(error)")
                return TimelineLoadResult(
                    timeline: Timeline(),
                    settings: settings,
                    recoveryNote: "This project's timeline couldn't be read, so it was opened empty. The original file was kept as \(URL(fileURLWithPath: backup).lastPathComponent) in the project folder."
                )
            }
        }
        
        // MARK: Save
        
        /// Main thread: normalise + encode. Throws BEFORE touching disk, so a failed encode
        /// can never replace a good file with a bad one.
        static func makeSnapshot(project: ProjectData, timeline: Timeline, settings: VideoSettings) throws -> TimelineSaveSnapshot {
            timeline.recalculateDuration()
            for track in timeline.tracks {
                // Android sortClips(): only touch the array when it is actually out of order.
                if zip(track.clips, track.clips.dropFirst()).contains(where: { $0.startTime > $1.startTime }) {
                    track.clips.sort { $0.startTime < $1.startTime }
                }
            }
            timeline.reloadTrackIndex()
            
            let json = try JSONEncoder().encode(timeline)
            
            // Android: preview comes from the first clip of the first track that has one.
            var thumbnail: ThumbnailSource?
            if let first = timeline.tracks.first(where: { !$0.clips.isEmpty })?.clips.first {
                let url = first.mediaURL(projectPath: project.projectPath)
                switch first.type {
                case .video: thumbnail = .video(url, seconds: Double(first.startClipTrim))
                case .image: thumbnail = .image(url)
                default: break
                }
            }
            
            return TimelineSaveSnapshot(project: project, settings: settings, timelineJSON: json,
                                        durationSeconds: timeline.duration, thumbnail: thumbnail)
        }
        
        /// Encode now, write in the background (kept alive briefly if the app is being suspended).
        static func save(project: ProjectData, timeline: Timeline, settings: VideoSettings) throws {
            let snapshot = try makeSnapshot(project: project, timeline: timeline, settings: settings)
            let task = UIApplication.shared.beginBackgroundTask(withName: "DoubleClips.SaveProject")
            queue.async {
                write(snapshot)
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        
        /// Runs on `queue`.
        private static func write(_ snapshot: TimelineSaveSnapshot) {
            let projectPath = snapshot.project.projectPath
            
            // 1. The timeline itself, atomically (temp file + rename): a crash mid-write
            //    leaves the previous version intact.
            let timelineURL = URL(fileURLWithPath: IOHelper.combinePath(projectPath, Constants.DEFAULT_TIMELINE_FILENAME))
            do {
                try snapshot.timelineJSON.write(to: timelineURL, options: .atomic)
            } catch {
                print("[Project] Saving timeline failed: \(error)")
                return
            }
            
            // 2. project.settings — created only when missing, so keys this app doesn't know
            //    (written by a newer Android/desktop build) are never stripped by a re-save.
            let settingsPath = IOHelper.combinePath(projectPath, Constants.DEFAULT_VIDEO_SETTINGS_FILENAME)
            if !FileManager.default.fileExists(atPath: settingsPath),
               let data = try? JSONEncoder().encode(snapshot.settings) {
                try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            }
            
            // 3. preview.png for the project list.
            if let source = snapshot.thumbnail {
                let previewPath = IOHelper.combinePath(projectPath, "preview.png")
                if lastThumbnailSignature[projectPath] != source.signature
                    || !FileManager.default.fileExists(atPath: previewPath) {
                    if writeThumbnail(source, to: previewPath) {
                        lastThumbnailSignature[projectPath] = source.signature
                    }
                }
            }
            
            // 4. project.properties: timestamp moves the project to the top of the list.
            var project = snapshot.project
            project.projectTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
            project.projectDuration = Int64(snapshot.durationSeconds * 1000)
            project.projectSize = Int64(IOHelper.getFileSize(projectPath))
            project.savePropertiesAtProject()
        }
        
        private static func writeThumbnail(_ source: ThumbnailSource, to path: String) -> Bool {
            let maxSide: CGFloat = 480
            var image: UIImage?
            
            switch source {
            case .video(let url, let seconds):
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxSide, height: maxSide)
                if let cg = try? generator.copyCGImage(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600), actualTime: nil) {
                    image = UIImage(cgImage: cg)
                }
            case .image(let url):
                guard let original = UIImage(contentsOfFile: url.path) else { return false }
                let scale = min(1, maxSide / max(original.size.width, original.size.height))
                let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    original.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            
            guard let png = image?.pngData() else { return false }
            return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
        }
    }
}
