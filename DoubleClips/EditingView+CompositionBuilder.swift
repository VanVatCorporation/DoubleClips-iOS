import Foundation
import AVFoundation
import CoreMedia

// MARK: - Composition builder (shared by the preview player and the exporter)
//
// The timeline -> AVMutableComposition + custom video composition step used to live inside
// `EditingPlayer.rebuildComposition`. Export has to render EXACTLY what the preview shows, so the
// logic now lives here and both callers use it: the preview wraps the result in an AVPlayerItem,
// the exporter feeds it to AVAssetReader/AVAssetWriter. Same compositor, same math, same frames.
//
// Transitions (EditingView+TransitionPlan.swift): while two clips of a track blend, both must be
// decodable at the same moment, so each clip goes on a "lane" (a composition video track) that has
// no other media at that time: normally one lane per timeline track, a second one only around a
// transition. B also gets its pre-roll and A its post-roll footage inserted next to its own range
// (the real footage when the file has it, otherwise a held first / last frame).

extension EditingView {

    struct BuiltComposition {
        let composition: AVMutableComposition
        /// nil when the timeline has no video / image / text layer (nothing to composite).
        let videoComposition: AVMutableVideoComposition?
        let settings: VideoSettings
        let scrubSources: [ScrubSource]
        /// Per-clip volume and fades for the composition's audio tracks (nil = every clip at its own level).
        let audioMix: AVAudioMix?
        /// Number of visual layers (video, image, text clips) that were composited.
        let layerCount: Int
    }

    enum CompositionBuilder {

        static func build(timeline: EditingView.Timeline, projectDir: URL) -> BuiltComposition {
            // Bundled animations + installed packs must be in the registry before any frame is rendered
            // (idempotent, cheap after the first call).
            ClipAnimationStore.loadAll()
            let projectSettings = VideoSettings.load(projectPath: projectDir.path)
            
            let composition = AVMutableComposition()
            let scale: CMTimeScale = 600
            func cm(_ seconds: Float) -> CMTime { CMTime(seconds: Double(seconds), preferredTimescale: scale) }
            
            /// Draw order: track order, later tracks on top (FFmpegEdit's overlay chain order).
            /// `range` is where the clip's picture is shown: its own range, or wider around a transition.
            var layers: [(layer: RenderLayer, range: CMTimeRange, order: Int)] = []
            var transitionSpecs: [(from: UUID, to: UUID, style: String, start: Float, end: Float)] = []
            var layerByClip: [UUID: RenderLayer] = [:]
            var drawOrder = 0
            var contentEnd: Float = 0
            var scrubSources: [ScrubSource] = []
            var audioMixParams: [AVMutableAudioMixInputParameters] = []
            
            for trackModel in timeline.tracks.sorted(by: { $0.timelineIndex < $1.timelineIndex }) {
                /// Video lanes of this track (see the header). Reused whenever they are free.
                var lanes: [AVMutableCompositionTrack] = []
                var compositionAudioTrack: AVMutableCompositionTrack?
                var compositionAudioParams: AVMutableAudioMixInputParameters?
                
                func lane(freeFrom time: CMTime) -> AVMutableCompositionTrack? {
                    if let free = lanes.first(where: { CMTimeCompare($0.timeRange.end, time) <= 0 }) { return free }
                    guard let created = composition.addMutableTrack(withMediaType: .video,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                    lanes.append(created)
                    return created
                }
                
                // Sequential inserts require ascending order within a lane.
                let sortedClips = trackModel.clips.sorted(by: { $0.startTime < $1.startTime })
                let plan = TransitionPlan.make(clips: sortedClips)
                transitionSpecs += plan.windows.map { ($0.aID, $0.bID, $0.style, $0.start, $0.end) }
                
                for clip in sortedClips {
                    guard clip.duration > 0 else { continue }
                    let start = cm(clip.startTime)
                    let duration = cm(clip.duration)
                    let window = CMTimeRange(start: start, duration: duration)
                    let clipURL = clip.mediaURL(projectPath: projectDir.path)
                    
                    // Where the picture is shown: wider than the clip while it takes part in a blend.
                    let shownStart = cm(max(0, plan.visibleStart[clip.id] ?? clip.startTime))
                    let shownEnd = cm(plan.visibleEnd[clip.id] ?? (clip.startTime + clip.duration))
                    let shown = CMTimeRange(start: shownStart, end: CMTimeMaximum(shownEnd, shownStart))
                    let preRoll = Double(plan.preRoll[clip.id] ?? 0)
                    let postRoll = Double(plan.postRoll[clip.id] ?? 0)
                    
                    func snapshot(_ kind: RenderLayer.Kind) -> RenderLayer {
                        RenderLayer(kind: kind, clipID: clip.id, startTime: clip.startTime,
                                    width: CGFloat(clip.width), height: CGFloat(clip.height),
                                    baseProperties: clip.videoProperties, keyframes: clip.keyframes,
                                    inAnimation: clip.inAnimation, outAnimation: clip.outAnimation,
                                    duration: clip.duration)
                    }
                    
                    switch clip.type {
                    case .video, .audio:
                        let asset = AVAsset(url: clipURL)
                        // Android trims [startClipTrim, startClipTrim + duration] from the source.
                        let sourceRange = CMTimeRange(start: cm(clip.startClipTrim), duration: duration)
                        
                        if clip.type == .video, let sourceTrack = asset.tracks(withMediaType: .video).first {
                            // Footage around the trimmed range, for the blend (pre-roll / post-roll).
                            let trim = Double(clip.startClipTrim)
                            let length = Double(clip.duration)
                            let sourceEnd = max(sourceTrack.timeRange.end.seconds, 0)
                            let preReal = min(preRoll, max(0, trim))
                            let preHold = max(0, preRoll - preReal)
                            let postReal = min(postRoll, max(0, sourceEnd - (trim + length)))
                            let postHold = max(0, postRoll - postReal)
                            
                            let firstNeeded = cm(clip.startTime - Float(preRoll))
                            if let target = lane(freeFrom: firstNeeded) {
                                let hold = CMTime(seconds: Constants.TRANSITION_HOLD_SAMPLE_SECONDS, preferredTimescale: scale)
                                /// A frozen frame: one sample of the source stretched over `seconds`.
                                func insertHold(sourceAt: Double, at: CMTime, seconds: Double) {
                                    guard seconds > 0.001 else { return }
                                    let at0 = max(0, min(sourceAt, max(0, sourceEnd - Constants.TRANSITION_HOLD_SAMPLE_SECONDS)))
                                    let range = CMTimeRange(start: CMTime(seconds: at0, preferredTimescale: scale), duration: hold)
                                    guard (try? target.insertTimeRange(range, of: sourceTrack, at: at)) != nil else { return }
                                    target.scaleTimeRange(CMTimeRange(start: at, duration: hold),
                                                          toDuration: CMTime(seconds: seconds, preferredTimescale: scale))
                                }
                                
                                // Before the clip (it is the B of a transition): held first frame, then real footage.
                                insertHold(sourceAt: trim - preReal, at: cm(clip.startTime - Float(preRoll)), seconds: preHold)
                                if preReal > 0.001 {
                                    let range = CMTimeRange(start: CMTime(seconds: trim - preReal, preferredTimescale: scale),
                                                            duration: CMTime(seconds: preReal, preferredTimescale: scale))
                                    _ = try? target.insertTimeRange(range, of: sourceTrack,
                                                                    at: cm(clip.startTime - Float(preReal)))
                                }
                                
                                if (try? target.insertTimeRange(sourceRange, of: sourceTrack, at: start)) != nil {
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
                                    let layer = snapshot(.video(trackID: target.trackID,
                                                                preferredTransform: sourceTrack.preferredTransform))
                                    layers.append((layer, shown, drawOrder))
                                    layerByClip[clip.id] = layer
                                    drawOrder += 1
                                    contentEnd = max(contentEnd, clip.startTime + clip.duration)
                                    
                                    // After the clip (it is the A of a transition): real footage, then a held last frame.
                                    if postReal > 0.001 {
                                        let range = CMTimeRange(start: CMTime(seconds: trim + length, preferredTimescale: scale),
                                                                duration: CMTime(seconds: postReal, preferredTimescale: scale))
                                        _ = try? target.insertTimeRange(range, of: sourceTrack, at: window.end)
                                    }
                                    insertHold(sourceAt: trim + length + postReal - Constants.TRANSITION_HOLD_SAMPLE_SECONDS,
                                               at: CMTimeAdd(window.end, cm(Float(postReal))), seconds: postHold)
                                }
                            }
                        }
                        
                        if clip.isClipHasAudio && !clip.isMute, let audioSource = asset.tracks(withMediaType: .audio).first {
                            if compositionAudioTrack == nil {
                                compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
                                if let audioTrack = compositionAudioTrack {
                                    let params = AVMutableAudioMixInputParameters(track: audioTrack)
                                    compositionAudioParams = params
                                    audioMixParams.append(params)
                                }
                            }
                            try? compositionAudioTrack?.insertTimeRange(sourceRange, of: audioSource, at: start)
                            // Volume, keyframed volume and fades (EditingView+ClipVolume.swift).
                            let volume = ClipVolume(clip: clip)
                            if let params = compositionAudioParams { volume.apply(to: params) }
                            // Same clips, same condition as the composition's audio: what scrubbing
                            // plays is exactly what playback would.
                            scrubSources.append(ScrubSource(url: clipURL, startTime: Double(clip.startTime),
                                                            startTrim: Double(clip.startClipTrim),
                                                            duration: Double(clip.duration),
                                                            gain: { volume.gain(atLocal: Float($0)) }))
                        }
                        
                    case .image:
                        let layer = snapshot(.image(clipURL))
                        layers.append((layer, shown, drawOrder))
                        layerByClip[clip.id] = layer
                        drawOrder += 1
                        contentEnd = max(contentEnd, clip.startTime + clip.duration)
                        
                    case .text:
                        let spec = TextSpec(text: clip.textContent ?? "", fontSize: CGFloat(clip.fontSize ?? 30),
                                            style: clip.textStyle ?? TextStyle(),
                                            canvasWidth: CGFloat(projectSettings.videoWidth))
                        layers.append((snapshot(.text(spec)), window, drawOrder))
                        drawOrder += 1
                        contentEnd = max(contentEnd, clip.startTime + clip.duration)
                        
                    case .effect:
                        // Adjustment layer: no media. It sits in the draw order at its track's place and
                        // filters whatever the earlier tracks produced during [startTime, endTime).
                        let template = clip.effect
                        let style = template?.style ?? ""
                        if !style.isEmpty {
                            layers.append((snapshot(.effect(style: style, intensity: template?.intensity ?? 1)), window, drawOrder))
                            drawOrder += 1
                        }
                        
                    default:
                        break // EFFECT / SCENE_3D: not composited in the preview yet
                    }
                }
            }
            
            // (transitions of every track are collected below, once all layers exist)
            
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
                    
                    // A transition replaces its two clips (same track, so same place in the stack)
                    // for exactly the stretch its window covers.
                    let segStart = Float(a.seconds), segEnd = Float(b.seconds)
                    let activeIDs = Set(active.map { $0.clipID })
                    var entries: [RenderEntry] = []
                    var consumed = Set<UUID>()
                    for layer in active {
                        if consumed.contains(layer.clipID) { continue }
                        if let spec = transitionSpecs.first(where: {
                            ($0.from == layer.clipID || $0.to == layer.clipID)
                                && activeIDs.contains($0.from) && activeIDs.contains($0.to)
                                && $0.start <= segStart + 0.001 && $0.end >= segEnd - 0.001
                        }), let from = layerByClip[spec.from], let to = layerByClip[spec.to] {
                            consumed.insert(spec.from)
                            consumed.insert(spec.to)
                            entries.append(.transition(RenderTransition(from: from, to: to, style: spec.style,
                                                                        start: spec.start,
                                                                        duration: spec.end - spec.start)))
                        } else {
                            entries.append(.layer(layer))
                        }
                    }
                    instructions.append(CompositorInstruction(timeRange: CMTimeRange(start: a, end: b),
                                                              entries: entries,
                                                              stretchToFull: projectSettings.isStretchToFull))
                }
                
                let videoComposition = AVMutableVideoComposition()
                videoComposition.customVideoCompositorClass = ClipCompositor.self
                videoComposition.renderSize = CGSize(width: projectSettings.videoWidth, height: projectSettings.videoHeight)
                videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(projectSettings.frameRate, 1)))
                videoComposition.instructions = instructions
                builtVideoComposition = videoComposition
            }

            var audioMix: AVMutableAudioMix?
            if !audioMixParams.isEmpty {
                let mix = AVMutableAudioMix()
                mix.inputParameters = audioMixParams
                audioMix = mix
            }
            
            return BuiltComposition(composition: composition,
                                    videoComposition: builtVideoComposition,
                                    settings: projectSettings,
                                    scrubSources: scrubSources,
                                    audioMix: audioMix,
                                    layerCount: layers.count)
        }
    }
}
