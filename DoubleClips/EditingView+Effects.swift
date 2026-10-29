import SwiftUI
import CoreImage
import ImageIO

// MARK: - Effect clips (adjustment layers)
//
// An effect clip filters everything that was drawn BEFORE it, for as long as the clip lasts:
// the timeline is a stream, tracks are composited in order (later tracks on top), and when the
// stream reaches the effect clip it processes the picture built so far. Clips on tracks after the
// effect's track are drawn over the result and are not touched. (This is how Android's FFmpeg
// filter graph reads: a filter placed in the chain only sees what came before it.)
//
// Android defines four effects (FXCommandEmitter.emit), ported to Core Image:
//   glitch-pulse      tblend=addition + framestep=2 + eq=brightness=0.2
//                     -> brightness lift, RGB split and slices that jump 15x/s and pulse. (The "blend
//                        with the previous frame" part needs the previous frame, which a stateless
//                        per-frame compositor doesn't have.)
//   warp-zoom         zoompan z='zoom+0.001' -> slow push-in about the centre, 3% per second.
//                     (Android's x='iw/2' puts the zoom window off to the right, which looks like a bug.)
//   lens-flare-surge  curves=cross_process + eq=contrast=1.5:saturation=1.2 -> cross-process grade.
//   spin-burst        rotate=2*PI*t/duration -> one clockwise turn across the clip, corners black.
// and this app adds a starter set of its own (blur, glow, vignette, VHS, shake, ...).
//
// Everything is a pure function of (picture so far, time into the effect), so preview, scrubbing,
// export and the picker tiles all show the same thing.
//
// `intensity` (effect.params["intensity"]; Android ignores it and keeps it on re-save) scales an
// effect: strength, zoom speed, number of turns... Effects without anything to scale hide the slider.
//
// Effect keyframes (animating strength over the clip) are planned for later.

enum EffectCatalog {
    struct Style: Identifiable {
        let key: String
        let title: String
        let author: String
        /// What the strength slider means; nil = this effect has nothing to scale.
        let intensityLabel: String?
        let intensityRange: ClosedRange<Float>
        var id: String { key }
        
        init(_ key: String, _ title: String, author: String = Constants.EFFECT_BUILTIN_AUTHOR,
             intensity: String? = "Strength", range: ClosedRange<Float> = 0.2...3) {
            self.key = key
            self.title = title
            self.author = author
            self.intensityLabel = intensity
            self.intensityRange = range
        }
    }
    
    /// Android's four first, then the iOS starter set, grouped loosely: motion, colour, optics, retro, fades.
    /// The order of the picker (Android's four first, then motion, colour, optics, fades). Names, authors and strength sliders come from the
    /// JSON files (animations/effects/*.json); a file that isn't listed here follows the listed ones, sorted by name.
    private static let pickerOrder: [String] = [
        "glitch-pulse", "warp-zoom", "lens-flare-surge", "spin-burst",
        "camera-shake", "simple-shake", "triggered-shake", "beat-pulse", "strobe", "flash",
        "rgb-shift", "vhs", "blur", "glow", "vignette", "noir", "vintage",
        "pixelate", "halftone", "kaleidoscope", "twirl", "bulge",
        "slow-push", "drift-blur", "heartbeat", "fade-in", "fade-out"
    ]
    
    /// Older projects store "shake" (the noise shake this app used to hard-code); it plays as Camera Shake now.
    static func canonicalKey(_ key: String?) -> String {
        let normalized = TransitionPlan.normalizedStyle(key)
        return normalized == "shake" ? "camera-shake" : normalized
    }
    
    static var styles: [Style] {
        let definitions = EffectStyleLoader.list()
        let ordered = pickerOrder.compactMap { key in definitions.first { $0.id == key } }
        let rest = definitions.filter { def in !pickerOrder.contains(def.id) }
        return (ordered + rest).map { def in
            Style(def.id, def.name, author: def.author, intensity: def.intensityLabel, range: def.intensityRange)
        }
    }
    
    static func style(for key: String?) -> Style? {
        let canonical = canonicalKey(key)
        return styles.first { $0.key == canonical }
    }
}

extension EditingView.EffectTemplate {
    /// 1 = the effect's default look. Stored in `params` so Android / desktop keep it on re-save.
    var intensity: Float {
        get {
            if case .number(let v)? = params?["intensity"] { return Float(v) }
            return 1
        }
        set {
            var p = params ?? [:]
            p["intensity"] = .number(Double(newValue))
            params = p
        }
    }
}

// MARK: - Renderer

enum EffectRenderer {
    
    /// `frame` is the canvas-sized picture so far; the result is canvas-sized too.
    /// - elapsed: seconds since the effect clip began; progress: elapsed / clip duration (0...1).
    static func apply(style: String, intensity: CGFloat, to frame: CIImage,
                      progress: CGFloat, time: Float, elapsed: Float, canvas: CGRect) -> CIImage {
        let a = max(intensity, 0)
        let p = min(max(progress, 0), 1)
        
        // A style defined by a JSON file (EffectStyleLoader) wins over the hard-coded one with the same key: its channels
        // are evaluated over the clip's progress (or looped every `period` seconds) and applied to the whole picture.
        if let definition = EffectStyleLoader.get(EffectCatalog.canonicalKey(style)) {
            let t: Float
            if definition.period > 0 {
                t = Float(Double(max(elapsed, 0)).truncatingRemainder(dividingBy: definition.period) / definition.period)
            } else if definition.span > 0 {
                t = Float(min(Double(max(elapsed, 0)) / definition.span, 1))
            } else {
                t = Float(p)
            }
            var out = frame
            if !definition.animation.channels.isEmpty {
                let look = definition.animation.evaluate(t).scaledDeviation(Float(a))
                out = EditingView.ClipCompositor.looked(out, anim: look, canvas: canvas)
            }
            if !definition.filters.isEmpty {
                out = applyFilters(definition, to: out, t: t, a: a, time: time, canvas: canvas)
            }
            return out
        }
        
        return frame       // a style from a newer version, or one whose file failed to load: leave the picture alone
    }
    
    // MARK: Filter ops (the "filters" list of a JSON style; format in EffectFilterOps.swift)
    
    private static func applyFilters(_ definition: EffectStyleDefinition, to input: CIImage, t: Float, a: CGFloat,
                                     time: Float, canvas: CGRect) -> CIImage {
        let step = Int(floor(Double(time) * 15))                 // random patterns jump 15 times a second
        let w = canvas.width, h = canvas.height
        let side = min(w, h)
        let scales = definition.filterStrength.scales
        var out = input
        
        for filter in definition.filters {
            guard let spec = EffectFilterOps.specs[filter.op] else { continue }
            /// The parameter at this moment, moved by the strength slider if the style asks for it.
            func v(_ name: String) -> CGFloat {
                guard let param = spec.params.first(where: { $0.name == name }), let curve = filter.curves[name] else { return 0 }
                var x = curve.at(Double(t))
                if scales && param.scaled { x = param.neutral + (x - param.neutral) * Double(a) }
                return CGFloat(min(max(x, param.min), param.max))
            }
            
            switch filter.op {
            case "blur":
                out = blurred(out, radius: h * v("radius"), canvas: canvas)
            case "colorControls":
                out = out.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: v("brightness"), kCIInputContrastKey: v("contrast"), kCIInputSaturationKey: v("saturation")
                ])
            case "photoEffect":
                let names = ["noir": "CIPhotoEffectNoir", "chrome": "CIPhotoEffectChrome", "fade": "CIPhotoEffectFade",
                             "instant": "CIPhotoEffectInstant", "mono": "CIPhotoEffectMono", "process": "CIPhotoEffectProcess",
                             "tonal": "CIPhotoEffectTonal", "transfer": "CIPhotoEffectTransfer"]
                out = out.applyingFilter(names[filter.strings["name"] ?? "noir"] ?? "CIPhotoEffectNoir")
            case "sepia":
                out = out.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: v("intensity")])
            case "vignette":
                out = out.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: v("intensity"), kCIInputRadiusKey: v("radius")
                ]).cropped(to: canvas)
            case "bloom":
                out = out.clampedToExtent().applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: h * v("radius"), kCIInputIntensityKey: v("intensity")
                ]).cropped(to: canvas)
            case "pixellate":
                out = out.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputScaleKey: max(2, h * v("scale"))
                ]).cropped(to: canvas)
            case "dotScreen":
                out = out.applyingFilter("CIDotScreen", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY), kCIInputAngleKey: v("angle"),
                    kCIInputWidthKey: max(3, h * v("width")), kCIInputSharpnessKey: v("sharpness")
                ]).cropped(to: canvas)
            case "kaleidoscope":
                out = out.clampedToExtent().applyingFilter("CIKaleidoscope", parameters: [
                    "inputCount": Int(v("count").rounded()), kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputAngleKey: v("angle")
                ]).cropped(to: canvas)
            case "twirl":
                out = out.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputRadiusKey: side * v("radius"), kCIInputAngleKey: v("angle")
                ]).cropped(to: canvas)
            case "bump":
                out = out.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputRadiusKey: side * v("radius"), kCIInputScaleKey: v("scale")
                ]).cropped(to: canvas)
            case "rgbShift":
                let direction: CGFloat = filter.flags.contains("randomSign") ? (random(step, 1) > 0.5 ? 1 : -1) : 1
                out = splitChannels(out, dx: w * v("dx") * direction, canvas: canvas)
            case "tearSlices":
                let amount = v("amount")
                for i in 0..<2 {
                    out = slice(out, y: random(step, 3 + Double(i)) * h * 0.85,
                                height: h * (0.02 + 0.08 * random(step, 5 + Double(i))),
                                shift: (random(step, 7 + Double(i)) - 0.5) * w * 0.14 * amount, canvas: canvas)
                }
            case "crossProcess":
                func poly(_ c0: CGFloat, _ c1: CGFloat, _ c2: CGFloat, _ c3: CGFloat) -> CIVector {
                    CIVector(values: [c0, c1, c2, c3], count: 4)
                }
                // Red and green get an S-curve (more contrast), blue is flattened and lifted.
                out = out.applyingFilter("CIColorPolynomial", parameters: [
                    "inputRedCoefficients": poly(0, 0.6, 1.2, -0.8),
                    "inputGreenCoefficients": poly(0, 0.9, 0.3, -0.2),
                    "inputBlueCoefficients": poly(0.08, 1.2, -0.9, 0.6)
                ])
            case "vhs":
                out = vhs(out, a: v("amount"), step: step, canvas: canvas)
            default:
                break
            }
        }
        return definition.filterStrength.mixes ? mix(input, out, amount: a, canvas: canvas) : out
    }
    
    // MARK: Small building blocks
    
    private static func blurred(_ image: CIImage, radius: CGFloat, canvas: CGRect) -> CIImage {
        guard radius > 0.1 else { return image }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: canvas)
    }
    
    /// `effected` over `frame` at `amount` (0...1; above 1 it is the effect alone).
    private static func mix(_ frame: CIImage, _ effected: CIImage, amount: CGFloat, canvas: CGRect) -> CIImage {
        if amount >= 1 { return effected.cropped(to: canvas) }
        let faded = effected.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, amount))
        ])
        return faded.composited(over: frame).cropped(to: canvas)
    }
    
    /// Deterministic pseudo-random in 0...1, so the same frame always looks the same
    /// (preview, scrubbing and export agree).
    private static func random(_ step: Int, _ salt: Double) -> CGFloat {
        let x = sin(Double(step) * 12.9898 + salt * 78.233) * 43758.5453
        return CGFloat(x - floor(x))
    }
    
    /// Red one way, blue the other, green stays; added back together.
    private static func splitChannels(_ image: CIImage, dx: CGFloat, canvas: CGRect) -> CIImage {
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        func shifted(_ i: CIImage, _ dx: CGFloat) -> CIImage {
            i.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: canvas)
        }
        let red = shifted(channel(1, 0, 0), dx)
        let green = channel(0, 1, 0)
        let blue = shifted(channel(0, 0, 1), -dx)
        return blue.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
        ]).cropped(to: canvas)
    }
    
    /// Moves a horizontal band sideways (a "torn" scanline strip).
    private static func slice(_ image: CIImage, y: CGFloat, height: CGFloat, shift: CGFloat, canvas: CGRect) -> CIImage {
        let band = CGRect(x: 0, y: y, width: canvas.width, height: height).intersection(canvas)
        guard !band.isEmpty else { return image }
        let moved = image.clampedToExtent().cropped(to: band)
            .transformed(by: CGAffineTransform(translationX: shift, y: 0)).cropped(to: band)
        return moved.composited(over: image).cropped(to: canvas)
    }
    
    // MARK: Android's effects
    
    // MARK: Starter set
    
    private static func vhs(_ frame: CIImage, a: CGFloat, step: Int, canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        let s = min(a, 2)
        
        // Worn tape: slightly flat colour, soft picture, colour fringing.
        var out = frame.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.88, kCIInputContrastKey: 1.05])
        out = blurred(out, radius: max(0.5, h * 0.0009 * s), canvas: canvas)
        out = splitChannels(out, dx: w * 0.004 * s, canvas: canvas)
        
        // Tracking error: the bottom strip tears sideways, a thin band wanders upward.
        out = slice(out, y: 0, height: h * 0.05, shift: (random(step, 21) - 0.5) * w * 0.06 * s, canvas: canvas)
        let wander = CGFloat((Double(step) * 0.07).truncatingRemainder(dividingBy: 1))
        out = slice(out, y: wander * h, height: h * 0.012, shift: (random(step, 23) - 0.5) * w * 0.03 * s, canvas: canvas)
        
        // Scanlines: dark horizontal stripes (the generator makes vertical ones, so turn them 90 degrees).
        let lineWidth = max(1, h / 540)
        if let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.22 * s),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            kCIInputWidthKey: lineWidth, kCIInputSharpnessKey: 0.6
        ])?.outputImage {
            let horizontal = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: canvas)
            out = horizontal.composited(over: out)
        }
        
        // Grain that changes every step.
        if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let moved = noise.transformed(by: CGAffineTransform(translationX: random(step, 25) * 700, y: random(step, 27) * 700))
            let grain = moved.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.12 * s)
            ]).cropped(to: canvas)
            out = grain.composited(over: out)
        }
        return out.cropped(to: canvas)
    }
}

// MARK: - Preview tiles
//
// Every tile shows the real effect, looping, on a small test picture. The pixels come from the same
// EffectRenderer the timeline uses, so what the tile shows is what the clip will do. A GIF
// can replace the live tile for any effect: put `<effect-key>.gif` (square) in the bundled
// `effects/previews` folder (add the folder to the target as a folder reference, like `animations`).

enum EffectPreview {
    static let side: CGFloat = 200
    static let loopSeconds: Double = 2.4
    static let framesPerSecond: Double = 12
    
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    
    /// A picture with shapes, colour and fine detail, so every effect has something to show.
    private static let testCard: CIImage = {
        let s = side
        let sky = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: s), "inputPoint1": CIVector(x: s, y: 0),
            "inputColor0": CIColor(red: 0.10, green: 0.18, blue: 0.55), "inputColor1": CIColor(red: 0.98, green: 0.52, blue: 0.20)
        ])!.outputImage!.cropped(to: canvas)
        var card = sky
        if let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputWidthKey: s / 10,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.22), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            kCIInputSharpnessKey: 1
        ])?.outputImage {
            card = checker.cropped(to: canvas).composited(over: card)
        }
        func disk(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: x, y: y), "inputRadius0": r, "inputRadius1": r + 1.2,
                "inputColor0": color, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ])!.outputImage!.cropped(to: canvas)
        }
        card = disk(s * 0.32, s * 0.62, s * 0.20, CIColor(red: 1.0, green: 0.88, blue: 0.20)).composited(over: card)
        card = disk(s * 0.70, s * 0.34, s * 0.16, CIColor(red: 0.20, green: 0.85, blue: 0.75)).composited(over: card)
        card = disk(s * 0.62, s * 0.76, s * 0.07, CIColor(red: 0.95, green: 0.25, blue: 0.35)).composited(over: card)
        return card.cropped(to: canvas)
    }()
    
    /// One frame of the loop. `phase` is seconds into the loop.
    static func frame(style: String, intensity: Float, phase: Double) -> UIImage? {
        let p = CGFloat(phase / loopSeconds)
        let out = EffectRenderer.apply(style: style, intensity: CGFloat(intensity), to: testCard,
                                       progress: p, time: Float(phase), elapsed: Float(phase), canvas: canvas)
        guard let cg = context.createCGImage(out, from: canvas) else { return nil }
        return UIImage(cgImage: cg)
    }
    
    // MARK: Optional GIFs
    
    private static var gifCache: [String: [(image: UIImage, delay: Double)]] = [:]
    private static let lock = NSLock()
    
    /// Frames of `<key>.gif` if it ships with the app; nil -> use the live tile.
    static func gifFrames(for key: String) -> [(image: UIImage, delay: Double)]? {
        lock.lock(); defer { lock.unlock() }
        if let hit = gifCache[key] { return hit.isEmpty ? nil : hit }
        var frames: [(UIImage, Double)] = []
        if let url = Bundle.main.url(forResource: key, withExtension: "gif", subdirectory: "effects/previews")
            ?? Bundle.main.url(forResource: key, withExtension: "gif"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            for i in 0..<min(CGImageSourceGetCount(source), 120) {
                guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                frames.append((UIImage(cgImage: cg), max(0.02, delay)))
            }
        }
        gifCache[key] = frames.map { (image: $0.0, delay: $0.1) }
        return frames.isEmpty ? nil : gifCache[key]
    }
}

struct EffectPreviewTile: View {
    let styleKey: String
    let intensity: Float
    /// Fixed start so tiles don't all begin on the same frame of their loop.
    @State private var origin = Date()
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / EffectPreview.framesPerSecond)) { context in
            let elapsed = context.date.timeIntervalSince(origin)
            Group {
                if let image = image(at: elapsed) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(hex: "#222222")
                }
            }
        }
    }
    
    private func image(at elapsed: Double) -> UIImage? {
        if let gif = EffectPreview.gifFrames(for: styleKey) {
            let total = gif.reduce(0) { $0 + $1.delay }
            var t = elapsed.truncatingRemainder(dividingBy: max(total, 0.05))
            for frame in gif {
                if t < frame.delay { return frame.image }
                t -= frame.delay
            }
            return gif.last?.image
        }
        return EffectPreview.frame(style: styleKey, intensity: intensity,
                                   phase: elapsed.truncatingRemainder(dividingBy: EffectPreview.loopSeconds))
    }
}

// MARK: - Editor

extension EditingView {
    
    struct EffectClipEditor: View {
        @ObservedObject var clip: EditingView.Clip
        let commandManager: CommandManager
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        
        @State private var intensityBefore: Float?
        @State private var keysBeforeEdit: EditingView.AnimatedProperty?
        
        private var effect: EffectTemplate {
            clip.effect ?? EffectTemplate(style: EffectCatalog.styles[0].key, duration: Double(clip.duration), offset: Double(clip.startTime))
        }
        private var current: EffectCatalog.Style? { EffectCatalog.style(for: effect.style) }
        
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                                    count: Constants.STYLE_GRID_COLUMNS)
        
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                if clip.trackIndex <= 0 {
                    Text("This is the first track, so nothing is drawn before it. Put the effect on a track below the clips it should change (T2 or further down).")
                        .font(.system(size: 11)).foregroundColor(.orange.opacity(0.9))
                }
                
                if let label = current?.intensityLabel {
                    // The diamond keys the strength at the playhead: once it is animated the slider edits the value at the
                    // playhead (adding or changing a keyframe there), like every other property.
                    HStack(spacing: 4) {
                        PropertySlider(
                            label: label,
                            value: Binding(get: { strengthNow }, set: { liveStrength($0) }),
                            range: current?.intensityRange ?? 0.2...3,
                            resetTo: 1,
                            onEditingBegan: {
                                if intensityBefore == nil { intensityBefore = effect.intensity; keysBeforeEdit = clip.keyframes }
                            },
                            onEditingEnded: commitIntensity)
                        KeyDiamond(mode: strengthKeyMode, enabled: playheadInsideClip) { toggleStrengthKey() }
                    }
                }
                
                Text(Lf("Active from %.2fs to %.2fs", clip.startTime, clip.startTime + clip.duration))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                
                if current == nil {
                    Text("This effect (\"\(effect.style)\") isn't known to this version. It is kept in the project and drawn by the platform that made it.")
                        .font(.system(size: 11)).foregroundColor(.orange.opacity(0.9))
                }
                
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(EffectCatalog.styles) { style in
                        tile(style, selected: current?.key == style.key)
                    }
                }
                
                Text(scopeText)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                Text("Trim the clip's ends on the timeline to change when the effect runs.")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
            }
        }
        
        private func tile(_ style: EffectCatalog.Style, selected: Bool) -> some View {
            Button { setStyle(style.key) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    EffectPreviewTile(styleKey: style.key, intensity: 1)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color.mdPrimary)
                                    .background(Circle().fill(Color.white).padding(3))
                                    .padding(5)
                            }
                        }
                    Text(L(style.title))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(L(style.author))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
        
        private var scopeText: String {
            guard clip.trackIndex > 0 else { return "" }
            let upper = clip.trackIndex
            let covered = upper == 1 ? "T1" : "T1 to T\(upper)"
            return Lf("Affects everything on %@ while it is active. Clips on tracks below this one are drawn on top and stay untouched.", covered)
        }
        
        // MARK: Editing
        
        private func setStyle(_ key: String) {
            var next = effect
            guard TransitionPlan.normalizedStyle(next.style) != key else { return }
            let before = clip.effect
            next.style = key
            // A new style starts at its default strength (turns, zoom speed... mean different things).
            next.intensity = 1
            apply(before: before, after: next, name: "Effect style")
        }
        
        // MARK: Strength and its keyframes
        
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        private var strengthAnimated: Bool { clip.keyframes.isAnimated(.strength) }
        
        /// The clip's properties with the effect's static strength in the strength slot (what keyframe maths falls back to).
        private var strengthBase: EditingView.VideoProperties {
            var properties = clip.videoProperties
            properties.valueStrength = effect.intensity
            return properties
        }
        
        /// The strength at the playhead: the keyframed value, or the static one.
        private var strengthNow: Float {
            strengthAnimated
                ? clip.keyframes.value(for: .strength, base: strengthBase, clipStartTime: clip.startTime,
                                       at: clip.startTime + localTime)
                : effect.intensity
        }
        
        private var strengthKeyMode: KeyDiamond.Mode {
            guard strengthAnimated else { return .off }
            return clip.keyframes.keyframeIndex(atLocal: localTime, animating: .strength) != nil ? .onKey : .animated
        }
        
        private func liveStrength(_ value: Float) {
            if strengthAnimated {
                clip.keyframes.setKey(.strength, atLocal: localTime, value: value, base: strengthBase,
                                      clipStartTime: clip.startTime, frameRate: frameRate)
            } else {
                liveIntensity(value)
            }
        }
        
        private func liveIntensity(_ value: Float) {
            var next = effect
            next.intensity = value
            clip.effect = next
        }
        
        /// One undo step for a whole slider gesture (static strength and keyframes together).
        private func commitIntensity() {
            guard let before = intensityBefore else { return }
            let keysBefore = keysBeforeEdit ?? clip.keyframes
            intensityBefore = nil
            keysBeforeEdit = nil
            var old = effect
            old.intensity = before
            let after = effect
            let keysAfter = clip.keyframes
            guard abs(before - after.intensity) > 0.0005 || keysBefore != keysAfter else { return }
            let target = clip
            let changed = onChanged
            commandManager.execute(GenericCommand(description: "Effect strength",
                undo: { target.effect = old; target.keyframes = keysBefore; changed() },
                redo: { target.effect = after; target.keyframes = keysAfter; changed() }))
            changed()
        }
        
        private func toggleStrengthKey() {
            guard playheadInsideClip else { return }
            let keysBefore = clip.keyframes
            let effectBefore = clip.effect
            var keys = keysBefore
            var next = effect
            if keys.keyframeIndex(atLocal: localTime, animating: .strength) != nil {
                // Off at this key; if it was the last one the strength stays where it was.
                if let removed = keys.removeKey(.strength, atLocal: localTime), !keys.isAnimated(.strength) {
                    next.intensity = removed
                }
            } else {
                keys.setKey(.strength, atLocal: localTime, value: strengthNow, base: strengthBase,
                            clipStartTime: clip.startTime, frameRate: frameRate)
            }
            guard keys != keysBefore || abs(next.intensity - effect.intensity) > 0.0005 else { return }
            clip.keyframes = keys
            clip.effect = next
            let target = clip
            let changed = onChanged
            let effectAfter = next
            commandManager.execute(GenericCommand(description: "Keyframe Strength: \(clip.clipName)",
                undo: { target.keyframes = keysBefore; target.effect = effectBefore; changed() },
                redo: { target.keyframes = keys; target.effect = effectAfter; changed() }))
            changed()
        }
        
        private func apply(before: EffectTemplate?, after: EffectTemplate, name: String, alreadyApplied: Bool = false) {
            let target = clip
            let changed = onChanged
            if !alreadyApplied { target.effect = after }
            commandManager.execute(GenericCommand(description: name,
                undo: { target.effect = before; changed() },
                redo: { target.effect = after; changed() }))
            changed()
        }
    }
}
