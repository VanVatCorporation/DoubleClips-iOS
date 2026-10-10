import Foundation

// MARK: - Filter ops for effect styles (animations/effects/*.json -> "filters")
//
//   "filters": [ { "op": "vignette", "intensity": 1.2, "radius": 1.4 },
//                { "op": "blur", "radius": { "kind": "knots", "interp": "smooth", "points": [[0, 0], [1, 0.02]] } } ],
//   "filterStrength": "scale"     // "scale" (default) | "mix" | "both" | "none"
//
// An effect style may list filters in addition to (or instead of) its channels. Channels are applied first (scale, offset,
// colour...), then the filters in order. Every parameter is a number or a curve ("constant" / "knots", p = 0...1 over the
// clip, or looped over the style's `period`, or run over its `span`), validated against the ranges in the registry
// (`EffectFilterSpecs.swift`, generated). Which ops exist is fixed in the app: JSON can pick, order and parameterize them,
// not invent new ones. Distances are fractions of the canvas (height, width or min(width, height); see each op).
//
// The effect's strength slider acts on the filters as `filterStrength` says:
//   scale  every parameter marked `scaled` moves from its neutral value by strength x (a vignette of 1.2 becomes 2.4 at 2)
//   mix    the result of the whole filter chain is blended over the picture before it, by strength (full at 1 and above)
//   both   scale, then mix        none   the slider doesn't change the filters
//
// Ops: blur(radius: h) colorControls(brightness, contrast, saturation) photoEffect(name) sepia(intensity)
//      vignette(intensity, radius) bloom(radius: h, intensity) pixellate(scale: h) dotScreen(width: h, angle, sharpness)
//      kaleidoscope(count, angle: radians) twirl(radius: min side, angle: radians) bump(radius: min side, scale)
//      rgbShift(dx: w, flag randomSign) tearSlices(amount) crossProcess vhs(amount)

struct EffectFilterParam {
    let name: String
    /// Used when the file leaves the parameter out.
    let def: Double
    /// "No effect" value: the strength slider scales the distance from here.
    let neutral: Double
    let min: Double
    let max: Double
    let scaled: Bool
}

struct EffectFilterString {
    let allowed: [String]
    let def: String
}

struct EffectFilterSpec {
    let params: [EffectFilterParam]
    let flags: [String]
    let strings: [String: EffectFilterString]
}

enum EffectFilterStrength: String {
    case scale, mix, both, none
    var scales: Bool { self == .scale || self == .both }
    var mixes: Bool { self == .mix || self == .both }
}

enum EffectFilterCurve {
    case constant(Double)
    /// Piecewise-linear (or smoothstep-eased) through (p, value) knots, p strictly increasing; holds the first / last value outside.
    case knots(ps: [Double], vs: [Double], smooth: Bool)
    
    func at(_ t: Double) -> Double {
        switch self {
        case .constant(let v):
            return v
        case .knots(let ps, let vs, let smooth):
            if t <= ps[0] { return vs[0] }
            if t >= ps[ps.count - 1] { return vs[vs.count - 1] }
            var i = 1
            while i < ps.count - 1 && t > ps[i] { i += 1 }
            let u = (t - ps[i - 1]) / (ps[i] - ps[i - 1])
            let k = smooth ? u * u * (3 - 2 * u) : u
            return vs[i - 1] + (vs[i] - vs[i - 1]) * k
        }
    }
}

struct EffectFilter {
    let op: String
    let curves: [String: EffectFilterCurve]
    let flags: Set<String>
    let strings: [String: String]
}

enum EffectFilterOps {
    static let maxFilters = 16
    static let maxKnots = 512
    
    static func parse(_ value: Any?, path: String) throws -> [EffectFilter] {
        typealias L = ClipAnimationLoader
        guard let array = value as? [Any] else {
            throw ClipAnimationFormatError("\(path): must be an array of filter objects")
        }
        guard array.count <= maxFilters else {
            throw ClipAnimationFormatError("\(path): at most \(maxFilters) filters")
        }
        var out: [EffectFilter] = []
        for (i, item) in array.enumerated() {
            let p = "\(path)[\(i)]"
            let object = try L.asObject(item, p)
            let op = try L.reqString(object, "op", p, 24)
            guard let spec = specs[op] else {
                throw ClipAnimationFormatError("\(p).op: unknown filter '\(op)'")
            }
            var allowed: Set<String> = ["op"]
            spec.params.forEach { allowed.insert($0.name) }
            spec.flags.forEach { allowed.insert($0) }
            spec.strings.keys.forEach { allowed.insert($0) }
            try L.allowKeys(object, p, allowed)
            
            var curves: [String: EffectFilterCurve] = [:]
            for param in spec.params {
                let path = "\(p).\(param.name)"
                guard let raw = object[param.name] else {
                    curves[param.name] = .constant(param.def)
                    continue
                }
                if let m = raw as? [String: Any] {
                    curves[param.name] = try parseCurve(m, param, path)
                } else {
                    let v = try L.reqNumber(object, param.name, p)
                    try check(v, param, path)
                    curves[param.name] = .constant(v)
                }
            }
            var flags = Set<String>()
            for flag in spec.flags {
                guard let raw = object[flag] else { continue }
                guard let on = raw as? Bool else {
                    throw ClipAnimationFormatError("\(p).\(flag): must be true or false")
                }
                if on { flags.insert(flag) }
            }
            var strings: [String: String] = [:]
            for (key, option) in spec.strings {
                if object[key] == nil { strings[key] = option.def; continue }
                let v = try L.reqString(object, key, p, 24)
                guard option.allowed.contains(v) else {
                    throw ClipAnimationFormatError("\(p).\(key): must be one of \(option.allowed.joined(separator: ", "))")
                }
                strings[key] = v
            }
            out.append(EffectFilter(op: op, curves: curves, flags: flags, strings: strings))
        }
        return out
    }
    
    private static func check(_ v: Double, _ param: EffectFilterParam, _ path: String) throws {
        guard v.isFinite, v >= param.min, v <= param.max else {
            throw ClipAnimationFormatError("\(path): \(ClipAnimationLoader.fmt(v)) is outside \(ClipAnimationLoader.fmt(param.min)) ... \(ClipAnimationLoader.fmt(param.max))")
        }
    }
    
    private static func parseCurve(_ m: [String: Any], _ param: EffectFilterParam, _ path: String) throws -> EffectFilterCurve {
        typealias L = ClipAnimationLoader
        let kind = try L.reqString(m, "kind", path, 16)
        switch kind {
        case "constant":
            try L.allowKeys(m, path, ["kind", "value"])
            let v = try L.reqNumber(m, "value", path)
            try check(v, param, path + ".value")
            return .constant(v)
        case "knots":
            try L.allowKeys(m, path, ["kind", "interp", "points"])
            var smooth = false
            if m["interp"] != nil {
                let interp = try L.reqString(m, "interp", path, 16)
                guard interp == "linear" || interp == "smooth" else {
                    throw ClipAnimationFormatError("\(path).interp: must be \"linear\" or \"smooth\"")
                }
                smooth = interp == "smooth"
            }
            guard let raw = m["points"] as? [Any], !raw.isEmpty, raw.count <= maxKnots else {
                throw ClipAnimationFormatError("\(path).points: needs 1 to \(maxKnots) [p, value] pairs")
            }
            var ps: [Double] = [], vs: [Double] = []
            for (i, item) in raw.enumerated() {
                guard let pair = item as? [Any], pair.count == 2, let p = pair[0] as? Double, let v = pair[1] as? Double else {
                    throw ClipAnimationFormatError("\(path).points[\(i)]: must be [p, value]")
                }
                guard p >= 0, p <= 1, ps.isEmpty || p > ps[ps.count - 1] else {
                    throw ClipAnimationFormatError("\(path).points[\(i)]: p must be 0...1 and increasing")
                }
                try check(v, param, "\(path).points[\(i)]")
                ps.append(p); vs.append(v)
            }
            return .knots(ps: ps, vs: vs, smooth: smooth)
        default:
            throw ClipAnimationFormatError("\(path).kind: must be \"constant\" or \"knots\"")
        }
    }
}
