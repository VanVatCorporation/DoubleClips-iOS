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
            self.tracks = try container.decode([Track].self, forKey: .tracks)
            self.duration = try container.decode(Float.self, forKey: .duration)
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
            self.timelineIndex = try container.decode(Int.self, forKey: .timelineIndex)
            self.clips = try container.decode([Clip].self, forKey: .clips)
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
        
        @Published var endTransition: TransitionClip?
        @Published var endTransitionEnabled: Bool
        
        @Published var isClipHasAudio: Bool
        @Published var isMute: Bool
        @Published var isLockedForTemplate: Bool
        @Published var isReverse: Bool
        
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
            case endTransition
            case endTransitionEnabled
            case isClipHasAudio
            case isMute
            case isLockedForTemplate
            case isReverse
        }
        
        init(clipName: String, startTime: Float, duration: Float, trackIndex: Int, type: ClipType, isClipHasAudio: Bool, width: Int, height: Int) {
            self.clipName = clipName
            self.startTime = startTime
            self.duration = duration
            self.originalDuration = duration
            self.trackIndex = trackIndex
            self.type = type
            self.isClipHasAudio = isClipHasAudio
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
            self.type = try container.decode(ClipType.self, forKey: .type)
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
            self.endTransition = try container.decodeIfPresent(TransitionClip.self, forKey: .endTransition)
            self.endTransitionEnabled = try container.decodeIfPresent(Bool.self, forKey: .endTransitionEnabled) ?? false
            self.isClipHasAudio = try container.decodeIfPresent(Bool.self, forKey: .isClipHasAudio) ?? false
            self.isMute = try container.decodeIfPresent(Bool.self, forKey: .isMute) ?? false
            self.isLockedForTemplate = try container.decodeIfPresent(Bool.self, forKey: .isLockedForTemplate) ?? false
            self.isReverse = try container.decodeIfPresent(Bool.self, forKey: .isReverse) ?? false
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
            try container.encodeIfPresent(endTransition, forKey: .endTransition)
            try container.encode(endTransitionEnabled, forKey: .endTransitionEnabled)
            try container.encode(isClipHasAudio, forKey: .isClipHasAudio)
            try container.encode(isMute, forKey: .isMute)
            try container.encode(isLockedForTemplate, forKey: .isLockedForTemplate)
            try container.encode(isReverse, forKey: .isReverse)
        }
    }
    
    struct VideoProperties: Codable {
        var valuePosX: Float = 0
        var valuePosY: Float = 0
        var valueRot: Float = 0
        var valueScaleX: Float = 1
        var valueScaleY: Float = 1
        var valueOpacity: Float = 1
        var valueSpeed: Float = 1
        var valueHue: Float = 0
        var valueSaturation: Float = 1
        var valueBrightness: Float = 0
        var valueTemperature: Float = 6500
        
        enum ValueType {
            case posX, posY, rot, rotInRadians, scaleX, scaleY, opacity, speed, hue, saturation, brightness, temperature
        }
    }
    
    struct AnimatedProperty: Codable {
        var keyframes: [Keyframe] = []
    }
    
    struct Keyframe: Codable {
        var time: Float // seconds in local clip time
        var value: VideoProperties
        var easing: EasingType
    }
    
    enum EasingType: String, Codable {
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

    struct EffectTemplate: Codable {
        var type: String? // Optional in Android, usually not serialized
        var style: String
        var duration: Double
        var offset: Double
        // Map<String, Object> params not modeled fully here to avoid AnyCodable overhead if unused
        // We will default to empty dict if needed or drop it if not critical
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
        }
    }
    
    // VideoSettings is serialized without Expose so we just serialize all fields directly
    struct VideoSettings: Codable {
        var videoWidth: Int
        var videoHeight: Int
        var frameRate: Int
        var crf: Int
        var clipCap: Int
        var preset: String
        var tune: String
        var isStretchToFull: Bool
    }
}
