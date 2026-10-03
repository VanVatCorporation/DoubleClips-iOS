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
//   - TEXT is centered on the canvas, offset by PosX/PosY, and ignores scale/rotation/opacity
//     (Android draws it with ffmpeg drawtext).
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
            case text(String, CGFloat)
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
    }
    
    final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
        let timeRange: CMTimeRange
        let enablePostProcessing = false
        let containsTweening = true
        let requiredSourceTrackIDs: [NSValue]?
        let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        let layers: [RenderLayer]
        let stretchToFull: Bool
        
        init(timeRange: CMTimeRange, layers: [RenderLayer], stretchToFull: Bool) {
            self.timeRange = timeRange
            self.layers = layers
            self.stretchToFull = stretchToFull
            var ids: [NSValue] = []
            var seen = Set<CMPersistentTrackID>()
            for layer in layers {
                if case .video(let id, _) = layer.kind, seen.insert(id).inserted {
                    ids.append(NSNumber(value: id))
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
                    for layer in instruction.layers {
                        if let image = render(layer, request: request, canvas: canvas,
                                              time: time, stretchToFull: instruction.stretchToFull) {
                            frame = image.composited(over: frame)
                        }
                    }
                    ciContext.render(frame, to: output, bounds: canvasRect, colorSpace: colorSpace)
                    request.finish(withComposedVideoFrame: output)
                }
            }
        }
        
        // MARK: Per-layer rendering
        
        private func render(_ layer: RenderLayer, request: AVAsynchronousVideoCompositionRequest,
                            canvas: CGSize, time: Float, stretchToFull: Bool) -> CIImage? {
            // A gesture in progress overrides the snapshot without rebuilding the player item.
            let live = LiveOverrides.shared.state(for: layer.clipID)
            let props = (live?.keyframes ?? layer.keyframes).resolved(base: live?.properties ?? layer.baseProperties,
                                                                     clipStartTime: layer.startTime, at: time)
            
            switch layer.kind {
            case .text(let text, let fontSize):
                guard !text.isEmpty, let img = Self.textImage(text, fontSize: fontSize) else { return nil }
                // drawtext: x = (w - text_w)/2 + PosX, y = (h - text_h)/2 + PosY  (y down)
                let cx = canvas.width / 2 + CGFloat(props.valuePosX)
                let cyDown = canvas.height / 2 + CGFloat(props.valuePosY)
                return img.transformed(by: CGAffineTransform(
                    translationX: cx - img.extent.width / 2,
                    y: (canvas.height - cyDown) - img.extent.height / 2))
                
            case .video(let trackID, let preferredTransform):
                guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
                let upright = Self.upright(CIImage(cvPixelBuffer: buffer), preferredTransform)
                return place(upright, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull,
                             anim: Self.animationFrame(layer, at: time))
                
            case .image(let url):
                guard let source = Self.cachedImage(url) else { return nil }
                return place(source, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull,
                             anim: Self.animationFrame(layer, at: time))
            }
        }
        
        /// Color adjustments (same order as FFmpegEdit: hue/sat/brightness → temperature → opacity),
        /// then the pivot-based scale/rotate/translate from OpenGLEdit.buildClipMvp.
        private func place(_ source: CIImage, layer: RenderLayer, props: VideoProperties,
                           canvas: CGSize, stretchToFull: Bool, anim: ClipAnimationFrame) -> CIImage? {
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
            let posX = CGFloat(props.valuePosX) + CGFloat(anim.offsetX) * canvas.width
            let posY = CGFloat(props.valuePosY) + CGFloat(anim.offsetY) * canvas.height
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
            let sigma = CGFloat(anim.blurWidthFraction) * canvas.width
            if sigma > 0.25 {
                placed = placed.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            }
            return placed
        }
        
        // MARK: Helpers
        
        /// Clip properties plus the animation's channels: hue / brightness / temperature add,
        /// saturation / opacity multiply, contrast stands alone (the clip has none). The animation's
        /// brightness is in Android's -10..10 units, which its shader scales by 0.1 before adding.
        private static func colorAdjusted(_ image: CIImage, _ p: VideoProperties, anim: ClipAnimationFrame) -> CIImage {
            let saturation = p.valueSaturation * anim.saturation
            let brightness = p.valueBrightness + anim.brightness * 0.1
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
                let outDur = ClipAnimation.fitDuration(outRaw, other: inRaw, clip: layer.duration)
                let p = ClipAnimation.progressOut(clipEnd: layer.startTime + layer.duration, t: t, duration: outDur)
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
        
        private static func warped(_ image: CIImage, anim: ClipAnimationFrame) -> CIImage {
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
        
        private static func textImage(_ text: String, fontSize: CGFloat) -> CIImage? {
            let key = "text|\(fontSize)|\(text)" as NSString
            if let hit = mediaCache.object(forKey: key) { return hit }
            let attributed = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: max(fontSize, 1)),
                .foregroundColor: UIColor.white
            ])
            let textSize = attributed.size()
            let pad: CGFloat = 2
            let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad * 2)
            guard size.width > 0, size.height > 0 else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                attributed.draw(at: CGPoint(x: pad, y: pad))
            }
            guard let cg = rendered.cgImage else { return nil }
            let image = CIImage(cgImage: cg)
            mediaCache.setObject(image, forKey: key)
            return image
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
