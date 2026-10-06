import AVFoundation

// MARK: - Clip volume
//
// A clip's level over its own time, as one linear gain:
//
//     gain(t) = audioVolume  x  valueVolume(t)  x  fadeIn(t)  x  fadeOut(t)
//
//   audioVolume  the desktop's per-clip volume (`volume=` in its FFmpeg audio chain); 1 unless set there
//   valueVolume  the "Volume" property of the clip editor, so it can be keyframed like any other
//   fadeIn/Out   Clip.audioFadeIn / audioFadeOut, linear, in seconds from the clip's start / to its end
//
// The gain is handed to AVFoundation as an AVAudioMix (volume ramps on the composition's audio tracks),
// which the preview player item and the exporter's audio reader both use, so what you hear is what is
// exported. The scrub audio applies the same gain to its grains.

extension EditingView {
    
    struct ClipVolume {
        let base: Float
        let props: VideoProperties
        let keys: AnimatedProperty
        let startTime: Float
        let duration: Float
        let fadeIn: Float
        let fadeOut: Float
        
        init(clip: Clip) {
            base = clip.audioVolume
            props = clip.videoProperties
            keys = clip.keyframes
            startTime = clip.startTime
            duration = clip.duration
            fadeIn = max(0, clip.audioFadeIn)
            fadeOut = max(0, clip.audioFadeOut)
        }
        
        /// Linear gain `local` seconds into the clip.
        func gain(atLocal local: Float) -> Float {
            let volume = keys.keyframes.isEmpty
                ? props.valueVolume
                : keys.resolved(base: props, clipStartTime: startTime, at: startTime + local).valueVolume
            var fade: Float = 1
            if fadeIn > 0 { fade = min(fade, local / fadeIn) }
            if fadeOut > 0 { fade = min(fade, (duration - local) / fadeOut) }
            fade = min(max(fade, 0), 1)
            return min(max(base * volume * fade, 0), Constants.CLIP_VOLUME_MAX)
        }
        
        /// No keyframes and no fades: one level for the whole clip.
        var isConstant: Bool { keys.keyframes.isEmpty && fadeIn <= 0 && fadeOut <= 0 }
        
        /// Where the gain changes direction or speed, as seconds into the clip (always starts at 0 and ends
        /// at the clip's duration). Between two of them the gain is a straight ramp.
        func breakpoints() -> [Float] {
            var points: [Float] = [0, duration]
            if fadeIn > 0 { points.append(min(fadeIn, duration)) }
            if fadeOut > 0 { points.append(max(duration - fadeOut, 0)) }
            
            let ordered = keys.keyframes.sorted { $0.time < $1.time }
            for key in ordered where key.time > 0 && key.time < duration {
                points.append(key.time)
                // A hold (or a sharp easing) jumps at the keyframe: keep the jump short, not smeared.
                points.append(max(0, key.time - Constants.VOLUME_STEP_SECONDS))
            }
            // Eased segments are not straight lines: cut them into pieces.
            let pieces = Constants.VOLUME_RAMP_SUBDIVISIONS
            for (a, b) in zip(ordered, ordered.dropFirst()) where b.time - a.time > 0.05 {
                for step in 1..<pieces {
                    points.append(a.time + (b.time - a.time) * Float(step) / Float(pieces))
                }
            }
            
            var result: [Float] = []
            for p in points.map({ min(max($0, 0), duration) }).sorted() {
                if let last = result.last, p - last < 0.001 { continue }
                result.append(p)
            }
            if let last = result.last, last != duration {
                if duration - last < 0.001 { result[result.count - 1] = duration } else { result.append(duration) }
            }
            return result
        }
        
        /// Writes the clip's gain into the audio track's mix parameters.
        func apply(to params: AVMutableAudioMixInputParameters) {
            let scale: CMTimeScale = 600
            func time(_ local: Float) -> CMTime { CMTime(seconds: Double(startTime + local), preferredTimescale: scale) }
            let points = breakpoints()
            if isConstant || points.count < 2 {
                params.setVolume(gain(atLocal: 0), at: time(0))
                return
            }
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                params.setVolumeRamp(fromStartVolume: gain(atLocal: a), toEndVolume: gain(atLocal: b),
                                     timeRange: CMTimeRange(start: time(a), end: time(b)))
            }
        }
    }
}
