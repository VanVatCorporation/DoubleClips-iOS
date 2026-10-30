import SwiftUI
import CoreImage

// MARK: - Chroma keys (the clip's "Background" panel, ported from desktop)
//
// A chroma key is a colour that is made transparent, so what is behind the clip shows through (a green screen). A clip can carry
// several (up to `ChromaKey.maxKeys`); a pixel that matches ANY of them goes away. Each key has CapCut's four controls, 0...100:
//   - intensity:   how wide the range of colours around the picked one that is removed (a tolerance);
//   - shadow:      also removes the darker shades of the picked colour (the shadows falling on the screen);
//   - feather:     how soft the edge of what stays is;
//   - cleanUpEdge: shrinks the edge a little and takes the key colour's tint off the pixels along it (the green fringe).
//
// Persistence is desktop's, so a project moves between the two without losing its keys:
//   - clip JSON key `chromaKeys`: [{enabled, color "#RRGGBB", intensity, shadow, feather, cleanUpEdge}], absent = none;
//   - each slider can be keyframed in the clip's ordinary `keyframes`: the keyframe lists the channel in `channels`
//     ("chromaIntensity0", "chromaShadow2", "chromaFeather1", "chromaCleanUp5": slider + the key's place in the list) and carries
//     the value in its `value.valueChroma` (6 keys x 4 sliders, key-major). Only a keyframe that names a chroma channel holds it.
//
// Rendering (EditingView+Compositor.swift calls `applyChromaKeys`) works on the clip's own picture, before the colour grade, the
// masks and the transform, in preview and export alike. It is the colour-cube recipe from Apple's Core Image docs: per key one
// 64^3 cube turns every colour into "how much of it is kept", evaluated with desktop's own maths (distance in the BT.601 chroma
// plane, so brightness matters little), then the kept amounts of all keys are multiplied.

extension EditingView {
    
    struct ChromaKey: Codable, Equatable {
        static let maxKeys = 6
        static let paramCount = 4
        static let scaleMax: Float = 100
        static let defaultColor = "#00FF00"
        static let defaultIntensity: Float = 20
        
        /// A switched-off key is kept (and can be switched on again) but doesn't key.
        var enabled = true
        /// "#RRGGBB".
        var color = ChromaKey.defaultColor
        var intensity: Float = ChromaKey.defaultIntensity
        var shadow: Float = 0
        var feather: Float = 0
        var cleanUpEdge: Float = 0
        
        init() {}
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? Self.defaultColor
            intensity = Self.clamped(try c.decodeIfPresent(Float.self, forKey: .intensity) ?? Self.defaultIntensity)
            shadow = Self.clamped(try c.decodeIfPresent(Float.self, forKey: .shadow) ?? 0)
            feather = Self.clamped(try c.decodeIfPresent(Float.self, forKey: .feather) ?? 0)
            cleanUpEdge = Self.clamped(try c.decodeIfPresent(Float.self, forKey: .cleanUpEdge) ?? 0)
        }
        
        private static func clamped(_ v: Float) -> Float {
            v.isNaN ? 0 : min(max(v, 0), scaleMax)
        }
        
        func get(_ param: ChromaParam) -> Float {
            switch param {
            case .intensity: return intensity
            case .shadow: return shadow
            case .feather: return feather
            case .cleanUp: return cleanUpEdge
            }
        }
        
        mutating func set(_ param: ChromaParam, _ value: Float) {
            let v = Self.clamped(value)
            switch param {
            case .intensity: intensity = v
            case .shadow: shadow = v
            case .feather: feather = v
            case .cleanUp: cleanUpEdge = v
            }
        }
        
        /// The colour as r, g, b in 0...1; the default green when the text isn't a "#RRGGBB" ("#RRGGBBAA" is read without its alpha).
        var rgb: (r: Float, g: Float, b: Float) {
            var value = Self.parse(color)
            if value < 0 { value = Self.parse(Self.defaultColor) }
            return (Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255, Float(value & 0xFF) / 255)
        }
        
        private static func parse(_ hex: String) -> Int {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            if s.count == 8 { s = String(s.prefix(6)) }
            guard s.count == 6, let v = Int(s, radix: 16) else { return -1 }
            return v
        }
        
        static func toHex(r: Float, g: Float, b: Float) -> String {
            func byte(_ v: Float) -> Int { Int((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        }
        
        /// A key as the render thread takes it: colour 0...1 and the four sliders 0...1, with keyframes already applied.
        struct Resolved: Equatable {
            var r: Float, g: Float, b: Float
            var intensity: Float, shadow: Float, feather: Float, cleanUp: Float
        }
        
        /// The enabled keys of a clip at a global time (their keyframed sliders resolved), at most `maxKeys`. A key keeps its place in
        /// the clip's list for its keyframes, switched on or off.
        static func resolve(_ keys: [ChromaKey], keyframes: AnimatedProperty, clipStartTime: Float, at time: Float) -> [Resolved] {
            var out: [Resolved] = []
            let blank = VideoProperties()
            for (index, key) in keys.enumerated() where index < maxKeys && key.enabled {
                var values = [key.intensity, key.shadow, key.feather, key.cleanUpEdge]
                if !keyframes.keyframes.isEmpty {
                    for p in 0..<paramCount {
                        let type = VideoProperties.ValueType.chromaTypes[index * paramCount + p]
                        if keyframes.isAnimated(type) {
                            values[p] = keyframes.value(for: type, base: blank, clipStartTime: clipStartTime, at: time)
                        }
                    }
                }
                func unit(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v / scaleMax, 0), 1) }
                let c = key.rgb
                out.append(Resolved(r: c.r, g: c.g, b: c.b, intensity: unit(values[0]), shadow: unit(values[1]),
                                    feather: unit(values[2]), cleanUp: unit(values[3])))
            }
            return out
        }
    }
    
    /// The four sliders of a key, in the order of `valueChroma` and of the channel names.
    enum ChromaParam: Int, CaseIterable {
        case intensity, shadow, feather, cleanUp
        
        /// English name (also the keyframe list's label); the panel runs it through `L`.
        var title: String {
            switch self {
            case .intensity: return "Intensity"
            case .shadow: return "Shadow"
            case .feather: return "Feather edge"
            case .cleanUp: return "Clean up edge"
            }
        }
    }
}

// MARK: - The keyframe channels of the sliders

extension EditingView.VideoProperties.ValueType {
    
    /// The 24 chroma channels in `valueChroma` order (key-major).
    static let chromaTypes: [EditingView.VideoProperties.ValueType] = [.chromaIntensity0, .chromaShadow0, .chromaFeather0, .chromaCleanUp0, .chromaIntensity1, .chromaShadow1, .chromaFeather1, .chromaCleanUp1, .chromaIntensity2, .chromaShadow2, .chromaFeather2, .chromaCleanUp2, .chromaIntensity3, .chromaShadow3, .chromaFeather3, .chromaCleanUp3, .chromaIntensity4, .chromaShadow4, .chromaFeather4, .chromaCleanUp4, .chromaIntensity5, .chromaShadow5, .chromaFeather5, .chromaCleanUp5]
    
    /// 0...23 = this channel's place in `valueChroma`; nil for every other property.
    var chromaSlot: Int? {
        switch self {
        case .chromaIntensity0: return 0
        case .chromaShadow0: return 1
        case .chromaFeather0: return 2
        case .chromaCleanUp0: return 3
        case .chromaIntensity1: return 4
        case .chromaShadow1: return 5
        case .chromaFeather1: return 6
        case .chromaCleanUp1: return 7
        case .chromaIntensity2: return 8
        case .chromaShadow2: return 9
        case .chromaFeather2: return 10
        case .chromaCleanUp2: return 11
        case .chromaIntensity3: return 12
        case .chromaShadow3: return 13
        case .chromaFeather3: return 14
        case .chromaCleanUp3: return 15
        case .chromaIntensity4: return 16
        case .chromaShadow4: return 17
        case .chromaFeather4: return 18
        case .chromaCleanUp4: return 19
        case .chromaIntensity5: return 20
        case .chromaShadow5: return 21
        case .chromaFeather5: return 22
        case .chromaCleanUp5: return 23
        default: return nil
        }
    }
    
    var isChroma: Bool { chromaSlot != nil }
    /// Which key of the clip's list (0-based) this slider belongs to.
    var chromaKey: Int? { chromaSlot.map { $0 / EditingView.ChromaKey.paramCount } }
    var chromaParam: EditingView.ChromaParam? { chromaSlot.flatMap { EditingView.ChromaParam(rawValue: $0 % EditingView.ChromaKey.paramCount) } }
    
    /// The channel of slider `param` of key number `key`.
    static func chroma(_ key: Int, _ param: EditingView.ChromaParam) -> EditingView.VideoProperties.ValueType? {
        guard key >= 0, key < EditingView.ChromaKey.maxKeys else { return nil }
        return chromaTypes[key * EditingView.ChromaKey.paramCount + param.rawValue]
    }
}

// MARK: - Keeping the keyframes in step with the key list

extension EditingView.AnimatedProperty {
    
    /// Call right after the key at `removed` was taken out of the clip's list: the sliders of the keys after it move down one place
    /// (which keyframes hold them and the values they keyed), the last place is freed, and a keyframe that held nothing but sliders
    /// of the removed key is deleted. Without it a keyframe would go on animating the wrong colour.
    mutating func chromaKeyRemoved(_ removed: Int) {
        typealias PropertyType = EditingView.VideoProperties.ValueType
        let maxKeys = EditingView.ChromaKey.maxKeys
        for i in keyframes.indices {
            guard keyframes[i].channels?.contains(where: { $0.isChroma }) == true else { continue }
            for param in EditingView.ChromaParam.allCases {
                for place in removed..<maxKeys {
                    guard let to = PropertyType.chroma(place, param) else { continue }
                    if place + 1 < maxKeys, let from = PropertyType.chroma(place + 1, param) {
                        let holds = keyframes[i].animates(from)
                        let value = keyframes[i].value.value(from)
                        keyframes[i].animate(to, holds)
                        keyframes[i].value.setValue(holds ? value : 0, to)
                    } else {
                        keyframes[i].animate(to, false)
                        keyframes[i].value.setValue(0, to)
                    }
                }
            }
        }
        keyframes.removeAll { $0.channels?.isEmpty == true }
    }
    
    /// All keyframes of the key at `index` go (its sliders are plain values again); emptied keyframes are deleted.
    mutating func clearChromaKey(_ index: Int) {
        for i in keyframes.indices {
            for param in EditingView.ChromaParam.allCases {
                guard let type = EditingView.VideoProperties.ValueType.chroma(index, param) else { continue }
                keyframes[i].animate(type, false)
                keyframes[i].value.setValue(0, type)
            }
        }
        keyframes.removeAll { $0.channels?.isEmpty == true }
    }
}

// MARK: - Colour cubes

extension EditingView {
    
    /// The lookup tables the keying runs on, built from the key's numbers and cached (a drag or an animated slider asks for a new one
    /// per step, so the numbers are rounded to 1/400 and a table is built on all cores).
    enum ChromaCubes {
        static let dimension = 64
        private static let cache: NSCache<NSString, NSData> = {
            let c = NSCache<NSString, NSData>()
            c.totalCostLimit = 96 * 1024 * 1024
            return c
        }()
        
        private struct SharedPointer: @unchecked Sendable { let pointer: UnsafeMutablePointer<Float> }
        
        // BT.601 chroma plane (U, V): the same matrix the colour grade uses.
        private static func chroma(_ r: Float, _ g: Float, _ b: Float) -> (u: Float, v: Float) {
            (-0.14713 * r - 0.28886 * g + 0.43600 * b, 0.61500 * r - 0.51499 * g - 0.10001 * b)
        }
        private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.299 * r + 0.587 * g + 0.114 * b }
        
        /// sRGB-encodes a linear 0...1 number: the keep amount is written this way into the table, because the table's colour space is
        /// sRGB and Core Image turns what it reads back into linear light, which gives the keep amount itself.
        private static func encode(_ v: Float) -> Float {
            v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        
        private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / max(e1 - e0, 1e-6), 0), 1)
            return t * t * (3 - 2 * t)
        }
        
        private static func quantized(_ v: Float) -> Int { Int((v * 400).rounded()) }
        private static func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        
        /// A grey table: how much of each colour is KEPT by this key (0 = removed, 1 = kept), desktop's `keyKeep`.
        static func keepCube(_ key: ChromaKey.Resolved) -> Data {
            let qi = quantized(key.intensity), qs = quantized(key.shadow), qf = quantized(key.feather)
            let id = NSString(string: "k|\(byte(key.r))|\(byte(key.g))|\(byte(key.b))|\(qi)|\(qs)|\(qf)")
            if let hit = cache.object(forKey: id) { return hit as Data }
            
            let intensity = Float(qi) / 400, shadow = Float(qs) / 400, feather = Float(qf) / 400
            let kr = Float(byte(key.r)) / 255, kg = Float(byte(key.g)) / 255, kb = Float(byte(key.b)) / 255
            let kc = chroma(kr, kg, kb)
            let keyLuma = luma(kr, kg, kb)
            let kk = kc.u * kc.u + kc.v * kc.v
            let tolerance = intensity * 0.5                 // chroma distance removed at intensity 1
            let softEnd = tolerance + 0.02 + feather * 0.3   // softness of the edge: 0.02 at feather 0, 0.32 at feather 1
            let shadowSpan: Float = 0.8                     // at shadow 1, shades down to 20 % of the key's chroma still count
            
            let n = dimension
            var table = [Float](repeating: 1, count: n * n * n * 4)
            table.withUnsafeMutableBufferPointer { buffer in
                let shared = SharedPointer(pointer: buffer.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: n) { bi in
                    let p = shared.pointer
                    let b = Float(bi) / Float(n - 1)
                    for gi in 0..<n {
                        let g = Float(gi) / Float(n - 1)
                        for ri in 0..<n {
                            let r = Float(ri) / Float(n - 1)
                            let pc = chroma(r, g, b)
                            var d = ((pc.u - kc.u) * (pc.u - kc.u) + (pc.v - kc.v) * (pc.v - kc.v)).squareRoot()
                            if shadow > 0, kk > 0.00001, luma(r, g, b) <= keyLuma * 1.1 + 0.02 {
                                let s = (pc.u * kc.u + pc.v * kc.v) / kk        // how much of the key's chroma this colour has
                                if s >= 1 - shadow * shadowSpan {
                                    let m = min(s, 1)
                                    let du = pc.u - m * kc.u, dv = pc.v - m * kc.v
                                    d = min(d, (du * du + dv * dv).squareRoot())
                                }
                            }
                            let keep = encode(smoothstep(tolerance, softEnd, d))
                            let index = ((bi * n + gi) * n + ri) * 4
                            p[index] = keep; p[index + 1] = keep; p[index + 2] = keep; p[index + 3] = 1
                        }
                    }
                }
            }
            let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
            cache.setObject(data as NSData, forKey: id, cost: data.count)
            return data
        }
        
        /// A colour table that takes the key colour's tint off a colour completely (the caller blends it in by how close to the edge
        /// a pixel is): the chroma along the key's direction goes, brightness stays.
        static func despillCube(_ key: ChromaKey.Resolved) -> Data {
            let id = NSString(string: "d|\(byte(key.r))|\(byte(key.g))|\(byte(key.b))")
            if let hit = cache.object(forKey: id) { return hit as Data }
            
            let kc = chroma(Float(byte(key.r)) / 255, Float(byte(key.g)) / 255, Float(byte(key.b)) / 255)
            let length = (kc.u * kc.u + kc.v * kc.v).squareRoot()
            let nu = length > 0.0001 ? kc.u / length : 0, nv = length > 0.0001 ? kc.v / length : 0
            
            let n = dimension
            var table = [Float](repeating: 1, count: n * n * n * 4)
            table.withUnsafeMutableBufferPointer { buffer in
                let shared = SharedPointer(pointer: buffer.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: n) { bi in
                    let p = shared.pointer
                    let b = Float(bi) / Float(n - 1)
                    for gi in 0..<n {
                        let g = Float(gi) / Float(n - 1)
                        for ri in 0..<n {
                            let r = Float(ri) / Float(n - 1)
                            var pc = chroma(r, g, b)
                            let y = luma(r, g, b)
                            let along = max(0, pc.u * nu + pc.v * nv)
                            pc.u -= along * nu
                            pc.v -= along * nv
                            let index = ((bi * n + gi) * n + ri) * 4
                            p[index] = min(max(y + 1.13983 * pc.v, 0), 1)
                            p[index + 1] = min(max(y - 0.39465 * pc.u - 0.58060 * pc.v, 0), 1)
                            p[index + 2] = min(max(y + 2.03211 * pc.u, 0), 1)
                            p[index + 3] = 1
                        }
                    }
                }
            }
            let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
            cache.setObject(data as NSData, forKey: id, cost: data.count)
            return data
        }
    }
}

// MARK: - Rendering (Core Image)

extension EditingView.ClipCompositor {
    
    private static let chromaColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    
    private static func applyCube(_ image: CIImage, _ data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": EditingView.ChromaCubes.dimension,
            "inputCubeData": data,
            "inputColorSpace": chromaColorSpace
        ])
    }
    
    /// `source` (the clip's own picture, before colour grade, masks and transform) with the keys' colours made transparent. A pixel
    /// that any key removes goes (the kept amounts multiply). `hasAlpha` is true for a picture that may have transparent parts of
    /// its own (an image), whose alpha is kept; a video frame is opaque.
    static func applyChromaKeys(_ keys: [EditingView.ChromaKey.Resolved], to source: CIImage, hasAlpha: Bool) -> CIImage {
        guard !keys.isEmpty else { return source }
        let extent = source.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return source }
        
        // What the tables read: the true colours, opaque.
        let flat = (hasAlpha ? source.unpremultiplyingAlpha() : source).settingAlphaOne(in: extent)
        var color = flat
        var kept: CIImage?
        
        for key in keys {
            let keep = applyCube(flat, EditingView.ChromaCubes.keepCube(key)).cropped(to: extent)
            var alpha = keep
            if key.cleanUp > 0.001 {
                // Shrink what stays by a texel or two ...
                let radius = 0.5 + Double(key.cleanUp) * 3
                let eroded = keep.clampedToExtent()
                    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: extent)
                alpha = keep.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: eroded,
                    kCIInputTimeKey: min(1.0, Double(key.cleanUp) * 1.5)
                ]).cropped(to: extent)
                // ... and take the key colour's tint off the pixels along that edge (the more the closer to the edge).
                let c = CGFloat(key.cleanUp)
                let edge = eroded.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -c, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: -c, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: -c, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: c, y: c, z: c, w: 0)
                ])
                let spillFree = applyCube(color, EditingView.ChromaCubes.despillCube(key))
                color = masked(spillFree, over: color, mask: edge).cropped(to: extent)
            }
            if let current = kept {
                kept = alpha.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            } else {
                kept = alpha
            }
        }
        guard let kept else { return source }
        
        let clear = CIImage(color: .clear).cropped(to: extent)
        var out = masked(color, over: clear, mask: kept).cropped(to: extent)
        if hasAlpha {
            // The picture's own transparency stays on top of the keying.
            out = out.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: source
            ]).cropped(to: extent)
        }
        return out
    }
}
