import Foundation
import AVFoundation
import CoreMedia

// MARK: - Composition builder (shared by the preview player and the exporter)
//
// The timeline -> AVMutableComposition + custom video composition step used to live inside
// `EditingPlayer.rebuildComposition`. Export has to render EXACTLY what the preview shows, so the
// logic now lives here and both callers use it: the preview wraps the result in an AVPlayerItem,
// the exporter feeds it to AVAssetReader/AVAssetWriter. Same compositor, same math, same frames.

extension EditingView {

    struct BuiltComposition {
        let composition: AVMutableComposition
        /// nil when the timeline has no video / image / text layer (nothing to composite).
        let videoComposition: AVMutableVideoComposition?
        let settings: VideoSettings
        let scrubSources: [ScrubSource]
        /// Number of visual layers (video, image, text clips) that were composited.
        let layerCount: Int
    }

    enum CompositionBuilder {

        static func build(timeline: EditingView.Timeline, projectDir: URL) -> BuiltComposition {
            let projectSettings = VideoSettings.load(projectPath: projectDir.path)
            
            let composition = AVMutableComposition()
            let scale: CMTimeScale = 600
            func cm(_ seconds: Float) -> CMTime { CMTime(seconds: Double(seconds), preferredTimescale: scale) }
            
            /// Draw order: track order, later tracks on top (FFmpegEdit's overlay chain order).
            var layers: [(layer: RenderLayer, range: CMTimeRange)] = []
            var contentEnd: Float = 0
            var scrubSources: [ScrubSource] = []
            
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
                            // Same clips, same condition as the composition's audio: what scrubbing
                            // plays is exactly what playback would.
                            scrubSources.append(ScrubSource(url: clipURL, startTime: Double(clip.startTime),
                                                            startTrim: Double(clip.startClipTrim),
                                                            duration: Double(clip.duration)))
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
            
            let end = composition.duration
            var builtVideoComposition: AVMutableVideoComposition?
            
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
                builtVideoComposition = videoComposition
            }

            return BuiltComposition(composition: composition,
                                    videoComposition: builtVideoComposition,
                                    settings: projectSettings,
                                    scrubSources: scrubSources,
                                    layerCount: layers.count)
        }
    }
}
