import Foundation
import AVFoundation
import CoreMedia
import SwiftUI
import AVKit
import Combine

extension EditingView {
    
    // MARK: - Playback Engine (Android ClipRenderer equivalent)
    
    class EditingPlayer: ObservableObject {
        @Published var player: AVPlayer = AVPlayer()
        @Published var isPlaying: Bool = false
        @Published var currentTime: Double = 0.0
        
        /// Project resolution / frame rate, refreshed on every rebuild from `project.settings`.
        @Published var settings: VideoSettings = VideoSettings.androidDefault
        
        private var timeObserverToken: Any?
        private var currentComposition: AVMutableComposition?
        
        init() {
            setupTimeObserver()
        }
        
        deinit {
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
            }
        }
        
        func togglePlayPause() {
            if player.timeControlStatus == .playing {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
        }
        
        /// Explicit stop, distinct from the toggle above — this is what timeline
        /// scrubbing calls. Android's equivalent is `stopPlayback(true)`, invoked
        /// from `handleEditZoneInteraction`'s ACTION_MOVE handler the instant the
        /// user starts dragging the timeline while playing. Idempotent: safe to
        /// call even when already paused.
        func pause() {
            if player.timeControlStatus == .playing {
                player.pause()
            }
            isPlaying = false
        }
        
        private func setupTimeObserver() {
            let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                
                // Only trust the player's own reported time while actually playing.
                // While paused/scrubbing, `currentTime` is driven manually by seek(to:)
                // from timeline scrolling — letting this observer overwrite it every
                // 50ms fought that, making the ruler/readout appear frozen no matter
                // how far you scrolled.
                if self.player.timeControlStatus == .playing {
                    self.currentTime = time.seconds
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
            }
        }
        
        private var isRefreshingFrame = false
        
        /// Re-render the frame under the playhead while paused, so a live gesture (which only
        /// changes `LiveOverrides`) becomes visible. While playing the compositor picks the new
        /// values up on the next frame by itself.
        func refreshFrame() {
            guard !isPlaying, let item = player.currentItem, !isRefreshingFrame else { return }
            isRefreshingFrame = true
            // Re-assigning a copy of the video composition invalidates the displayed frame...
            if let composition = item.videoComposition,
               let copy = composition.mutableCopy() as? AVVideoComposition {
                item.videoComposition = copy
            }
            // ...and a zero-tolerance seek to the same time asks for a fresh one.
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.isRefreshingFrame = false
            }
        }
        
        func seek(to seconds: Double) {
            // Update immediately so the ruler/readout track scrolling in real time,
            // independent of how long the underlying AVPlayer seek takes.
            self.currentTime = seconds
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            // A small tolerance lets AVPlayer coalesce rapid successive seek calls
            // (many per second while scrubbing/scrolling) instead of each one
            // cancelling the last and never letting the player's time settle.
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        
        /// Rebuilds the AVPlayerItem composition when timeline changes.
        /// This mimics Android's ClipRenderer pipeline: AVFoundation only supplies the decoded
        /// source frames and audio; every visual layer is composited by `ClipCompositor`.
        func rebuildComposition(from timeline: EditingView.Timeline, projectDir: URL) {
            let projectSettings = VideoSettings.load(projectPath: projectDir.path)
            self.settings = projectSettings
            
            let composition = AVMutableComposition()
            let scale: CMTimeScale = 600
            func cm(_ seconds: Float) -> CMTime { CMTime(seconds: Double(seconds), preferredTimescale: scale) }
            
            /// Draw order: track order, later tracks on top (FFmpegEdit's overlay chain order).
            var layers: [(layer: RenderLayer, range: CMTimeRange)] = []
            var contentEnd: Float = 0
            
            for trackModel in timeline.tracks.sorted(by: { $0.timelineIndex < $1.timelineIndex }) {
                var compositionVideoTrack: AVMutableCompositionTrack?
                var compositionAudioTrack: AVMutableCompositionTrack?
                
                // Sequential inserts require ascending order within a track.
                for clip in trackModel.clips.sorted(by: { $0.startTime < $1.startTime }) {
                    guard clip.duration > 0 else { continue }
                    let start = cm(clip.startTime)
                    let duration = cm(clip.duration)
                    let window = CMTimeRange(start: start, duration: duration)
                    let clipURL = clip.mediaURL(projectPath: projectDir.path)
                    
                    func snapshot(_ kind: RenderLayer.Kind) -> RenderLayer {
                        RenderLayer(kind: kind, clipID: clip.id, startTime: clip.startTime,
                                    width: CGFloat(clip.width), height: CGFloat(clip.height),
                                    baseProperties: clip.videoProperties, keyframes: clip.keyframes)
                    }
                    
                    switch clip.type {
                    case .video, .audio:
                        let asset = AVAsset(url: clipURL)
                        // Android trims [startClipTrim, startClipTrim + duration] from the source.
                        let sourceRange = CMTimeRange(start: cm(clip.startClipTrim), duration: duration)
                        
                        if clip.type == .video, let sourceTrack = asset.tracks(withMediaType: .video).first {
                            if compositionVideoTrack == nil {
                                compositionVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
                            }
                            if let target = compositionVideoTrack,
                               (try? target.insertTimeRange(sourceRange, of: sourceTrack, at: start)) != nil {
                                // Speed: Android does setpts=PTS/speed inside the fixed [start, start+duration]
                                // window — the source range keeps its length, it just plays faster/slower.
                                let speed = Double(max(0.1, clip.videoProperties.valueSpeed))
                                if abs(speed - 1) > 0.001 {
                                    target.scaleTimeRange(window, toDuration: CMTime(seconds: Double(clip.duration) / speed, preferredTimescale: scale))
                                    // Slower than 1x would spill past the window into the next clip; trim the overflow.
                                    let scaledEnd = CMTimeAdd(start, CMTime(seconds: Double(clip.duration) / speed, preferredTimescale: scale))
                                    if CMTimeCompare(scaledEnd, window.end) > 0 {
                                        target.removeTimeRange(CMTimeRange(start: window.end, end: scaledEnd))
                                    }
                                }
                                layers.append((snapshot(.video(trackID: target.trackID,
                                                                preferredTransform: sourceTrack.preferredTransform)), window))
                                contentEnd = max(contentEnd, clip.startTime + clip.duration)
                            }
                        }
                        
                        if clip.isClipHasAudio && !clip.isMute, let audioSource = asset.tracks(withMediaType: .audio).first {
                            if compositionAudioTrack == nil {
                                compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
                            }
                            try? compositionAudioTrack?.insertTimeRange(sourceRange, of: audioSource, at: start)
                        }
                        
                    case .image:
                        layers.append((snapshot(.image(clipURL)), window))
                        contentEnd = max(contentEnd, clip.startTime + clip.duration)
                        
                    case .text:
                        layers.append((snapshot(.text(clip.textContent ?? "", CGFloat(clip.fontSize ?? 30))), window))
                        contentEnd = max(contentEnd, clip.startTime + clip.duration)
                        
                    default:
                        break // EFFECT / SCENE_3D: not composited in the preview yet
                    }
                }
            }
            
            // Images and text add no media, so they'd leave the composition shorter than the timeline.
            // An empty edit on a dummy track stretches the composition to the last clip's end.
            if contentEnd > 0 {
                let filler = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                filler?.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: cm(contentEnd)))
            }
            
            let item = AVPlayerItem(asset: composition)
            let end = composition.duration
            
            if !layers.isEmpty, CMTimeCompare(end, .zero) > 0 {
                // Split the timeline at every clip boundary so each instruction has a fixed layer stack.
                var points: [CMTime] = [.zero, end]
                for entry in layers {
                    points.append(CMTimeMinimum(CMTimeMaximum(entry.range.start, .zero), end))
                    points.append(CMTimeMinimum(CMTimeMaximum(entry.range.end, .zero), end))
                }
                points.sort { CMTimeCompare($0, $1) < 0 }
                var unique: [CMTime] = []
                for p in points where unique.last.map({ CMTimeCompare($0, p) != 0 }) ?? true { unique.append(p) }
                
                var instructions: [AVVideoCompositionInstructionProtocol] = []
                for i in 0..<(unique.count - 1) {
                    let a = unique[i], b = unique[i + 1]
                    let active = layers.filter {
                        CMTimeCompare($0.range.start, a) <= 0 && CMTimeCompare($0.range.end, b) >= 0
                    }.map { $0.layer }
                    instructions.append(CompositorInstruction(timeRange: CMTimeRange(start: a, end: b),
                                                              layers: active,
                                                              stretchToFull: projectSettings.isStretchToFull))
                }
                
                let videoComposition = AVMutableVideoComposition()
                videoComposition.customVideoCompositorClass = ClipCompositor.self
                videoComposition.renderSize = CGSize(width: projectSettings.videoWidth, height: projectSettings.videoHeight)
                videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(projectSettings.frameRate, 1)))
                videoComposition.instructions = instructions
                item.videoComposition = videoComposition
            }
            
            currentComposition = composition
            player.replaceCurrentItem(with: item)
            
            // Prevent auto-play explicitly
            player.pause()
            isPlaying = false
            
            // replaceCurrentItem resets the player to 0; put it back on the playhead so the
            // frame under the playhead reflects the edit that triggered this rebuild.
            let resumeAt = min(currentTime, max(end.seconds, 0))
            if resumeAt > 0 {
                player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: scale),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
}
