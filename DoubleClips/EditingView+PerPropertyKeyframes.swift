import Foundation

// MARK: - Per-property keyframes
//
// Beyond Android / desktop, where every keyframe snapshots ALL the clip's properties: here a keyframe can
// belong to just some of them. A keyframe with `channels == nil` is the old kind and holds every property
// (so existing projects behave exactly as before); a keyframe with `channels == [posX]` only animates Pos X.
//
// Each property is interpolated on its own, through the keyframes that hold it:
//   - no keyframe holds it    -> its static value (VideoProperties), editable as before
//   - keyframes hold it       -> the value interpolated between those keyframes (before the first / after
//                                the last it holds the nearest one), using the easing of the keyframe the
//                                segment starts at
//
// A keyframe's stored `value` always carries a complete look: the properties it doesn't hold are filled
// with what they were at that moment, so a reader that knows nothing about `channels` (an older build,
// Android, desktop) still plays something close to it.

extension EditingView.VideoProperties {
    
    typealias Channel = ValueType
    
    /// The properties a keyframe can hold (`rotInRadians` is only Rot in radians).
    static let channels: [ValueType] = ValueType.allCases.filter { $0 != .rotInRadians }
    
    private static let channelKeyPaths: [(ValueType, WritableKeyPath<EditingView.VideoProperties, Float>)] = [
        (.posX, \.valuePosX), (.posY, \.valuePosY), (.rot, \.valueRot),
        (.scaleX, \.valueScaleX), (.scaleY, \.valueScaleY),
        (.pivotX, \.valuePivotX), (.pivotY, \.valuePivotY),
        (.opacity, \.valueOpacity), (.speed, \.valueSpeed), (.volume, \.valueVolume),
        (.hue, \.valueHue), (.saturation, \.valueSaturation),
        (.brightness, \.valueBrightness), (.temperature, \.valueTemperature)
    ]
    
    static func channel(for keyPath: WritableKeyPath<EditingView.VideoProperties, Float>) -> ValueType? {
        channelKeyPaths.first { $0.1 == keyPath }?.0
    }
    
    static func displayName(for type: ValueType) -> String {
        switch type {
        case .posX: return "Pos X"
        case .posY: return "Pos Y"
        case .rot, .rotInRadians: return "Rotation"
        case .scaleX: return "Scale X"
        case .scaleY: return "Scale Y"
        case .pivotX: return "Pivot X"
        case .pivotY: return "Pivot Y"
        case .opacity: return "Opacity"
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .brightness: return "Brightness"
        case .temperature: return "Temperature"
        }
    }
}

extension EditingView.Keyframe {
    
    /// Does this keyframe hold `type`? (Old keyframes, `channels == nil`, hold everything.)
    func animates(_ type: EditingView.VideoProperties.ValueType) -> Bool {
        channels?.contains(type) ?? true
    }
    
    var channelList: [EditingView.VideoProperties.ValueType] {
        channels ?? EditingView.VideoProperties.channels
    }
    
    /// "All" or "Pos X, Scale Y".
    var channelSummary: String {
        guard let channels else { return "All" }
        return channels.map { EditingView.VideoProperties.displayName(for: $0) }.joined(separator: ", ")
    }
    
    /// Makes the keyframe hold (or stop holding) one property. Holding every property is stored as nil.
    mutating func animate(_ type: EditingView.VideoProperties.ValueType, _ on: Bool) {
        let all = EditingView.VideoProperties.channels
        var list = channels ?? all
        if on {
            if !list.contains(type) { list.append(type) }
        } else {
            list.removeAll { $0 == type }
        }
        channels = list.count == all.count ? nil : list
    }
}

extension EditingView.AnimatedProperty {
    
    /// Does any keyframe hold `type`? (Otherwise the property is just its static value.)
    func isAnimated(_ type: EditingView.VideoProperties.ValueType) -> Bool {
        keyframes.contains { $0.animates(type) }
    }
    
    /// The keyframe at this local time that holds `type`.
    func keyframeIndex(atLocal local: Float, animating type: EditingView.VideoProperties.ValueType) -> Int? {
        keyframes.firstIndex { abs($0.time - local) <= EditingView.minimumKeyframeSpacing && $0.animates(type) }
    }
    
    /// Gives `type` the value `value` at this local time: updates the keyframe that already holds it
    /// there, makes a keyframe that is already there hold it, or adds a keyframe that holds only it.
    mutating func setKey(_ type: EditingView.VideoProperties.ValueType, atLocal local: Float, value: Float,
                         base: EditingView.VideoProperties, clipStartTime: Float, frameRate: Int,
                         easing: EditingView.EasingType = Constants.KEYFRAME_DEFAULT_EASING) {
        if let i = keyframes.firstIndex(where: { abs($0.time - local) <= EditingView.minimumKeyframeSpacing }) {
            keyframes[i].animate(type, true)
            keyframes[i].value.setValue(value, type)
            return
        }
        // The look at this moment, so what the keyframe stores for the other properties is what they are.
        var look = resolved(base: base, clipStartTime: clipStartTime, at: clipStartTime + local)
        look.setValue(value, type)
        keyframes.append(EditingView.Keyframe(time: local, value: look, easing: easing, channels: [type]))
        sortKeyframes()
        reassignKeyframes(frameRate: frameRate)
    }
    
    /// Takes `type` off the keyframe at this local time (the keyframe goes when it holds nothing else).
    /// Returns the value it had, so the caller can keep the property at that value.
    @discardableResult
    mutating func removeKey(_ type: EditingView.VideoProperties.ValueType, atLocal local: Float) -> Float? {
        guard let i = keyframeIndex(atLocal: local, animating: type) else { return nil }
        let value = keyframes[i].value.value(type)
        keyframes[i].animate(type, false)
        if keyframes[i].channelList.isEmpty { keyframes.remove(at: i) }
        return value
    }
}
