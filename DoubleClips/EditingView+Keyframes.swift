import Foundation

// MARK: - Keyframes, easing and clip math
//
// Ports of the pure-logic parts of EditingActivity.java that the Swift side was missing:
//   - VideoProperties.getValue / setValue / (Pivot, Volume)
//   - AnimatedProperty.getValueAtTime + ease()  (all 31 easing curves)
//   - Clip.addKeyframe / removeKeyframe / clearKeyframes / reassignKeyframes
//   - Clip.setStartClipTrim / setEndClipTrim / getLocalClipTime / getTrimmedLocalTime
//   - Clip.copy()  (Android's `new Clip(Clip)` copy constructor)
//
// Nothing here touches UI, so the preview compositor, the export path and the editor
// panels can all share the same resolved values.

extension EditingView {
    /// Constants.TRACK_CLIPS_MINIMUM_KEYFRAME_SPACE_SECONDS
    static let minimumKeyframeSpacing: Float = 0.01
}

// MARK: - VideoProperties accessors

extension EditingView.VideoProperties {
    
    func value(_ type: ValueType) -> Float {
        switch type {
        case .posX: return valuePosX
        case .posY: return valuePosY
        case .rot: return valueRot
        case .rotInRadians: return valueRot * .pi / 180
        case .scaleX: return valueScaleX
        case .scaleY: return valueScaleY
        case .pivotX: return valuePivotX
        case .pivotY: return valuePivotY
        case .opacity: return valueOpacity
        case .speed: return valueSpeed
        case .volume: return valueVolume
        case .hue: return valueHue
        case .saturation: return valueSaturation
        case .brightness: return valueBrightness
        case .temperature: return valueTemperature
        }
    }
    
    mutating func setValue(_ v: Float, _ type: ValueType) {
        switch type {
        case .posX: valuePosX = v
        case .posY: valuePosY = v
        case .rot: valueRot = v
        case .rotInRadians: valueRot = v * 180 / .pi
        case .scaleX: valueScaleX = v
        case .scaleY: valueScaleY = v
        case .pivotX: valuePivotX = v
        case .pivotY: valuePivotY = v
        case .opacity: valueOpacity = v
        case .speed: valueSpeed = v
        case .volume: valueVolume = v
        case .hue: valueHue = v
        case .saturation: valueSaturation = v
        case .brightness: valueBrightness = v
        case .temperature: valueTemperature = v
        }
    }
}

// MARK: - Easing

extension EditingView.EasingType {
    
    /// Port of AnimatedProperty.ease(). Note `.none` returns 0 on purpose (same as Android):
    /// the value holds at the previous keyframe until the next one is reached.
    func apply(_ tIn: Float) -> Float {
        let t = Double(tIn)
        let c1 = 1.70158
        let c2 = c1 * 1.525
        let c3 = c1 + 1
        let c4 = (2 * Double.pi) / 3
        let c5 = (2 * Double.pi) / 4.5
        
        func outBounce(_ x: Double) -> Double {
            var x = x
            let n1 = 7.5625, d1 = 2.75
            if x < 1 / d1 { return n1 * x * x }
            else if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
            else if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
            else { x -= 2.625 / d1; return n1 * x * x + 0.984375 }
        }
        
        let r: Double
        switch self {
        case .none: r = 0
        case .linear: r = t
            
        case .easeInSine: r = 1 - cos((t * .pi) / 2)
        case .easeOutSine: r = sin((t * .pi) / 2)
        case .easeInOutSine: r = -(cos(.pi * t) - 1) / 2
            
        case .easeInQuad: r = t * t
        case .easeOutQuad: r = 1 - (1 - t) * (1 - t)
        case .easeInOutQuad: r = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            
        case .easeInCubic: r = t * t * t
        case .easeOutCubic: r = 1 - pow(1 - t, 3)
        case .easeInOutCubic: r = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            
        case .easeInQuart: r = t * t * t * t
        case .easeOutQuart: r = 1 - pow(1 - t, 4)
        case .easeInOutQuart: r = t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2
            
        case .easeInQuint: r = t * t * t * t * t
        case .easeOutQuint: r = 1 - pow(1 - t, 5)
        case .easeInOutQuint: r = t < 0.5 ? 16 * t * t * t * t * t : 1 - pow(-2 * t + 2, 5) / 2
            
        case .easeInExpo: r = t == 0 ? 0 : pow(2, 10 * t - 10)
        case .easeOutExpo: r = t == 1 ? 1 : 1 - pow(2, -10 * t)
        case .easeInOutExpo:
            if t == 0 { r = 0 }
            else if t == 1 { r = 1 }
            else { r = t < 0.5 ? pow(2, 20 * t - 10) / 2 : (2 - pow(2, -20 * t + 10)) / 2 }
            
        case .easeInCirc: r = 1 - sqrt(1 - t * t)
        case .easeOutCirc: r = sqrt(1 - pow(t - 1, 2))
        case .easeInOutCirc:
            r = t < 0.5 ? (1 - sqrt(1 - pow(2 * t, 2))) / 2 : (sqrt(1 - pow(-2 * t + 2, 2)) + 1) / 2
            
        case .easeInBack: r = c3 * t * t * t - c1 * t * t
        case .easeOutBack: r = 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .easeInOutBack:
            r = t < 0.5
                ? (pow(2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2
                : (pow(2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2
            
        case .easeInElastic:
            if t == 0 { r = 0 } else if t == 1 { r = 1 }
            else { r = -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * c4) }
        case .easeOutElastic:
            if t == 0 { r = 0 } else if t == 1 { r = 1 }
            else { r = pow(2, -10 * t) * sin((t * 10 - 0.75) * c4) + 1 }
        case .easeInOutElastic:
            if t == 0 { r = 0 } else if t == 1 { r = 1 }
            else if t < 0.5 { r = -(pow(2, 20 * t - 10) * sin((20 * t - 11.125) * c5)) / 2 }
            else { r = (pow(2, -20 * t + 10) * sin((20 * t - 11.125) * c5)) / 2 + 1 }
            
        case .easeInBounce: r = 1 - outBounce(1 - t)
        case .easeOutBounce: r = outBounce(t)
        case .easeInOutBounce:
            r = t < 0.5 ? (1 - outBounce(1 - 2 * t)) / 2 : (1 + outBounce(2 * t - 1)) / 2
        }
        return Float(r)
    }
}

// MARK: - AnimatedProperty

extension EditingView.AnimatedProperty {
    
    /// Keyframe whose *global* time matches `playheadTime` within the keyframe spacing tolerance.
    func keyframe(at playheadTime: Float, clip: EditingView.Clip) -> EditingView.Keyframe? {
        keyframes.first { abs(($0.time + clip.startTime) - playheadTime) <= EditingView.minimumKeyframeSpacing }
    }
    
    /// Port of AnimatedProperty.getValueAtTime (global playhead time in, single value out).
    func value(for type: EditingView.VideoProperties.ValueType, clip: EditingView.Clip, at playheadTime: Float) -> Float {
        value(for: type, base: clip.videoProperties, clipStartTime: clip.startTime, at: playheadTime)
    }
    
    /// Same maths on plain value types, so the preview compositor can call it from its render
    /// queue with a snapshot instead of touching the (main-thread) Clip object.
    func value(for type: EditingView.VideoProperties.ValueType, base: EditingView.VideoProperties,
               clipStartTime: Float, at playheadTime: Float) -> Float {
        guard let first = keyframes.first, let last = keyframes.last else {
            return base.value(type)
        }
        let local = playheadTime - clipStartTime
        
        var prev = first
        for next in keyframes {
            if local < next.time {
                let span = next.time - prev.time
                // Android divides by zero here when playhead is before the first keyframe; the
                // clamp then yields 0 → prev value. Guard explicitly so we never produce NaN.
                let raw: Float = span > 0 ? (local - prev.time) / span : 0
                let t = max(0, min(1, raw))
                let a = prev.value.value(type), b = next.value.value(type)
                return a + (b - a) * prev.easing.apply(t)
            }
            prev = next
        }
        return last.value.value(type)
    }
    
    /// All properties resolved at once — this is what the preview/export compositors consume.
    func resolved(clip: EditingView.Clip, at playheadTime: Float) -> EditingView.VideoProperties {
        resolved(base: clip.videoProperties, clipStartTime: clip.startTime, at: playheadTime)
    }
    
    func resolved(base: EditingView.VideoProperties, clipStartTime: Float, at playheadTime: Float) -> EditingView.VideoProperties {
        guard !keyframes.isEmpty else { return base }
        var out = base
        for type in EditingView.VideoProperties.ValueType.allCases where type != .rotInRadians {
            out.setValue(value(for: type, base: base, clipStartTime: clipStartTime, at: playheadTime), type)
        }
        return out
    }
}

// MARK: - Clip helpers

extension EditingView.Clip {
    
    /// Android `Clip(Clip)` copy constructor. Every editable field is carried over (the old
    /// Swift `makeClone` / `splitClip` silently dropped properties, keyframes, mute, reverse, …).
    func copy() -> EditingView.Clip {
        let c = EditingView.Clip(
            clipName: clipName, startTime: startTime, duration: duration,
            trackIndex: trackIndex, type: type, isClipHasAudio: isClipHasAudio,
            width: width, height: height
        )
        c.startClipTrim = startClipTrim
        c.endClipTrim = endClipTrim
        c.originalDuration = originalDuration
        c.videoProperties = videoProperties
        c.keyframes = keyframes
        c.isMute = isMute
        c.isReverse = isReverse
        c.removeBackground = removeBackground
        c.audioVolume = audioVolume
        c.isLockedForTemplate = isLockedForTemplate
        c.additionalFFmpegCommand = additionalFFmpegCommand
        c.endTransition = endTransition
        c.endTransitionEnabled = endTransitionEnabled
        c.inAnimation = inAnimation
        c.outAnimation = outAnimation
        c.comboAnimation = comboAnimation
        c.textContent = textContent
        c.fontSize = fontSize
        c.effect = effect
        c.sceneConfig = sceneConfig
        c.textureClipName = textureClipName
        return c
    }
    
    // MARK: Time math (getLocalClipTime / getTrimmedLocalTime / getCutoutDuration)
    
    func localClipTime(_ playheadTime: Float) -> Float { playheadTime - startTime }
    func trimmedLocalTime(_ localClipTime: Float) -> Float { localClipTime + startClipTrim }
    var cutoutDuration: Float { duration - startClipTrim - endClipTrim }
    
    /// setStartClipTrim(): changing a trim also re-derives duration.
    func setStartClipTrim(_ value: Float) {
        startClipTrim = value
        duration = originalDuration - endClipTrim - startClipTrim
    }
    
    func setEndClipTrim(_ value: Float) {
        endClipTrim = value
        duration = originalDuration - endClipTrim - startClipTrim
    }
    
    // MARK: Properties
    
    /// Android: needs > 1 keyframe to form a line to interpolate along.
    var hasAnimatedProperties: Bool { keyframes.keyframes.count > 1 }
    var hasOnlyOneAnimatedProperty: Bool { keyframes.keyframes.count == 1 }
    
    /// "Restate" toolbar button — reset every property to its default.
    func restate() { videoProperties = EditingView.VideoProperties() }
    
    func mergeSingleKeyframeIntoProperties() {
        guard hasOnlyOneAnimatedProperty, let only = keyframes.keyframes.first else { return }
        videoProperties = only.value
    }
    
    // MARK: Keyframes
    
    /// Port of EditingActivity.addKeyframe(clip, time). Snapshots the current static properties.
    /// Returns the keyframe if one was added (nil when outside the clip or a duplicate).
    @discardableResult
    func addKeyframe(atGlobalTime playhead: Float, frameRate: Int, easing: EditingView.EasingType = .none) -> EditingView.Keyframe? {
        let local = playhead - startTime
        guard local >= 0 && local <= duration else { return nil }
        let candidate = EditingView.Keyframe(time: local, value: videoProperties, easing: easing)
        guard !keyframes.keyframes.contains(where: { abs($0.time - local) <= EditingView.minimumKeyframeSpacing }) else { return nil }
        keyframes.keyframes.append(candidate)
        keyframes.sortKeyframes()
        keyframes.reassignKeyframes(frameRate: frameRate)
        // reassign may nudge `time` to the nearest frame; return the stored instance.
        return keyframes.keyframes.first { abs($0.time - local) <= 1.0 / Float(max(frameRate, 1)) }
    }
    
    func removeKeyframe(at index: Int) {
        guard keyframes.keyframes.indices.contains(index) else { return }
        keyframes.keyframes.remove(at: index)
    }
    
    func clearKeyframes() { keyframes.keyframes.removeAll() }
}

extension EditingView.AnimatedProperty {
    mutating func sortKeyframes() { keyframes.sort { $0.time < $1.time } }
    
    /// Snap every keyframe onto the project's frame grid (AnimatedProperty.reassignKeyframes).
    mutating func reassignKeyframes(frameRate: Int) {
        guard frameRate > 0 else { return }
        let fps = Float(frameRate)
        for i in keyframes.indices {
            let idx = (keyframes[i].time * fps).rounded()
            keyframes[i].frame = Int64(idx)
            keyframes[i].time = idx / fps
        }
    }
}
