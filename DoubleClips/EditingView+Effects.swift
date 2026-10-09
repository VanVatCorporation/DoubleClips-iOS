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
    static let styles: [Style] = [
        Style("glitch-pulse", "Glitch Pulse"),
        Style("warp-zoom", "Warp Zoom", intensity: "Zoom speed", range: 0.2...5),
        Style("lens-flare-surge", "Lens Flare Surge", range: 0.2...2),
        Style("spin-burst", "Spinning Burst", intensity: "Turns", range: 0.25...4),
        
        Style("shake", "Camera Shake"),
        Style("beat-pulse", "Beat Pulse"),
        Style("strobe", "Strobe"),
        Style("flash", "Flash"),
        Style("rgb-shift", "RGB Shift"),
        Style("vhs", "VHS Tape"),
        Style("blur", "Soft Blur"),
        Style("glow", "Dream Glow"),
        Style("vignette", "Vignette", range: 0.2...2),
        Style("noir", "Noir", range: 0.2...1),
        Style("vintage", "Vintage", range: 0.2...1),
        Style("pixelate", "Pixelate"),
        Style("halftone", "Halftone"),
        Style("kaleidoscope", "Kaleidoscope", intensity: "Speed", range: 0.2...4),
        Style("twirl", "Twirl"),
        Style("bulge", "Lens Bulge"),
        Style("fade-in", "Fade In", intensity: nil),
        Style("fade-out", "Fade Out", intensity: nil)
    ]
    
    static func style(for key: String?) -> Style? {
        let normalized = TransitionPlan.normalizedStyle(key)
        return styles.first { $0.key == normalized }
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
        let e = CGFloat(max(elapsed, 0))
        let p = min(max(progress, 0), 1)
        let step = Int(floor(Double(time) * 15))
        switch TransitionPlan.normalizedStyle(style) {
        // Android's four
        case "glitch-pulse": return glitch(frame, a: a, time: time, elapsed: elapsed, canvas: canvas)
        case "warp-zoom": return zoom(frame, scale: 1 + 0.03 * a * e, canvas: canvas)
        case "lens-flare-surge": return grade(frame, a: a, canvas: canvas)
        case "spin-burst": return spin(frame, turns: a, progress: p, canvas: canvas)
        
        // Motion
        case "shake": return shake(frame, a: a, time: time, canvas: canvas)
        case "beat-pulse":
            let phase = (e * 2).truncatingRemainder(dividingBy: 1)            // 2 beats a second
            return zoom(frame, scale: 1 + 0.08 * a * exp(-6 * phase), canvas: canvas)
        case "strobe":
            let on = Int(floor(Double(e) * 10)) % 2 == 0                      // 5 flashes a second
            return on ? adjust(frame, brightness: 0.35 * min(a, 2), contrast: 1.2)
                      : adjust(frame, brightness: -0.12 * min(a, 2), contrast: 1)
        case "flash":
            let decay = pow(1 - p, 3)
            let lit = frame.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.5 * a * decay])
            return adjust(lit, brightness: 0.3 * min(a, 2) * decay, contrast: 1).cropped(to: canvas)
            
        // Colour
        case "rgb-shift":
            return splitChannels(frame, dx: canvas.width * 0.01 * a * (1 + 0.5 * sin(2 * .pi * 1.5 * e)), canvas: canvas)
        case "noir":
            return mix(frame, frame.applyingFilter("CIPhotoEffectNoir"), amount: a, canvas: canvas)
        case "vintage": return vintage(frame, a: a, canvas: canvas)
        case "vhs": return vhs(frame, a: a, step: step, canvas: canvas)
            
        // Optics
        case "blur":
            return blurred(frame, radius: canvas.height * 0.014 * a, canvas: canvas)
        case "glow":
            return frame.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: canvas.height * 0.025 * a, kCIInputIntensityKey: min(1.2, 0.6 + 0.4 * a)
            ]).cropped(to: canvas)
        case "vignette":
            return frame.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 1.2 * min(a, 2), kCIInputRadiusKey: 1.4
            ]).cropped(to: canvas)
        case "pixelate":
            return frame.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputScaleKey: max(2, canvas.height * 0.012 * a)
            ]).cropped(to: canvas)
        case "halftone":
            return frame.applyingFilter("CIDotScreen", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY), kCIInputAngleKey: 0.5,
                kCIInputWidthKey: max(3, canvas.height * 0.006 * a), kCIInputSharpnessKey: 0.7
            ]).cropped(to: canvas)
        case "kaleidoscope":
            return frame.clampedToExtent().applyingFilter("CIKaleidoscope", parameters: [
                "inputCount": 6, kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                kCIInputAngleKey: e * 0.5 * a
            ]).cropped(to: canvas)
        case "twirl":
            let angle = 2 * a * sin(2 * .pi * 0.5 * e)
            return frame.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                kCIInputRadiusKey: min(canvas.width, canvas.height) * 0.45, kCIInputAngleKey: angle
            ]).cropped(to: canvas)
        case "bulge":
            let swell = 0.5 - 0.5 * cos(2 * .pi * 0.7 * e)
            return frame.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                kCIInputRadiusKey: min(canvas.width, canvas.height) * 0.45, kCIInputScaleKey: 0.7 * a * swell
            ]).cropped(to: canvas)
            
        // Fades
        case "fade-in": return fade(frame, visible: p, canvas: canvas)
        case "fade-out": return fade(frame, visible: 1 - p, canvas: canvas)
            
        default: return frame       // a style from a newer version: leave the picture alone
        }
    }
    
    // MARK: Small building blocks
    
    private static func adjust(_ image: CIImage, brightness: CGFloat, contrast: CGFloat) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast])
    }
    
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
    
    private static func fade(_ frame: CIImage, visible: CGFloat, canvas: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: canvas)
        return frame.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(visible, 0), 1))
        ]).composited(over: black).cropped(to: canvas)
    }
    
    private static func zoom(_ frame: CIImage, scale z: CGFloat, canvas: CGRect) -> CIImage {
        let cx = canvas.midX, cy = canvas.midY
        let transform = CGAffineTransform(translationX: cx, y: cy)
            .scaledBy(x: z, y: z)
            .translatedBy(x: -cx, y: -cy)
        return frame.transformed(by: transform).cropped(to: canvas)
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
    
    private static func spin(_ frame: CIImage, turns: CGFloat, progress: CGFloat, canvas: CGRect) -> CIImage {
        // FFmpeg's rotate turns clockwise; Core Image's y axis points up, so clockwise is negative.
        let angle = -2 * CGFloat.pi * turns * progress
        let cx = canvas.midX, cy = canvas.midY
        let transform = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: angle)
            .translatedBy(x: -cx, y: -cy)
        let black = CIImage(color: .black).cropped(to: canvas)
        return frame.transformed(by: transform).composited(over: black).cropped(to: canvas)
    }
    
    private static func grade(_ frame: CIImage, a: CGFloat, canvas: CGRect) -> CIImage {
        func poly(_ c0: CGFloat, _ c1: CGFloat, _ c2: CGFloat, _ c3: CGFloat) -> CIVector {
            CIVector(values: [c0, c1, c2, c3], count: 4)
        }
        // Cross process: red and green get an S-curve (more contrast), blue is flattened and lifted.
        let crossed = frame.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": poly(0, 0.6, 1.2, -0.8),
            "inputGreenCoefficients": poly(0, 0.9, 0.3, -0.2),
            "inputBlueCoefficients": poly(0.08, 1.2, -0.9, 0.6)
        ])
        let graded = crossed.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 + 0.5 * min(a, 2), kCIInputSaturationKey: 1 + 0.2 * min(a, 2)
        ])
        return mix(frame, graded, amount: a, canvas: canvas)
    }
    
    private static func glitch(_ frame: CIImage, a: CGFloat, time: Float, elapsed: Float, canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        let step = Int(floor(Double(time) * 15))                 // the pattern jumps 15 times a second
        let pulse = 0.5 + 0.5 * sin(2 * Double.pi * 3 * Double(max(elapsed, 0)))
        let amount = CGFloat(0.4 + 0.6 * pulse) * min(a, 3)
        
        let lit = adjust(frame, brightness: 0.2 * min(a, 1.5), contrast: 1)
        let direction: CGFloat = random(step, 1) > 0.5 ? 1 : -1
        var out = splitChannels(lit, dx: w * 0.012 * amount * direction, canvas: canvas)
        for i in 0..<2 {
            out = slice(out, y: random(step, 3 + Double(i)) * h * 0.85,
                        height: h * (0.02 + 0.08 * random(step, 5 + Double(i))),
                        shift: (random(step, 7 + Double(i)) - 0.5) * w * 0.14 * amount, canvas: canvas)
        }
        return out
    }
    
    // MARK: Starter set
    
    private static func shake(_ frame: CIImage, a: CGFloat, time: Float, canvas: CGRect) -> CIImage {
        let step = Int(floor(Double(time) * 30))                 // a new jolt every frame at 30 fps
        let dx = (random(step, 11) - 0.5) * 2 * canvas.width * 0.012 * a
        let dy = (random(step, 13) - 0.5) * 2 * canvas.height * 0.012 * a
        let rot = (random(step, 17) - 0.5) * 2 * 0.012 * a
        let z = 1 + 0.03 * min(a, 3)                             // a little push-in hides the moving edges
        let cx = canvas.midX, cy = canvas.midY
        let transform = CGAffineTransform(translationX: cx + dx, y: cy + dy)
            .rotated(by: rot).scaledBy(x: z, y: z).translatedBy(x: -cx, y: -cy)
        return frame.clampedToExtent().transformed(by: transform).cropped(to: canvas)
    }
    
    private static func vintage(_ frame: CIImage, a: CGFloat, canvas: CGRect) -> CIImage {
        let aged = frame
            .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9, kCIInputContrastKey: 1.06])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.5])
        return mix(frame, aged, amount: a, canvas: canvas)
    }
    
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
        let onChanged: () -> Void
        
        @State private var intensityBefore: Float?
        
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
                    PropertySlider(
                        label: label,
                        value: Binding(get: { effect.intensity }, set: { liveIntensity($0) }),
                        range: current?.intensityRange ?? 0.2...3,
                        resetTo: 1,
                        onEditingBegan: { if intensityBefore == nil { intensityBefore = effect.intensity } },
                        onEditingEnded: commitIntensity)
                }
                
                Text(String(format: "Active from %.2fs to %.2fs", clip.startTime, clip.startTime + clip.duration))
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
                    Text(style.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(style.author)
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
            return "Affects everything on \(covered) while it is active. Clips on tracks below this one are drawn on top and stay untouched."
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
        
        private func liveIntensity(_ value: Float) {
            var next = effect
            next.intensity = value
            clip.effect = next
        }
        
        private func commitIntensity() {
            guard let before = intensityBefore else { return }
            intensityBefore = nil
            var old = effect
            old.intensity = before
            let after = effect
            guard abs(before - after.intensity) > 0.0005 else { return }
            apply(before: old, after: after, name: "Effect strength", alreadyApplied: true)
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
