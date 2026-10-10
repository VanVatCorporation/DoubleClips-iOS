import Foundation

// MARK: - Clip animations (port of Android ClipAnimation / ClipAnimationFrame)
//
// One loaded clip animation (an "in" or an "out"): a set of channels, each a curve over progress
// p in [0, 1]. Immutable. Built by `ClipAnimationLoader` from a JSON file; nothing in here executes
// anything from the file: a curve is numbers plus one of three fixed formulas
// (constant / piecewise-linear knots / gaussian).
//
// Progress p is the animation's OWN time: for an "in" animation p = 0 at the clip's first frame;
// for an "out" animation p = 0 at the start of the out window and p = 1 at the clip's end.
// An out animation may be authored directly, or be the time-reverse of an in animation ("mirrorOf").

final class ClipAnimation {
    
    enum Direction: String, CaseIterable {
        case `in` = "in"
        case out = "out"
    }
    
    /// Every channel an animation may drive, with the same ranges as Android (enforced on load).
    /// BLUR is capped at 5 % of the canvas width (Android's blur shader is a fixed 17-tap kernel).
    enum Channel: Int, CaseIterable {
        case opacity, scale, offsetX, offsetY, rotation, hue, saturation, brightness, contrast
        case temperature, blur, warpTopWidth, warpBottomWidth, warpHeight
        /// iOS additions (no Android equivalent): see the notes in DoubleClips-Glitch-Blur-and-Shake-Slide-Notes.md.
        case motionBlur, edgeSlide
        /// More iOS additions, used by transition styles and Shake Slide: brightness MULTIPLIER, streak direction, horizontal
        /// squeeze toward an anchor, and "fill the canvas with the picture's edge pixels".
        case exposure, blurAngle, squeezeX, squeezeAnchor, edgeFill, edgeSlideY
        
        var json: String {
            switch self {
            case .opacity:         return "opacity"
            case .scale:           return "scale"
            case .offsetX:         return "offsetX"
            case .offsetY:         return "offsetY"
            case .rotation:        return "rotation"
            case .hue:             return "hue"
            case .saturation:      return "saturation"
            case .brightness:      return "brightness"
            case .contrast:        return "contrast"
            case .temperature:     return "temperature"
            case .blur:            return "blur"
            case .warpTopWidth:    return "warp.topWidth"
            case .warpBottomWidth: return "warp.bottomWidth"
            case .warpHeight:      return "warp.height"
            case .motionBlur:      return "motionBlur"
            case .edgeSlide:       return "edgeSlide"
            case .exposure:        return "exposure"
            case .blurAngle:       return "blurAngle"
            case .squeezeX:        return "squeezeX"
            case .squeezeAnchor:   return "squeezeAnchor"
            case .edgeFill:        return "edgeFill"
            case .edgeSlideY:      return "edgeSlideY"
            }
        }
        
        var neutral: Double {
            switch self {
            case .opacity, .scale, .saturation, .contrast, .warpTopWidth, .warpBottomWidth, .warpHeight, .exposure, .squeezeX: return 1
            case .squeezeAnchor: return 0.5
            default: return 0
            }
        }
        
        var min: Double {
            switch self {
            case .opacity: return 0
            case .scale: return 0.01
            case .offsetX, .offsetY: return -2
            case .rotation: return -3600
            case .hue: return -360
            case .saturation: return 0
            case .brightness: return -10
            case .contrast: return 0
            case .temperature: return -6000
            case .blur: return 0
            case .motionBlur: return 0
            case .edgeSlide, .edgeSlideY: return -2
            case .exposure: return 0
            case .blurAngle: return -180
            case .squeezeX: return 0.02
            case .squeezeAnchor, .edgeFill: return 0
            case .warpTopWidth, .warpBottomWidth, .warpHeight: return 0.1
            }
        }
        
        var max: Double {
            switch self {
            case .opacity: return 1
            case .scale: return 10
            case .offsetX, .offsetY: return 2
            case .rotation: return 3600
            case .hue: return 360
            case .saturation: return 10
            case .brightness: return 10
            case .contrast: return 10
            case .temperature: return 6000
            case .blur: return 0.05
            case .motionBlur: return 1
            case .edgeSlide, .edgeSlideY: return 2
            case .exposure: return 4
            case .blurAngle: return 180
            case .squeezeX: return 2
            case .squeezeAnchor, .edgeFill: return 1
            case .warpTopWidth, .warpBottomWidth, .warpHeight: return 2
            }
        }
        
        static func fromJSON(_ s: String) -> Channel? {
            allCases.first { $0.json == s }
        }
    }
    
    // MARK: Curves (three fixed kinds only)
    
    enum Curve {
        case constant(Double)
        /// Piecewise-linear (or smoothstep-eased) through (p, value) knots, p strictly increasing.
        /// Holds the first value before the first knot and the last value after the last.
        case knots(ps: [Double], vs: [Double], smooth: Bool)
        /// base + peak * envelope(p), envelope(p) = (exp(-(p/tau)^2) - tail) / (1 - tail) with
        /// tail = exp(-(1/tau)^2): exactly 1 at p = 0 and exactly 0 at p = 1.
        case gaussian(base: Double, peak: Double, tau: Double)
        
        func at(_ p: Double) -> Double {
            switch self {
            case .constant(let value):
                return value
            case .knots(let ps, let vs, let smooth):
                let last = ps.count - 1
                if p <= ps[0] { return vs[0] }
                if p >= ps[last] { return vs[last] }
                var i = 1
                while ps[i] < p { i += 1 }          // first knot at or after p; i >= 1 here
                var t = (p - ps[i - 1]) / (ps[i] - ps[i - 1])
                if smooth { t = t * t * (3.0 - 2.0 * t) }
                return vs[i - 1] + (vs[i] - vs[i - 1]) * t
            case .gaussian(let base, let peak, let tau):
                let tail = exp(-(1.0 / tau) * (1.0 / tau))
                let env = (exp(-(p / tau) * (p / tau)) - tail) / (1.0 - tail)
                return base + peak * env
            }
        }
    }
    
    // MARK: The animation
    
    let id: String
    let name: String
    let direction: Direction
    /// Suggested duration in seconds (the editor's duration field default for this animation).
    let defaultDuration: Float
    /// True if p is flipped (1 - p) before sampling the curves (a "mirrorOf" animation).
    let reversed: Bool
    let referenceFrames: Int
    private let curves: [Channel: Curve]
    private let activeChannels: [Channel]
    
    init(id: String, name: String, direction: Direction, defaultDuration: Float,
         curves: [Channel: Curve], reversed: Bool, referenceFrames: Int) {
        self.id = id
        self.name = name
        self.direction = direction
        self.defaultDuration = defaultDuration
        self.reversed = reversed
        self.referenceFrames = referenceFrames
        self.curves = curves
        self.activeChannels = curves.keys.sorted { $0.rawValue < $1.rawValue }
    }
    
    /// The time-reverse of `base`, sharing its curves, as a new animation.
    static func mirror(of base: ClipAnimation, id: String, name: String,
                       direction: Direction, defaultDuration: Float) -> ClipAnimation {
        ClipAnimation(id: id, name: name, direction: direction, defaultDuration: defaultDuration,
                      curves: base.curves, reversed: !base.reversed, referenceFrames: base.referenceFrames)
    }
    
    /// The channels this animation drives (the rest stay neutral).
    var channels: Set<Channel> { Set(curves.keys) }
    func curve(for channel: Channel) -> Curve? { curves[channel] }
    
    /// Channel values at progress p. p < 0 (or NaN) means "not inside the animation window" and
    /// returns `.neutral`; p > 1 is held at 1.
    func evaluate(_ p: Float) -> ClipAnimationFrame {
        if p < 0 || p.isNaN { return .neutral }
        var q = p > 1 ? 1.0 : Double(p)
        if reversed { q = 1.0 - q }
        var values = ClipAnimationFrame.neutralValues
        for channel in activeChannels {
            if let curve = curves[channel] { values[channel.rawValue] = Float(curve.at(q)) }
        }
        return ClipAnimationFrame(values: values, isNeutral: false)
    }
    
    // MARK: Progress helpers
    
    /// Progress of an IN animation: elapsed seconds since the clip's first frame over the
    /// animation's duration, or -1 outside [0, duration).
    static func progress(elapsed: Float, duration: Float) -> Float {
        if duration <= 0 || elapsed < 0 || elapsed >= duration { return -1 }
        return elapsed / duration
    }
    
    /// Progress of an OUT animation: -1 before the window opens at (clipEnd - duration), then
    /// rising 0 → 1 at the clip's last frame, and HELD at 1 from the clip's end on (the outgoing
    /// clip of a transition keeps being drawn past its nominal end).
    static func progressOut(clipEnd: Float, t: Float, duration: Float) -> Float {
        if duration <= 0 { return -1 }
        let elapsed = t - (clipEnd - duration)
        if elapsed < 0 { return -1 }
        return elapsed >= duration ? 1 : elapsed / duration
    }
    
    /// Shrinks `duration` so it and the clip's other animation fit inside the clip together: when
    /// duration + otherDuration exceeds clipDuration both are scaled by the same factor.
    static func fitDuration(_ duration: Float, other otherDuration: Float, clip clipDuration: Float) -> Float {
        if !(duration > 0) { return 0 }
        let other: Float = otherDuration > 0 ? otherDuration : 0
        let total = duration + other
        if !(clipDuration > 0) || total <= clipDuration { return duration }
        return duration * clipDuration / total
    }
}

// MARK: - One frame of channel values

/// The values of every animatable channel for ONE output frame. A channel an animation does not
/// define sits at its neutral value, so "no animation" and "outside its window" are both `.neutral`.
///
/// How each value combines with the clip's own (keyframed) properties is fixed in code, never
/// chosen by an animation file (see ClipCompositor.place):
///   additive       offsetX, offsetY, rotation, hue, brightness, temperature
///   multiplicative opacity, scale, saturation
///   standalone     contrast, blur, warp.* (the clip itself has no such property)
struct ClipAnimationFrame {
    fileprivate let values: [Float]
    let isNeutral: Bool
    
    fileprivate static let neutralValues: [Float] = ClipAnimation.Channel.allCases.map { Float($0.neutral) }
    static let neutral = ClipAnimationFrame(values: neutralValues, isNeutral: true)
    
    func value(_ channel: ClipAnimation.Channel) -> Float { values[channel.rawValue] }
    
    /// Multiplier, 1 = unchanged.
    var opacity: Float { value(.opacity) }
    /// Uniform scale multiplier about the clip's pivot, 1 = unchanged.
    var scale: Float { value(.scale) }
    /// Offset as a fraction of the canvas WIDTH (+ = right).
    var offsetX: Float { value(.offsetX) }
    /// Offset as a fraction of the canvas HEIGHT (+ = down).
    var offsetY: Float { value(.offsetY) }
    /// Extra rotation in degrees.
    var rotationDegrees: Float { value(.rotation) }
    /// Extra hue rotation in degrees.
    var hueDegrees: Float { value(.hue) }
    /// Multiplier, 1 = unchanged.
    var saturation: Float { value(.saturation) }
    /// Additive, same -10..10 scale as Android's VideoProperties.Brightness.
    var brightness: Float { value(.brightness) }
    /// Multiplier about mid-grey, 1 = unchanged.
    var contrast: Float { value(.contrast) }
    /// Additive colour-temperature offset in Kelvin (0 = unchanged).
    var temperatureKelvin: Float { value(.temperature) }
    /// Gaussian blur sigma as a fraction of the canvas WIDTH (0 = none).
    var blurWidthFraction: Float { value(.blur) }
    /// Horizontal motion blur, total streak length as a fraction of the canvas WIDTH (0 = none).
    var motionBlurWidthFraction: Float { value(.motionBlur) }
    /// The picture slides sideways INSIDE its own box (fraction of canvas width, + = right) and the edge
    /// pixels are stretched into the gap it leaves, instead of the gap showing what is behind.
    var edgeSlideFraction: Float { value(.edgeSlide) }
    /// Like `edgeSlide` but vertical (fraction of canvas HEIGHT, + = down, so a negative value moves the picture's pixels up).
    var edgeSlideYFraction: Float { value(.edgeSlideY) }
    /// Brightness MULTIPLIER on the colours (1 = unchanged, 0.32 = the dark hit of Glitch Blur).
    var exposure: Float { value(.exposure) }
    /// Direction of the motion-blur streaks, degrees counter-clockwise from the right (0 = horizontal).
    var blurAngleDegrees: Float { value(.blurAngle) }
    /// Horizontal squeeze of the picture toward its anchor (1 = unchanged); the edge pixels smear into the gap.
    var squeezeX: Float { value(.squeezeX) }
    /// Where the squeeze holds still: 0 = the picture's left edge, 1 = its right edge.
    var squeezeAnchor: Float { value(.squeezeAnchor) }
    /// 1 = after placing the picture, extend its edge pixels over the whole canvas (a shrunken picture leaves no black margin).
    var edgeFill: Float { value(.edgeFill) }
    /// Top-edge width of the top-centre-anchored squish, 1 = unchanged.
    var warpTopWidth: Float { value(.warpTopWidth) }
    /// Bottom-edge width of the squish, 1 = unchanged.
    var warpBottomWidth: Float { value(.warpBottomWidth) }
    /// Height of the squish (top edge fixed), 1 = unchanged.
    var warpHeight: Float { value(.warpHeight) }
    
    var hasWarp: Bool { warpTopWidth != 1 || warpBottomWidth != 1 || warpHeight != 1 }
}

// MARK: - Combining two frames (a transition style's side + the clip's own In / Out animation)

extension ClipAnimationFrame {
    /// `self` combined with `other` (nil = unchanged), channel by channel with the same rules the compositor uses
    /// for a clip's own properties: additive channels add, multiplicative ones multiply (all clamped to their
    /// range); the streak angle follows the longer streak, the squeeze anchor follows the stronger squeeze,
    /// edge fill takes the larger.
    func merged(with other: ClipAnimationFrame?) -> ClipAnimationFrame {
        guard let other, !other.isNeutral else { return self }
        if isNeutral { return other }
        var out = values
        for channel in ClipAnimation.Channel.allCases {
            let i = channel.rawValue
            let a = Double(values[i]), b = Double(other.values[i])
            let combined: Double
            switch channel {
            case .offsetX, .offsetY, .rotation, .hue, .brightness, .temperature, .edgeSlide, .edgeSlideY, .motionBlur, .blur:
                combined = a + b
            case .opacity, .scale, .saturation, .contrast, .exposure, .warpTopWidth, .warpBottomWidth, .warpHeight, .squeezeX:
                combined = a * b
            case .blurAngle:
                combined = motionBlurWidthFraction >= other.motionBlurWidthFraction ? a : b
            case .squeezeAnchor:
                combined = abs(squeezeX - 1) >= abs(other.squeezeX - 1) ? a : b
            case .edgeFill:
                combined = Swift.max(a, b)
            }
            out[i] = Float(Swift.min(Swift.max(combined, channel.min), channel.max))
        }
        return ClipAnimationFrame(values: out, isNeutral: false)
    }
}

// MARK: - Scaling a frame (effect strength)

extension ClipAnimationFrame {
    /// Every channel's distance from its neutral value times `amount` (1 = as authored, 0 = nothing), clamped to the
    /// channel's range. Used for an effect's strength slider: a push of 12% becomes 24% at 2. The streak direction, the
    /// squeeze anchor and edge fill describe HOW, not how much, so they are left alone.
    func scaledDeviation(_ amount: Float) -> ClipAnimationFrame {
        if isNeutral || abs(amount - 1) < 0.0001 { return self }
        var out = values
        for channel in ClipAnimation.Channel.allCases {
            switch channel {
            case .blurAngle, .squeezeAnchor, .edgeFill: continue
            default:
                let i = channel.rawValue
                let n = Float(channel.neutral)
                out[i] = Swift.min(Swift.max(n + (values[i] - n) * amount, Float(channel.min)), Float(channel.max))
            }
        }
        return ClipAnimationFrame(values: out, isNeutral: false)
    }
}
