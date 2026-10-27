import AVFoundation

// MARK: - Audio volume (static and keyframed)
//
// `VideoProperties.valueVolume` and its keyframe channel (`.volume`) existed (and the Volume row even had a keyframe
// diamond), but nothing ever applied them: neither the preview nor the export changed the loudness of a clip. This is
// the audio counterpart of Opacity: the clip's loudness over its own length, 1 = as recorded, 0 = silent, 2 = twice as loud.
//
// Preview and export read the SAME AVAudioMix (CompositionBuilder makes it once):
//   - a clip with a static volume that isn't 1 sets it at its start;
//   - a clip whose volume is keyframed gets a chain of short linear ramps along its length. AVFoundation only ramps
//     linearly, so each keyframe segment is cut into steps of at most 50 ms that follow the segment's easing curve
//     (a "hold" key is a step, the others are smooth to the ear);
//   - when nothing on the timeline changes any loudness the mix is nil, so untouched projects play exactly as before.
// Scrubbing (EditingView+Audio.swift) applies the same gain to its grains.
//
// Keyframe times are seconds into the clip on the TIMELINE (speed changes don't move them), the same clock the
// composition's audio track runs on, so no speed mapping is needed here.

extension EditingView {
    
    /// One clip's footage on a composition audio track, with what decides its loudness.
    struct AudioVolumeEntry {
        let trackID: CMPersistentTrackID
        let startTime: Float
        let duration: Float
        let baseProperties: VideoProperties
        let keyframes: AnimatedProperty
        
        /// Plain volume 1 and nothing animated: this clip needs no instruction of its own.
        var isTrivial: Bool {
            !keyframes.isAnimated(.volume) && abs(baseProperties.valueVolume - 1) < 0.0005
        }
    }
    
    enum AudioVolume {
        
        /// Loudest gain allowed (400 %): the slider goes to 2, a typed value may go further.
        static let maxGain: Float = 4
        /// Longest stretch one ramp covers.
        static let stepSeconds: Float = 0.05
        /// A very long clip uses longer steps instead of thousands of ramps.
        static let maxStepsPerClip = 4000
        
        /// The gain of a clip at a timeline time: the keyframed volume when some keyframe holds it, else the static one.
        static func gain(_ properties: VideoProperties, _ keyframes: AnimatedProperty,
                         clipStart: Float, at time: Float) -> Float {
            let raw = keyframes.isAnimated(.volume)
                ? keyframes.value(for: .volume, base: properties, clipStartTime: clipStart, at: time)
                : properties.valueVolume
            guard raw.isFinite else { return 1 }
            return min(max(raw, 0), maxGain)
        }
        
        /// nil when no clip changes its loudness.
        static func makeMix(_ entries: [AudioVolumeEntry], in composition: AVComposition) -> AVAudioMix? {
            func time(_ seconds: Float) -> CMTime { CMTime(seconds: Double(seconds), preferredTimescale: 6000) }
            
            var parameters: [AVAudioMixInputParameters] = []
            for (trackID, list) in Dictionary(grouping: entries, by: { $0.trackID }) {
                // A track where every clip is plain needs no instructions. As soon as one clip changes the level, EVERY clip
                // of the track gets one, or a quiet clip's level would carry on into the plain clip after it.
                guard list.contains(where: { !$0.isTrivial }),
                      let track = composition.track(withTrackID: trackID) else { continue }
                let input = AVMutableAudioMixInputParameters(track: track)
                
                for entry in list.sorted(by: { $0.startTime < $1.startTime }) where entry.duration > 0 {
                    func gain(at local: Float) -> Float {
                        Self.gain(entry.baseProperties, entry.keyframes, clipStart: entry.startTime,
                                  at: entry.startTime + local)
                    }
                    
                    guard entry.keyframes.isAnimated(.volume) else {
                        input.setVolume(gain(at: 0), at: time(entry.startTime))
                        continue
                    }
                    
                    // Break points: the clip's ends and every key that holds the volume, each stretch cut into short steps.
                    var points: [Float] = [0, entry.duration]
                    for key in entry.keyframes.keyframes where key.animates(.volume) && key.time > 0 && key.time < entry.duration {
                        points.append(key.time)
                    }
                    points.sort()
                    let step = max(stepSeconds, entry.duration / Float(maxStepsPerClip))
                    var marks: [Float] = []
                    for i in 0..<(points.count - 1) {
                        let from = points[i], to = points[i + 1]
                        guard to - from > 0.0005 else { continue }
                        let pieces = max(1, Int((to - from) / step + 0.999))
                        for j in 0..<pieces { marks.append(from + (to - from) * Float(j) / Float(pieces)) }
                    }
                    marks.append(entry.duration)
                    guard marks.count >= 2 else {
                        input.setVolume(gain(at: 0), at: time(entry.startTime))
                        continue
                    }
                    
                    for i in 0..<(marks.count - 1) {
                        let from = marks[i], to = marks[i + 1]
                        // The end of a step is read just before the next mark, so a key that holds its value (or the start
                        // of the next segment) isn't pulled into this step.
                        let startGain = gain(at: from)
                        let endGain = gain(at: max(to - 0.0002, from))
                        input.setVolumeRamp(fromStartVolume: startGain, toEndVolume: endGain,
                                            timeRange: CMTimeRange(start: time(entry.startTime + from),
                                                                   duration: time(to - from)))
                    }
                }
                parameters.append(input)
            }
            guard !parameters.isEmpty else { return nil }
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            return mix
        }
    }
}
