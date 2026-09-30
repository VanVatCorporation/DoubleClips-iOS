import Foundation
import CoreMedia
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

extension EditingView.Timeline {
    
    // MARK: - Core Operations
    
    func addTrack(_ track: EditingView.Track) {
        track.timelineIndex = self.tracks.count
        self.tracks.append(track)
    }
    
    func removeTrack(_ track: EditingView.Track) {
        self.tracks.removeAll(where: { $0.id == track.id })
        // Re-index remaining tracks to match Android's logic
        for (index, t) in self.tracks.enumerated() {
            t.timelineIndex = index
        }
    }
    
    func clearTimeline() {
        self.tracks.removeAll()
        self.duration = 0
    }
    
    /// Recomputes `duration` as the furthest clip end time across all tracks —
    /// matching Android's `Timeline.recalculateDuration()` / `Track.getTrackEndTime()`
    /// (`max(startTime + duration)`). This is the single source of truth the ruler,
    /// the duration readout, and the scrollable track width all derive from; nothing
    /// here is inferred from playhead position or view state.
    func recalculateDuration() {
        var maxEnd: Float = 0
        for track in tracks {
            let trackEnd = track.clips.map { $0.startTime + $0.duration }.max() ?? 0
            if trackEnd > maxEnd { maxEnd = trackEnd }
        }
        self.duration = maxEnd
    }
    
    /// Equivalent of Android's `Timeline.getClipsAtCurrentTime(currentTime)` — every clip,
    /// across all tracks, whose range strictly contains `time`. Used by both the default
    /// and track toolbars' Split button to split "whatever's under the playhead".
    func clipsAtCurrentTime(_ time: Float) -> [EditingView.Clip] {
        tracks.flatMap { $0.clips }.filter { time > $0.startTime && time < $0.startTime + $0.duration }
    }
    
    /// Reassigns `clip` to a different track. Equivalent of the drop handling in Android's
    /// `EditingActivity.handleClipInteraction` ACTION_UP branch (remove from old track,
    /// update trackIndex, add to new track).
    func moveClip(_ clip: EditingView.Clip, toTrackIndex newIndex: Int) {
        guard newIndex >= 0 && newIndex < tracks.count else { return }
        guard clip.trackIndex >= 0 && clip.trackIndex < tracks.count else { return }
        guard newIndex != clip.trackIndex else { return }
        let oldTrack = tracks[clip.trackIndex]
        oldTrack.removeClip(clip)
        clip.trackIndex = newIndex
        tracks[newIndex].addClip(clip)
    }
    
    /// Snaps a proposed drag start-time to the playhead and to neighboring clips' edges.
    /// Equivalent of the ACTION_MOVE snap logic in Android's
    /// `EditingActivity.handleClipInteraction`: snap targets are the playhead and clips on
    /// the current ± 1 neighboring tracks only (Android: "only snap in neighbors track"),
    /// within `TRACK_CLIPS_SNAP_THRESHOLD_PIXEL` converted to seconds at the current zoom
    /// (Android compares in raw pixels since it snaps view X positions directly; we work in
    /// seconds throughout, so the pixel threshold is converted using the live pixels-per-second).
    func snappedStartTime(for clip: EditingView.Clip, proposedStartTime: Float, candidateTrackIndex: Int, currentTime: Float, pixelsPerSecond: CGFloat) -> Float {
        var newStart = max(0, proposedStartTime)
        let thresholdSeconds = Float(Double(Constants.TRACK_CLIPS_SNAP_THRESHOLD_PIXEL) / Double(max(pixelsPerSecond, 1)))
        let duration = clip.duration
        
        // Snap to playhead — either edge of the clip landing on it.
        if abs(newStart - currentTime) < thresholdSeconds {
            newStart = currentTime
        } else if abs((newStart + duration) - currentTime) < thresholdSeconds {
            newStart = currentTime - duration
        }
        
        // Snap to neighboring clips' edges, current ± 1 track only.
        if !tracks.isEmpty {
            let lo = max(0, candidateTrackIndex - 1)
            let hi = min(tracks.count - 1, candidateTrackIndex + 1)
            if lo <= hi {
                snapSearch: for idx in lo...hi {
                    for other in tracks[idx].clips where other.id != clip.id {
                        let otherStart = other.startTime
                        let otherEnd = other.startTime + other.duration
                        let start = newStart
                        let end = newStart + duration
                        if abs(start - otherEnd) <= thresholdSeconds {
                            newStart = otherEnd
                            break snapSearch
                        }
                        if abs(end - otherStart) <= thresholdSeconds {
                            newStart = otherStart - duration
                            break snapSearch
                        }
                    }
                }
            }
        }
        return max(0, newStart)
    }
    
    /// Mutates this timeline's own @Published properties in place from a freshly
    /// decoded instance, rather than reassigning the @StateObject itself.
    /// @StateObject is meant to keep a stable object identity across the view's
    /// lifetime (SwiftUI's observation wiring is attached to that identity);
    /// swapping in a whole new Timeline instance from onAppear works in the
    /// simple case but is the wrong pattern for a load path that may run again
    /// later (e.g. reverting to a saved version).
    func load(from other: EditingView.Timeline) {
        self.tracks = other.tracks
        self.duration = other.duration
    }
    
    // MARK: - Serialization
    
    func saveTimeline(to url: URL) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
    
    static func loadTimeline(from url: URL) throws -> EditingView.Timeline {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(EditingView.Timeline.self, from: data)
    }
}

extension EditingView.Track {
    
    func addClip(_ clip: EditingView.Clip) {
        clip.trackIndex = self.timelineIndex
        self.clips.append(clip)
    }
    
    func removeClip(_ clip: EditingView.Clip) {
        self.clips.removeAll(where: { $0.id == clip.id })
    }
    
    /// Equivalent of Android's `Track.sortClips()` — keeps clips in start-time order
    /// after a move/drag, so index-based neighbor lookups (e.g. auto-snap, transition
    /// bridging) stay valid.
    func sortClips() {
        clips.sort { $0.startTime < $1.startTime }
    }
}

extension EditingView.Clip {
    
    /// Delete this clip from its parent timeline
    func deleteClip(timeline: EditingView.Timeline) {
        guard self.trackIndex >= 0 && self.trackIndex < timeline.tracks.count else { return }
        let track = timeline.tracks[self.trackIndex]
        track.removeClip(self)
    }
    
    /// Split at a global time. Port of Clip.splitClip / SplitClipCommand: the secondary clip is a
    /// full copy (keyframes, properties, mute, reverse, animations...) and both halves get their
    /// trims re-derived from `originalDuration`, so the source media is never re-cut.
    func splitClip(timeline: EditingView.Timeline, currentGlobalTime: Float) -> EditingView.Clip? {
        guard currentGlobalTime > startTime && currentGlobalTime < (startTime + duration) else { return nil }
        guard trackIndex >= 0 && trackIndex < timeline.tracks.count else { return nil }
        
        let local = localClipTime(currentGlobalTime)
        let oldStartTrim = startClipTrim
        let oldEndTrim = endClipTrim
        // Clips decoded from partial JSON can have originalDuration == 0; derive it instead.
        let base = originalDuration > 0 ? originalDuration : (oldStartTrim + duration + oldEndTrim)
        
        let secondary = copy()
        secondary.startTime = currentGlobalTime
        secondary.originalDuration = base
        
        // Primary (left) half
        originalDuration = base
        endClipTrim = base - (local + oldStartTrim)
        duration = base - endClipTrim - startClipTrim
        
        // Secondary (right) half
        secondary.startClipTrim = local + oldStartTrim
        secondary.endClipTrim = oldEndTrim
        secondary.duration = base - secondary.endClipTrim - secondary.startClipTrim
        
        // A transition belongs to the END of a clip, so it stays with the right half only.
        endTransition = nil
        endTransitionEnabled = false
        
        let track = timeline.tracks[trackIndex]
        if let idx = track.clips.firstIndex(where: { $0.id == id }) {
            track.clips.insert(secondary, at: idx + 1)
        } else {
            track.addClip(secondary)
        }
        return secondary
    }
}

extension EditingView {
    
    // MARK: - File Paths Equivalent
    
    func getAbsolutePath(for filename: String) -> URL {
        let projectFolder = URL(fileURLWithPath: project.projectPath)
        return projectFolder.appendingPathComponent(filename)
    }
    
    func getAbsolutePreviewPath(for filename: String) -> URL {
        let projectFolder = URL(fileURLWithPath: project.projectPath)
        let previewFolder = projectFolder.appendingPathComponent("previews")
        if !FileManager.default.fileExists(atPath: previewFolder.path) {
            try? FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
        }
        return previewFolder.appendingPathComponent(filename)
    }
    
    // MARK: - Native Thumbnail Extraction
    
    /// Equivalent to Android's `extractThumbnail` which uses MediaMetadataRetriever
    func extractThumbnail(from videoURL: URL, at timeInSeconds: Double) async throws -> URL? {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let targetTime = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
        
        do {
            let (cgImage, _) = try await generator.image(at: targetTime)
            
            #if canImport(UIKit)
            let uiImage = UIImage(cgImage: cgImage)
            let filename = UUID().uuidString + ".jpg"
            let destURL = getAbsolutePreviewPath(for: filename)
            
            if let data = uiImage.jpegData(compressionQuality: 0.8) {
                try data.write(to: destURL)
                return destURL
            }
            #endif
        } catch {
            print("Failed to extract thumbnail: \(error)")
        }
        return nil
    }
}
