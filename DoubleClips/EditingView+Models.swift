import Foundation
import Combine

extension EditingView {
    
    // MARK: - Core Editing Models
    
    /// The root Timeline structure matching Android's Timeline
    class Timeline: Codable, ObservableObject {
        @Published var tracks: [Track] = []
        @Published var duration: Float = 0
        
        enum CodingKeys: String, CodingKey {
            case tracks
            case duration
        }
        
        init() {}
        
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
            self.duration = try container.decodeIfPresent(Float.self, forKey: .duration) ?? 0
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tracks, forKey: .tracks)
            try container.encode(duration, forKey: .duration)
        }
    }
    
    class Track: Codable, Identifiable, ObservableObject {
        let id = UUID()
        
        @Published var timelineIndex: Int = 0
        @Published var clips: [Clip] = []
        
        enum CodingKeys: String, CodingKey {
            case timelineIndex
            case clips
        }
        
        init(timelineIndex: Int = 0) {
            self.timelineIndex = timelineIndex
        }
        
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.timelineIndex = try container.decodeIfPresent(Int.self, forKey: .timelineIndex) ?? 0
            self.clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timelineIndex, forKey: .timelineIndex)
            try container.encode(clips, forKey: .clips)
        }
    }
    
    enum ClipType: String, Codable {
        case video = "VIDEO"
        case audio = "AUDIO"
        case image = "IMAGE"
        case text = "TEXT"
        case transition = "TRANSITION"
        case effect = "EFFECT"
        case scene3D = "SCENE_3D"
        
        /// Gson stores enums by name and yields null for names it doesn't know; the desktop then
        /// falls back to VIDEO. Do the same instead of failing to open the whole project.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ClipType(rawValue: raw) ?? .video
        }
    }

    /// Equivalent of EditingActivity.AnimationClip (in / out / combo animation slot).
    struct AnimationClip: Codable, Equatable {
        var type: String = "none"
        var duration: Float = 0.5

        init(type: String = "none", duration: Float = 0.5) {
            self.type = type
            self.duration = duration
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? "none"
            self.duration = try c.decodeIfPresent(Float.self, forKey: .duration) ?? 0.5
        }
    }

    class Clip: Codable, Identifiable, ObservableObject {
        let id = UUID()
        
        @Published var type: ClipType
        @Published var clipName: String
        @Published var startTime: Float
        @Published var duration: Float
        @Published var startClipTrim: Float
        @Published var endClipTrim: Float
        @Published var originalDuration: Float
        @Published var trackIndex: Int
        @Published var width: Int
        @Published var height: Int
        
        @Published var videoProperties: VideoProperties
        @Published var keyframes: AnimatedProperty
        
        @Published var effect: EffectTemplate?
        @Published var textContent: String?
        @Published var fontSize: Float?
        /// iOS addition (EditingView+Text.swift): font, colour, outline, shadow... nil = defaults.
        @Published var textStyle: TextStyle?
        
        @Published var endTransition: TransitionClip?
        @Published var endTransitionEnabled: Bool
        
        @Published var isClipHasAudio: Bool
        @Published var isMute: Bool
        @Published var isLockedForTemplate: Bool
        @Published var isReverse: Bool
        @Published var removeBackground: Bool = false
        /// Desktop-only field (ClipRenderer / AudioUtils apply it). Android has no such field.
        /// When missing: 1 for clips with audio, like the desktop constructor, instead of Gson's 0.
        @Published var audioVolume: Float = 1
        
        @Published var additionalFFmpegCommand: String?
        @Published var sceneConfig: String?        // SCENE_3D
        @Published var textureClipName: String?    // SCENE_3D
        
        @Published var inAnimation: AnimationClip = AnimationClip()
        @Published var outAnimation: AnimationClip = AnimationClip()
        @Published var comboAnimation: AnimationClip = AnimationClip()
        
        enum CodingKeys: String, CodingKey {
            case type
            case clipName
            case startTime
            case duration
            case startClipTrim
            case endClipTrim
            case originalDuration
            case trackIndex
            case width
            case height
            case videoProperties
            case keyframes
            case effect
            case textContent
            case fontSize
            case textStyle
            case endTransition
            case endTransitionEnabled
            case isClipHasAudio
            case isMute
            case isLockedForTemplate
            case isReverse
            case removeBackground
            case audioVolume
            case additionalFFmpegCommand
            case sceneConfig
            case textureClipName
            case inAnimation
            case outAnimation
            case comboAnimation
        }
        
        init(clipName: String, startTime: Float, duration: Float, trackIndex: Int, type: ClipType, isClipHasAudio: Bool, width: Int, height: Int) {
            self.clipName = clipName
            self.startTime = startTime
            self.duration = duration
            self.originalDuration = duration
            self.trackIndex = trackIndex
            self.type = type
            self.isClipHasAudio = isClipHasAudio
            self.audioVolume = isClipHasAudio ? 1 : 0
            self.width = width
            self.height = height
            
            self.startClipTrim = 0
            self.endClipTrim = 0
            self.videoProperties = VideoProperties()
            self.keyframes = AnimatedProperty()
            self.endTransitionEnabled = false
            self.isMute = false
            self.isLockedForTemplate = false
            self.isReverse = false
        }
        
        required init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decodeIfPresent(ClipType.self, forKey: .type) ?? .video
            // Need to handle potential missing values for backward compatibility loosely
            self.clipName = try container.decodeIfPresent(String.self, forKey: .clipName) ?? ""
            self.startTime = try container.decodeIfPresent(Float.self, forKey: .startTime) ?? 0
            self.duration = try container.decodeIfPresent(Float.self, forKey: .duration) ?? 0
            self.startClipTrim = try container.decodeIfPresent(Float.self, forKey: .startClipTrim) ?? 0
            self.endClipTrim = try container.decodeIfPresent(Float.self, forKey: .endClipTrim) ?? 0
            self.originalDuration = try container.decodeIfPresent(Float.self, forKey: .originalDuration) ?? 0//self.duration
            self.trackIndex = try container.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0
            self.width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
            self.height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
            self.videoProperties = try container.decodeIfPresent(VideoProperties.self, forKey: .videoProperties) ?? VideoProperties()
            self.keyframes = try container.decodeIfPresent(AnimatedProperty.self, forKey: .keyframes) ?? AnimatedProperty()
            self.effect = try container.decodeIfPresent(EffectTemplate.self, forKey: .effect)
            self.textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
            self.fontSize = try container.decodeIfPresent(Float.self, forKey: .fontSize)
            // A style that can't be read must never cost the clip: fall back to the defaults.
            self.textStyle = try? container.decodeIfPresent(TextStyle.self, forKey: .textStyle)
            self.endTransition = try container.decodeIfPresent(TransitionClip.self, forKey: .endTransition)
            self.endTransitionEnabled = try container.decodeIfPresent(Bool.self, forKey: .endTransitionEnabled) ?? false
            self.isClipHasAudio = try container.decodeIfPresent(Bool.self, forKey: .isClipHasAudio) ?? false
            self.isMute = try container.decodeIfPresent(Bool.self, forKey: .isMute) ?? false
            self.isLockedForTemplate = try container.decodeIfPresent(Bool.self, forKey: .isLockedForTemplate) ?? false
            self.isReverse = try container.decodeIfPresent(Bool.self, forKey: .isReverse) ?? false
            self.audioVolume = try container.decodeIfPresent(Float.self, forKey: .audioVolume) ?? (self.isClipHasAudio ? 1 : 0)
            self.removeBackground = try container.decodeIfPresent(Bool.self, forKey: .removeBackground) ?? false
            self.additionalFFmpegCommand = try container.decodeIfPresent(String.self, forKey: .additionalFFmpegCommand)
            self.sceneConfig = try container.decodeIfPresent(String.self, forKey: .sceneConfig)
            self.textureClipName = try container.decodeIfPresent(String.self, forKey: .textureClipName)
            self.inAnimation = try container.decodeIfPresent(AnimationClip.self, forKey: .inAnimation) ?? AnimationClip()
            self.outAnimation = try container.decodeIfPresent(AnimationClip.self, forKey: .outAnimation) ?? AnimationClip()
            self.comboAnimation = try container.decodeIfPresent(AnimationClip.self, forKey: .comboAnimation) ?? AnimationClip()
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(clipName, forKey: .clipName)
            try container.encode(startTime, forKey: .startTime)
            try container.encode(duration, forKey: .duration)
            try container.encode(startClipTrim, forKey: .startClipTrim)
            try container.encode(endClipTrim, forKey: .endClipTrim)
            try container.encode(originalDuration, forKey: .originalDuration)
            try container.encode(trackIndex, forKey: .trackIndex)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(videoProperties, forKey: .videoProperties)
            try container.encode(keyframes, forKey: .keyframes)
            try container.encodeIfPresent(effect, forKey: .effect)
            try container.encodeIfPresent(textContent, forKey: .textContent)
            try container.encodeIfPresent(fontSize, forKey: .fontSize)
            try container.encodeIfPresent(textStyle, forKey: .textStyle)
            try container.encodeIfPresent(endTransition, forKey: .endTransition)
            try container.encode(endTransitionEnabled, forKey: .endTransitionEnabled)
            try container.encode(isClipHasAudio, forKey: .isClipHasAudio)
            try container.encode(isMute, forKey: .isMute)
            try container.encode(isLockedForTemplate, forKey: .isLockedForTemplate)
            try container.encode(isReverse, forKey: .isReverse)
            try container.encode(removeBackground, forKey: .removeBackground)
            try container.encode(audioVolume, forKey: .audioVolume)
            try container.encodeIfPresent(additionalFFmpegCommand, forKey: .additionalFFmpegCommand)
            try container.encodeIfPresent(sceneConfig, forKey: .sceneConfig)
            try container.encodeIfPresent(textureClipName, forKey: .textureClipName)
            try container.encode(inAnimation, forKey: .inAnimation)
            try container.encode(outAnimation, forKey: .outAnimation)
            try container.encode(comboAnimation, forKey: .comboAnimation)
        }
    }
    
    struct VideoProperties: Codable, Equatable {
        var valuePosX: Float = 0
        var valuePosY: Float = 0
        var valueRot: Float = 0
        var valueScaleX: Float = 1
        var valueScaleY: Float = 1
        /// Normalized pivot within the scaled clip [0 = left/top ... 1 = right/bottom].
        var valuePivotX: Float = 0
        var valuePivotY: Float = 0
        var valueOpacity: Float = 1
        var valueSpeed: Float = 1
        var valueVolume: Float = 1
        var valueHue: Float = 0
        var valueSaturation: Float = 1
        var valueBrightness: Float = 0
        var valueTemperature: Float = 6500
        
        /// Same order/cases as Android's VideoProperties.ValueType.
        enum ValueType: CaseIterable {
            case posX, posY, rot, rotInRadians, scaleX, scaleY, pivotX, pivotY, opacity, speed, volume, hue, saturation, brightness, temperature
        }
        
        init() {}
        
        // Old Android project JSON may lack newer fields (pivot, volume): fall back to defaults,
        // exactly what Gson does by leaving the field at its constructor value.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            valuePosX = try c.decodeIfPresent(Float.self, forKey: .valuePosX) ?? 0
            valuePosY = try c.decodeIfPresent(Float.self, forKey: .valuePosY) ?? 0
            valueRot = try c.decodeIfPresent(Float.self, forKey: .valueRot) ?? 0
            valueScaleX = try c.decodeIfPresent(Float.self, forKey: .valueScaleX) ?? 1
            valueScaleY = try c.decodeIfPresent(Float.self, forKey: .valueScaleY) ?? 1
            valuePivotX = try c.decodeIfPresent(Float.self, forKey: .valuePivotX) ?? 0
            valuePivotY = try c.decodeIfPresent(Float.self, forKey: .valuePivotY) ?? 0
            valueOpacity = try c.decodeIfPresent(Float.self, forKey: .valueOpacity) ?? 1
            valueSpeed = try c.decodeIfPresent(Float.self, forKey: .valueSpeed) ?? 1
            valueVolume = try c.decodeIfPresent(Float.self, forKey: .valueVolume) ?? 1
            valueHue = try c.decodeIfPresent(Float.self, forKey: .valueHue) ?? 0
            valueSaturation = try c.decodeIfPresent(Float.self, forKey: .valueSaturation) ?? 1
            valueBrightness = try c.decodeIfPresent(Float.self, forKey: .valueBrightness) ?? 0
            valueTemperature = try c.decodeIfPresent(Float.self, forKey: .valueTemperature) ?? 6500
        }
    }
    
    struct AnimatedProperty: Codable {
        var keyframes: [Keyframe] = []
    }
    
    struct Keyframe: Codable {
        var time: Float // seconds in local clip time
        var frame: Int64 = 0 // local clip frame (Android: reassignKeyframes)
        var value: VideoProperties
        var easing: EasingType
        
        init(time: Float, value: VideoProperties, easing: EasingType = .none, frame: Int64 = 0) {
            self.time = time
            self.value = value
            self.easing = easing
            self.frame = frame
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try c.decode(Float.self, forKey: .time)
            frame = try c.decodeIfPresent(Int64.self, forKey: .frame) ?? 0
            value = try c.decodeIfPresent(VideoProperties.self, forKey: .value) ?? VideoProperties()
            easing = try c.decodeIfPresent(EasingType.self, forKey: .easing) ?? .none
        }
    }
    
    enum EasingType: String, Codable, CaseIterable {
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = EasingType(rawValue: raw) ?? EasingType.none
        }

        case none = "NONE"
        case linear = "LINEAR"
        case easeInSine = "EASE_IN_SINE"
        case easeOutSine = "EASE_OUT_SINE"
        case easeInOutSine = "EASE_IN_OUT_SINE"
        case easeInQuad = "EASE_IN_QUAD"
        case easeOutQuad = "EASE_OUT_QUAD"
        case easeInOutQuad = "EASE_IN_OUT_QUAD"
        case easeInCubic = "EASE_IN_CUBIC"
        case easeOutCubic = "EASE_OUT_CUBIC"
        case easeInOutCubic = "EASE_IN_OUT_CUBIC"
        case easeInQuart = "EASE_IN_QUART"
        case easeOutQuart = "EASE_OUT_QUART"
        case easeInOutQuart = "EASE_IN_OUT_QUART"
        case easeInQuint = "EASE_IN_QUINT"
        case easeOutQuint = "EASE_OUT_QUINT"
        case easeInOutQuint = "EASE_IN_OUT_QUINT"
        case easeInExpo = "EASE_IN_EXPO"
        case easeOutExpo = "EASE_OUT_EXPO"
        case easeInOutExpo = "EASE_IN_OUT_EXPO"
        case easeInCirc = "EASE_IN_CIRC"
        case easeOutCirc = "EASE_OUT_CIRC"
        case easeInOutCirc = "EASE_IN_OUT_CIRC"
        case easeInBack = "EASE_IN_BACK"
        case easeOutBack = "EASE_OUT_BACK"
        case easeInOutBack = "EASE_IN_OUT_BACK"
        case easeInElastic = "EASE_IN_ELASTIC"
        case easeOutElastic = "EASE_OUT_ELASTIC"
        case easeInOutElastic = "EASE_IN_OUT_ELASTIC"
        case easeInBounce = "EASE_IN_BOUNCE"
        case easeOutBounce = "EASE_OUT_BOUNCE"
        case easeInOutBounce = "EASE_IN_OUT_BOUNCE"
    }

    /// Minimal JSON value so EffectTemplate.params (Java `Map<String, Object>`) round-trips
    /// instead of being silently dropped when iOS re-saves an Android-authored project.
    enum JSONValue: Codable, Equatable {
        case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
        
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
        }
        
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
    }

    /// Android writes `offset`, the desktop writes `startTime` for the same value. Read either,
    /// and write BOTH so a project can travel between Android, desktop and iOS without losing it
    /// (Gson ignores keys it doesn't know).
    struct EffectTemplate: Codable {
        var type: String?   // "transition", "overlay", etc (Android only)
        var style: String   // "fade", "zoom", "glitch"
        var duration: Double
        var offset: Double
        var params: [String: JSONValue]?  // Android only
        
        init(type: String? = nil, style: String, duration: Double, offset: Double, params: [String: JSONValue]? = nil) {
            self.type = type
            self.style = style
            self.duration = duration
            self.offset = offset
            self.params = params
        }
        
        enum CodingKeys: String, CodingKey { case type, style, duration, offset, startTime, params }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            style = try c.decodeIfPresent(String.self, forKey: .style) ?? "none"
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            offset = try c.decodeIfPresent(Double.self, forKey: .offset)
                ?? c.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
            params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params)
        }
        
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encode(style, forKey: .style)
            try c.encode(duration, forKey: .duration)
            try c.encode(offset, forKey: .offset)
            try c.encode(offset, forKey: .startTime)
            try c.encodeIfPresent(params, forKey: .params)
        }
    }
    
    struct TransitionClip: Codable {
        var trackIndex: Int
        var startTime: Float
        var duration: Float
        var effect: EffectTemplate
        var mode: TransitionMode
        
        enum TransitionMode: String, Codable {
            case endFirst = "END_FIRST"
            case overlap = "OVERLAP"
            case beginSecond = "BEGIN_SECOND"
            
            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = TransitionMode(rawValue: raw) ?? .overlap
            }
        }
    }
    
    // VideoSettings is serialized without Expose so we just serialize all fields directly
    struct VideoSettings: Codable {
        var videoWidth: Int
        var videoHeight: Int
        var frameRate: Int
        var crf: Int
        var bitrate: Int = 15
        var clipCap: Int
        var preset: String
        var tune: String
        var isStretchToFull: Bool
        var useHardwareAccel: Bool = true
        /// "ffmpeg" or "opengl". Old project JSON has no such field -> "ffmpeg" (matches Android loadSettings).
        var renderEngine: String = "ffmpeg"
        
        init(videoWidth: Int, videoHeight: Int, frameRate: Int, crf: Int, clipCap: Int, preset: String, tune: String, isStretchToFull: Bool) {
            self.videoWidth = videoWidth
            self.videoHeight = videoHeight
            self.frameRate = frameRate
            self.crf = crf
            self.clipCap = clipCap
            self.preset = preset
            self.tune = tune
            self.isStretchToFull = isStretchToFull
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            videoWidth = try c.decode(Int.self, forKey: .videoWidth)
            videoHeight = try c.decode(Int.self, forKey: .videoHeight)
            frameRate = try c.decode(Int.self, forKey: .frameRate)
            crf = try c.decode(Int.self, forKey: .crf)
            bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 15
            clipCap = try c.decode(Int.self, forKey: .clipCap)
            preset = try c.decode(String.self, forKey: .preset)
            tune = try c.decode(String.self, forKey: .tune)
            isStretchToFull = try c.decodeIfPresent(Bool.self, forKey: .isStretchToFull) ?? false
            useHardwareAccel = try c.decodeIfPresent(Bool.self, forKey: .useHardwareAccel) ?? true
            renderEngine = try c.decodeIfPresent(String.self, forKey: .renderEngine) ?? "ffmpeg"
        }
    }
}

extension EditingView.TransitionClip {
    enum CodingKeys: String, CodingKey { case trackIndex, startTime, duration, effect, mode }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decodeIfPresent(Float.self, forKey: .startTime) ?? 0
        let length = try c.decodeIfPresent(Float.self, forKey: .duration) ?? 0
        self.init(
            trackIndex: try c.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0,
            startTime: start,
            duration: length,
            effect: try c.decodeIfPresent(EditingView.EffectTemplate.self, forKey: .effect)
                ?? EditingView.EffectTemplate(style: "none", duration: Double(length), offset: Double(start)),
            mode: try c.decodeIfPresent(TransitionMode.self, forKey: .mode) ?? .overlap
        )
    }
}

