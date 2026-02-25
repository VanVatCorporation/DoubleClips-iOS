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
}

extension EditingView.Clip {
    
    /// Delete this clip from its parent timeline
    func deleteClip(timeline: EditingView.Timeline) {
        guard self.trackIndex >= 0 && self.trackIndex < timeline.tracks.count else { return }
        let track = timeline.tracks[self.trackIndex]
        track.removeClip(self)
    }
    
    /// Split this clip into two clips at the specified global time
    func splitClip(timeline: EditingView.Timeline, currentGlobalTime: Float) -> EditingView.Clip? {
        guard currentGlobalTime > self.startTime && currentGlobalTime < (self.startTime + self.duration) else {
            return nil
        }
        
        let localSplitTime = currentGlobalTime - self.startTime
        
        // Android equivalent: Creates a new clip cloned from this one
        let newClip = EditingView.Clip(
            clipName: self.clipName,
            startTime: currentGlobalTime,
            duration: self.duration - localSplitTime,
            trackIndex: self.trackIndex,
            type: self.type,
            isClipHasAudio: self.isClipHasAudio,
            width: self.width,
            height: self.height
        )
        // Adjust split trims
        newClip.startClipTrim = self.startClipTrim + localSplitTime
        newClip.originalDuration = self.originalDuration
        
        self.duration = localSplitTime
        
        // Add new clip to the track immediately after this one
        guard self.trackIndex >= 0 && self.trackIndex < timeline.tracks.count else { return nil }
        let track = timeline.tracks[self.trackIndex]
        if let idx = track.clips.firstIndex(where: { $0.id == self.id }) {
            track.clips.insert(newClip, at: idx + 1)
        } else {
            track.addClip(newClip)
        }
        return newClip
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
