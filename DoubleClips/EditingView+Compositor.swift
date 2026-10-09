import AVFoundation
import CoreImage
import UIKit

// MARK: - Preview compositor
//
// AVPlayer's default pipeline can only show one video track at a time and knows nothing about
// keyframes, so the preview ignored position/scale/rotation/opacity/color, overlapping tracks,
// images and text. This file is the iOS counterpart of Android's OpenGLEdit/FFmpegEdit
// per-frame math, run through an `AVVideoCompositing` implementation on Core Image.
//
// Semantics copied from Android (OpenGLEdit.buildClipMvp / FFmpegEdit):
//   - Canvas = project resolution (project.settings), origin top-left, +Y down, pixels.
//   - PosX/PosY = canvas position of the clip's UNSCALED, unrotated top-left corner.
//   - Scale and rotation happen around the pivot (normalized 0..1 of the clip); the pivot
//     itself never moves. Base size = clip size (or the canvas when stretch-to-full).
//   - Rotation is stored in degrees; positive = clockwise.
//   - Layers draw in track order, later tracks on top.
//   - TEXT is drawn into its own bitmap (TextRenderer: font, colour, outline, shadow, box) and then
//     placed like any other layer. Its centre starts on the canvas centre (drawtext's
//     x=(w-text_w)/2), offset by PosX/PosY, but unlike Android's drawtext it also honours scale,
//     rotation about the pivot, opacity, colour adjustments and clip in/out animations.
//   - Clip in / out animations (assets/animations JSON, see ClipAnimation.swift) are evaluated per
//     frame and combined with the clip's own properties exactly as OpenGLEdit does: additive
//     (offset, rotation, hue, brightness, temperature), multiplicative (opacity, scale, saturation),
//     standalone (contrast, blur, warp). Videos and images only, as on Android.

extension EditingView {
    
    // MARK: Snapshot handed to the render thread (value types only)
    
    struct RenderLayer {
        enum Kind {
            case video(trackID: CMPersistentTrackID, preferredTransform: CGAffineTransform)
            case image(URL)
            case text(TextSpec)
            /// Not a picture: filters everything drawn before it (EditingView+Effects.swift).
            case effect(style: String, intensity: Float)
        }
        var kind: Kind
        var clipID: UUID
        var startTime: Float
        var width: CGFloat
        var height: CGFloat
        var baseProperties: VideoProperties
        var keyframes: AnimatedProperty
        /// Clip in / out animation slots (ids looked up in ClipAnimationLoader at render time) and the
        /// clip's timeline duration, which decides how the two windows fit inside the clip.
        var inAnimation = AnimationClip()
        var outAnimation = AnimationClip()
        var duration: Float = 0
        /// When set, the out animation plays over this stretch instead of ending with the clip. The outgoing
        /// side of a transition gets the transition's own window (CapCut's "combine out animation with the
        /// transition"), so a transition and an out animation play together instead of one after the other.
        struct OutWindow {
            var start: Float
            var duration: Float
        }
        var outWindow: OutWindow?
    }
    
    /// A transition between two clips of one track (EditingView+TransitionPlan.swift): both sides are
    /// rendered as full-canvas pictures at the SAME timeline time and blended by `progress`.
    struct RenderTransition {
        var from: RenderLayer
        var to: RenderLayer
        /// Normalized style key (trimmed, lower case).
        var style: String
        var start: Float
        var duration: Float
    }
    
    /// One thing to draw in a stretch of the timeline: a plain layer, or a transition standing in for
    /// the two clips it joins.
    enum RenderEntry {
        case layer(RenderLayer)
        case transition(RenderTransition)
    }
    
    final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
        let timeRange: CMTimeRange
        let enablePostProcessing = false
        let containsTweening = true
        let requiredSourceTrackIDs: [NSValue]?
        let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        /// Draw order, bottom to top.
        let entries: [RenderEntry]
        let stretchToFull: Bool
        
        init(timeRange: CMTimeRange, entries: [RenderEntry], stretchToFull: Bool) {
            self.timeRange = timeRange
            self.entries = entries
            self.stretchToFull = stretchToFull
            var ids: [NSValue] = []
            var seen = Set<CMPersistentTrackID>()
            func collect(_ layer: RenderLayer) {
                if case .video(let id, _) = layer.kind, seen.insert(id).inserted {
                    ids.append(NSNumber(value: id))
                }
            }
            for entry in entries {
                switch entry {
                case .layer(let layer): collect(layer)
                case .transition(let transition): collect(transition.from); collect(transition.to)
                }
            }
            self.requiredSourceTrackIDs = ids
            super.init()
        }
    }
    
    // MARK: Compositor
    
    final class ClipCompositor: NSObject, AVVideoCompositing {
        
        var sourcePixelBufferAttributes: [String: Any]? = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        private let renderQueue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.compositor")
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private static let mediaCache = NSCache<NSString, CIImage>()
        
        func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
        
        func cancelAllPendingVideoCompositionRequests() {
            // Requests are short (one frame); draining the queue guarantees none run afterwards.
            renderQueue.sync {}
        }
        
        func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
            renderQueue.async { [self] in
                autoreleasepool {
                    guard let instruction = request.videoCompositionInstruction as? CompositorInstruction,
                          let output = request.renderContext.newPixelBuffer() else {
                        request.finish(with: NSError(domain: "ClipCompositor", code: -1))
                        return
                    }
                    let canvas = request.renderContext.size
                    let canvasRect = CGRect(origin: .zero, size: canvas)
                    let time = Float(request.compositionTime.seconds)
                    
                    var frame = CIImage(color: .black).cropped(to: canvasRect)
                    for entry in instruction.entries {
                        switch entry {
                        case .layer(let layer):
                            if case .effect(let style, let intensity) = layer.kind {
                                // Adjustment layer: process the picture built so far, tracks after it stay clean.
                                let elapsed = time - layer.startTime
                                let progress = layer.duration > 0 ? min(max(elapsed / layer.duration, 0), 1) : 0
                                frame = EffectRenderer.apply(style: style, intensity: CGFloat(intensity), to: frame,
                                                             progress: CGFloat(progress), time: time,
                                                             elapsed: elapsed, canvas: canvasRect)
                            } else if let image = render(layer, request: request, canvas: canvas,
                                                         time: time, stretchToFull: instruction.stretchToFull) {
                                frame = image.composited(over: frame)
                            }
                        case .transition(let transition):
                            // The outgoing clip's out animation runs through the transition's window.
                            var outgoing = transition.from
                            if transition.duration > 0 {
                                outgoing.outWindow = RenderLayer.OutWindow(start: transition.start, duration: transition.duration)
                            }
                            let progress = transition.duration > 0
                                ? CGFloat(min(max((time - transition.start) / transition.duration, 0), 1)) : 1
                            
                            if let style = TransitionStyleLoader.get(transition.style) {
                                // Data-driven style (animations/transitions/*.json): ONE of the two clips is drawn,
                                // A before the style's cut and B after it, each with its side's channels merged into
                                // its own animation frame. No cross dissolve.
                                let showOutgoing = Double(progress) < style.cut
                                let extra = (showOutgoing ? style.from : style.to).evaluate(Float(progress))
                                let picture = showOutgoing
                                    ? render(outgoing, request: request, canvas: canvas, time: time,
                                             stretchToFull: instruction.stretchToFull, extraAnim: extra)
                                    : render(transition.to, request: request, canvas: canvas, time: time,
                                             stretchToFull: instruction.stretchToFull, extraAnim: extra)
                                if let picture { frame = picture.composited(over: frame) }
                            } else {
                                // Both clips as full-canvas pictures at this very time, then the blend
                                // (Android: two offscreen layers + TransitionBlendShader).
                                let from = render(outgoing, request: request, canvas: canvas,
                                                  time: time, stretchToFull: instruction.stretchToFull)
                                let to = render(transition.to, request: request, canvas: canvas,
                                                time: time, stretchToFull: instruction.stretchToFull)
                                if let blended = Self.blend(from, to, style: transition.style,
                                                            progress: progress, canvas: canvasRect) {
                                    frame = blended.composited(over: frame)
                                }
                            }
                        }
                    }
                    ciContext.render(frame, to: output, bounds: canvasRect, colorSpace: colorSpace)
                    request.finish(withComposedVideoFrame: output)
                }
            }
        }
        
        // MARK: Per-layer rendering
        
        private func render(_ layer: RenderLayer, request: AVAsynchronousVideoCompositionRequest,
                            canvas: CGSize, time: Float, stretchToFull: Bool,
                            extraAnim: ClipAnimationFrame? = nil) -> CIImage? {
            // A gesture in progress overrides the snapshot without rebuilding the player item.
            let live = LiveOverrides.shared.state(for: layer.clipID)
            let props = (live?.keyframes ?? layer.keyframes).resolved(base: live?.properties ?? layer.baseProperties,
                                                                     clipStartTime: layer.startTime, at: time)
            
            switch layer.kind {
            case .text(let spec):
                // Per-character / word / line animation, while an In / Out window is open.
                if spec.style.animatesPerUnit,
                   let units = renderTextUnits(layer, spec: spec, props: props, canvas: canvas, time: time) {
                    return units
                }
                guard let rendered = TextRenderer.render(spec) else { return nil }
                // The bitmap is the clip's own box; PosX/PosY move its top-left from the canvas-centred spot.
                var box = layer
                box.width = rendered.size.width
                box.height = rendered.size.height
                let origin = CGPoint(x: (canvas.width - rendered.size.width) / 2,
                                     y: (canvas.height - rendered.size.height) / 2)
                return place(rendered.image, layer: box, props: props, canvas: canvas, stretchToFull: false,
                             anim: Self.animationFrame(layer, at: time).merged(with: extraAnim), origin: origin)
                
            case .video(let trackID, let preferredTransform):
                guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
                let upright = Self.upright(CIImage(cvPixelBuffer: buffer), preferredTransform)
                return place(upright, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull,
                             anim: Self.animationFrame(layer, at: time).merged(with: extraAnim))
                
            case .image(let url):
                guard let source = Self.cachedImage(url) else { return nil }
                return place(source, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull,
                             anim: Self.animationFrame(layer, at: time).merged(with: extraAnim))
                
            case .effect:
                return nil      // handled where the layers are composited
            }
        }
        
        // MARK: Per-unit text (EditingView+TextUnits.swift)
        //
        // Android's OpenGLEdit.buildTextUnitCommands: the clip's In / Out animation is evaluated per unit,
        // each unit starting a little after the previous one (stagger), and applied about the unit's OWN
        // centre on top of the clip's (keyframed) position / scale / rotation / pivot, which move the
        // whole block. Returns nil when the whole-block path should draw: no In / Out window is open
        // (every unit would be neutral anyway) or the text can't be split.
        
        private func renderTextUnits(_ layer: RenderLayer, spec: TextSpec, props: VideoProperties,
                                     canvas: CGSize, time t: Float) -> CIImage? {
            let inDef = ClipAnimationLoader.get(layer.inAnimation.type, direction: .in)
            let outDef = ClipAnimationLoader.get(layer.outAnimation.type, direction: .out)
            if inDef == nil && outDef == nil { return nil }
            let inRaw: Float = inDef != nil ? layer.inAnimation.duration : 0
            let outRaw: Float = outDef != nil ? layer.outAnimation.duration : 0
            let inDur: Float = inDef != nil ? ClipAnimation.fitDuration(inRaw, other: outRaw, clip: layer.duration) : 0
            let outDur: Float = outDef != nil ? ClipAnimation.fitDuration(outRaw, other: inRaw, clip: layer.duration) : 0
            let clipEnd = layer.startTime + layer.duration
            let local = t - layer.startTime
            let inOpen = inDef != nil && inDur > 0 && local >= 0 && local < inDur
            let outOpen = outDef != nil && outDur > 0 && t >= clipEnd - outDur
            guard inOpen || outOpen else { return nil }
            guard let set = TextUnitRenderer.render(spec), !set.units.isEmpty else { return nil }
            
            let n = set.units.count
            let stagger = min(max(spec.style.stagger, 0), 0.95)
            let ranks = TextUnitRenderer.ranks(count: n, order: spec.style.order, seedText: spec.text)
            
            // The block's transform: the same quantities place() reads, without the clip-level animation.
            let tw = set.blockSize.width, th = set.blockSize.height
            let scaleX = CGFloat(props.valueScaleX), scaleY = CGFloat(props.valueScaleY)
            let pivotX = CGFloat(props.valuePivotX), pivotY = CGFloat(props.valuePivotY)
            let originX = (canvas.width - tw) / 2, originY = (canvas.height - th) / 2
            let pivotCanvasX = CGFloat(props.valuePosX) + originX + pivotX * tw
            let pivotCanvasY = CGFloat(props.valuePosY) + originY + pivotY * th
            let blockRot = CGFloat(props.value(.rotInRadians))
            let cosB = cos(blockRot), sinB = sin(blockRot)
            
            // The background box stays still under the units.
            var result: CIImage?
            if let box = set.box {
                var boxLayer = layer
                boxLayer.width = tw
                boxLayer.height = th
                result = place(box, layer: boxLayer, props: props, canvas: canvas, stretchToFull: false,
                               anim: .neutral, origin: CGPoint(x: originX, y: originY))
            }
            
            for (i, unit) in set.units.enumerated() {
                let frac: Float = n > 1 ? Float(ranks[i]) / Float(n - 1) : 0
                var anim = ClipAnimationFrame.neutral
                if inOpen, let inDef {
                    let delay = stagger * inDur * frac
                    let length = max(inDur * (1 - stagger), 0.001)
                    let e = local - delay
                    if e < 0 { anim = inDef.evaluate(0) }                  // not started: held at the first frame
                    else if e < length { anim = inDef.evaluate(e / length) }
                    // else finished: neutral
                } else if let outDef {
                    let delay = stagger * outDur * frac
                    let length = max(outDur * (1 - stagger), 0.001)
                    let e = t - (clipEnd - outDur) - delay
                    if e >= length { anim = outDef.evaluate(1) }           // finished: held at the last frame
                    else if e >= 0 { anim = outDef.evaluate(e / length) }
                    // else not started: neutral
                }
                
                // Unit centre on the canvas (y down): block-relative, scaled and turned about the pivot.
                let dx = (unit.rect.midX - pivotX * tw) * scaleX
                let dy = (unit.rect.midY - pivotY * th) * scaleY
                let cx = pivotCanvasX + dx * cosB - dy * sinB + CGFloat(anim.offsetX) * canvas.width
                let cy = pivotCanvasY + dx * sinB + dy * cosB + CGFloat(anim.offsetY) * canvas.height
                let rotation = blockRot + CGFloat(anim.rotationDegrees) * .pi / 180
                let sx = scaleX * CGFloat(anim.scale), sy = scaleY * CGFloat(anim.scale)
                guard sx > 0, sy > 0 else { continue }
                
                var image = Self.colorAdjusted(unit.image, props, anim: anim)
                if anim.hasWarp { image = Self.warped(image, anim: anim) }
                // Blur isn't applied per unit (Android doesn't either).
                let w = unit.rect.width, h = unit.rect.height
                let transform = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                    .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                    .concatenating(CGAffineTransform(rotationAngle: -rotation))      // y-up: clockwise is negative
                    .concatenating(CGAffineTransform(translationX: cx, y: canvas.height - cy))
                let placed = image.transformed(by: transform)
                result = result.map { placed.composited(over: $0) } ?? placed
            }
            return result
        }
        
        /// Color adjustments (same order as FFmpegEdit: hue/sat/brightness → temperature → opacity),
        /// then the pivot-based scale/rotate/translate from OpenGLEdit.buildClipMvp.
        private func place(_ source: CIImage, layer: RenderLayer, props: VideoProperties,
                           canvas: CGSize, stretchToFull: Bool, anim: ClipAnimationFrame,
                           origin: CGPoint = .zero) -> CIImage? {
            let srcW = source.extent.width, srcH = source.extent.height
            guard srcW > 0, srcH > 0 else { return nil }
            
            let baseW = stretchToFull ? canvas.width : (layer.width > 0 ? layer.width : srcW)
            let baseH = stretchToFull ? canvas.height : (layer.height > 0 ? layer.height : srcH)
            // The animation's scale multiplies the clip's own (about its pivot).
            let scaledW = baseW * CGFloat(props.valueScaleX * anim.scale)
            let scaledH = baseH * CGFloat(props.valueScaleY * anim.scale)
            guard scaledW > 0, scaledH > 0 else { return nil }
            
            var colored = Self.colorAdjusted(source, props, anim: anim)
            // Top-centre squish (warp.* channels) happens on the clip's own box, before scale/rotate.
            if anim.hasWarp { colored = Self.warped(colored, anim: anim) }
            
            // Offsets are fractions of the canvas size added to PosX/PosY.
            let posX = CGFloat(props.valuePosX) + CGFloat(anim.offsetX) * canvas.width + origin.x
            let posY = CGFloat(props.valuePosY) + CGFloat(anim.offsetY) * canvas.height + origin.y
            let pivotX = CGFloat(props.valuePivotX), pivotY = CGFloat(props.valuePivotY)
            // Pivot inside the scaled clip, in Core Image's y-up space.
            let pivotLocal = CGPoint(x: pivotX * scaledW, y: scaledH - pivotY * scaledH)
            // Pivot on the canvas: located on the UNSCALED clip, so it stays put (Android's rule).
            let pivotCanvasDown = CGPoint(x: posX + pivotX * baseW,
                                          y: posY + pivotY * baseH)
            let pivotCanvas = CGPoint(x: pivotCanvasDown.x, y: canvas.height - pivotCanvasDown.y)
            // The animation's rotation (degrees) is added to the clip's own.
            let theta = CGFloat(props.value(.rotInRadians)) + CGFloat(anim.rotationDegrees) * .pi / 180
            
            // scale → move pivot to origin → rotate → move pivot to its canvas position.
            // Android's positive angle is clockwise on a y-down canvas = -theta in y-up space.
            let transform = CGAffineTransform(scaleX: scaledW / srcW, y: scaledH / srcH)
                .concatenating(CGAffineTransform(translationX: -pivotLocal.x, y: -pivotLocal.y))
                .concatenating(CGAffineTransform(rotationAngle: -theta))
                .concatenating(CGAffineTransform(translationX: pivotCanvas.x, y: pivotCanvas.y))
            var placed = colored.transformed(by: transform)
            
            // Blur sigma is a fraction of the canvas WIDTH, applied to the drawn layer in canvas
            // pixels (Android blurs the layer after drawing it). Transparent surroundings fade in
            // exactly as they do there; the final render crops to the canvas.
            // Edge fill, edge slide, squeeze, motion blur, blur (EditingView+TransitionLook.swift).
            placed = Self.streakStack(placed, anim: anim, canvas: CGRect(origin: .zero, size: canvas))
            return placed
        }
        
        // MARK: Helpers
        
        /// Clip properties plus the animation's channels: hue / brightness / temperature add,
        /// saturation / opacity multiply, contrast stands alone (the clip has none). Brightness is in
        /// Android's -10..10 units for both the clip and the animation; the shader scales the sum by 0.1.
        static func colorAdjusted(_ image: CIImage, _ p: VideoProperties, anim: ClipAnimationFrame) -> CIImage {
            let saturation = p.valueSaturation * anim.saturation
            let brightness = (p.valueBrightness + anim.brightness) * 0.1
            let contrast = anim.contrast
            let hue = p.valueHue + anim.hueDegrees
            let temperature = p.valueTemperature + anim.temperatureKelvin
            let opacity = p.valueOpacity * anim.opacity
            
            var out = image
            if saturation != 1 || brightness != 0 || contrast != 1 {
                out = out.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: saturation,
                    kCIInputBrightnessKey: brightness,
                    kCIInputContrastKey: contrast
                ])
            }
            if hue != 0 {
                out = out.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * .pi / 180])
            }
            if abs(temperature - 6500) > 1 {
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(temperature), y: 0),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0)
                ])
            }
            let exposure = CGFloat(anim.exposure)
            if abs(exposure - 1) > 0.001 {
                // Brightness multiplier on the colours (alpha untouched).
                out = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: exposure, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: exposure, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: exposure, w: 0)
                ])
            }
            if opacity < 1 {
                out = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))
                ])
            }
            return out
        }
        
        // MARK: Clip animations
        
        /// The clip's animation channel values at this output time (`.neutral` when none is active).
        /// The in window starts at the clip's first frame, the out window ends at its last; if the two
        /// don't fit in the clip together both shrink proportionally, so they never overlap and at most
        /// one is active at any time. The out animation is held at its end state past the clip's nominal
        /// end (the outgoing clip of a transition keeps drawing there). Same rules as Android's
        /// OpenGLEdit.animationFrame.
        static func animationFrame(_ layer: RenderLayer, at t: Float) -> ClipAnimationFrame {
            let inDef = ClipAnimationLoader.get(layer.inAnimation.type, direction: .in)
            let outDef = ClipAnimationLoader.get(layer.outAnimation.type, direction: .out)
            if inDef == nil && outDef == nil { return .neutral }
            
            let inRaw: Float = inDef != nil ? layer.inAnimation.duration : 0
            let outRaw: Float = outDef != nil ? layer.outAnimation.duration : 0
            if let inDef {
                let inDur = ClipAnimation.fitDuration(inRaw, other: outRaw, clip: layer.duration)
                let p = ClipAnimation.progress(elapsed: t - layer.startTime, duration: inDur)
                if p >= 0 { return inDef.evaluate(p) }
            }
            if let outDef {
                let outDur: Float
                let clipEnd: Float
                if let window = layer.outWindow {          // combined with a transition
                    outDur = window.duration
                    clipEnd = window.start + window.duration
                } else {
                    outDur = ClipAnimation.fitDuration(outRaw, other: inRaw, clip: layer.duration)
                    clipEnd = layer.startTime + layer.duration
                }
                let p = ClipAnimation.progressOut(clipEnd: clipEnd, t: t, duration: outDur)
                if p >= 0 { return outDef.evaluate(p) }
            }
            return .neutral
        }
        
        // MARK: Warp (top-centre squish)
        //
        // Android does this per pixel in the fragment shader as an inverse mapping with edge clamping:
        // the TOP edge is topWidth wide, the BOTTOM edge bottomWidth wide (relative to normal, about the
        // vertical centre line), the height is scaled by `height` keeping the top edge fixed, and source
        // positions outside the clip clamp to its edge, so the area the shrunken picture no longer
        // covers is filled with edge pixels instead of showing a gap. This is the same mapping as a
        // Core Image warp kernel. Should the (deprecated) kernel language be unavailable on a future
        // iOS, it falls back to a perspective trapezoid: same silhouette, no edge fill.
        
        private static let warpKernel: CIWarpKernel? = {
            let source = """
            kernel vec2 clipWarp(vec4 box, vec3 w)
            {
                vec2 d = destCoord();
                float qx = ((d.x - box.x) / box.z) * 2.0 - 1.0;
                float qy = 1.0 - 2.0 * ((d.y - box.y) / box.w);
                float srcQy = clamp((qy + 1.0) / w.z - 1.0, -1.0, 1.0);
                float edgeW = mix(w.x, w.y, (qy + 1.0) * 0.5);
                float srcQx = clamp(qx / edgeW, -1.0, 1.0);
                float sx = box.x + (srcQx * 0.5 + 0.5) * box.z;
                float sy = box.y + (1.0 - (srcQy + 1.0) * 0.5) * box.w;
                return vec2(clamp(sx, box.x + 0.5, box.x + box.z - 0.5),
                            clamp(sy, box.y + 0.5, box.y + box.w - 0.5));
            }
            """
            return CIWarpKernel(source: source)
        }()
        
        static func warped(_ image: CIImage, anim: ClipAnimationFrame) -> CIImage {
            let box = image.extent
            guard box.width > 1, box.height > 1, box.width.isFinite, box.height.isFinite else { return image }
            let topW = CGFloat(max(anim.warpTopWidth, 0.1))
            let bottomW = CGFloat(max(anim.warpBottomWidth, 0.1))
            let height = CGFloat(max(anim.warpHeight, 0.1))
            
            if let kernel = warpKernel,
               let result = kernel.apply(extent: box,
                                         roiCallback: { _, _ in box },
                                         image: image,
                                         arguments: [CIVector(x: box.minX, y: box.minY, z: box.width, w: box.height),
                                                     CIVector(x: topW, y: bottomW, z: height)]) {
                return result
            }
            
            // Fallback: trapezoid (y-up coordinates; the top edge stays where it is).
            let cx = box.midX
            let topY = box.maxY
            let bottomY = box.maxY - box.height * height
            return image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: cx - box.width * topW / 2, y: topY),
                "inputTopRight": CIVector(x: cx + box.width * topW / 2, y: topY),
                "inputBottomLeft": CIVector(x: cx - box.width * bottomW / 2, y: bottomY),
                "inputBottomRight": CIVector(x: cx + box.width * bottomW / 2, y: bottomY)
            ])
        }
        
        /// Apply a track's preferredTransform (defined in y-down video space) to a y-up CIImage,
        /// and normalise the result to origin (0,0). Without this, portrait iPhone clips are sideways.
        private static func upright(_ image: CIImage, _ t: CGAffineTransform) -> CIImage {
            let normalized: (CIImage) -> CIImage = {
                $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY))
            }
            if t.isIdentity { return normalized(image) }
            let h = image.extent.height
            var img = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) // → y-down
            img = img.transformed(by: t)
            let e = img.extent
            img = img.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: e.minY + e.maxY)) // → y-up
            return normalized(img)
        }
        
        private static func cachedImage(_ url: URL) -> CIImage? {
            let key = url.path as NSString
            if let hit = mediaCache.object(forKey: key) { return hit }
            guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            let normalized = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY))
            mediaCache.setObject(normalized, forKey: key)
            return normalized
        }
    }
}

// MARK: - Project settings (project.settings)

extension EditingView.VideoSettings {
    /// Android's default when a project has no settings file (EditingActivity.onCreate).
    static var androidDefault: EditingView.VideoSettings {
        EditingView.VideoSettings(videoWidth: 1366, videoHeight: 768, frameRate: 30, crf: 30,
                                  clipCap: 30, preset: "MEDIUM", tune: "ZEROLATENCY", isStretchToFull: false)
    }
    
    static func load(projectPath: String) -> EditingView.VideoSettings {
        let path = IOHelper.combinePath(projectPath, Constants.DEFAULT_VIDEO_SETTINGS_FILENAME)
        let json = IOHelper.readFromFile(path)
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EditingView.VideoSettings.self, from: data),
              decoded.videoWidth > 0, decoded.videoHeight > 0, decoded.frameRate > 0 else {
            return androidDefault
        }
        return decoded
    }
}
