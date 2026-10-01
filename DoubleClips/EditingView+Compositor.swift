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
                return place(upright, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull)
                
            case .image(let url):
                guard let source = Self.cachedImage(url) else { return nil }
                return place(source, layer: layer, props: props, canvas: canvas, stretchToFull: stretchToFull)
            }
        }
        
        /// Color adjustments (same order as FFmpegEdit: hue/sat/brightness → temperature → opacity),
        /// then the pivot-based scale/rotate/translate from OpenGLEdit.buildClipMvp.
        private func place(_ source: CIImage, layer: RenderLayer, props: VideoProperties,
                           canvas: CGSize, stretchToFull: Bool) -> CIImage? {
            let srcW = source.extent.width, srcH = source.extent.height
            guard srcW > 0, srcH > 0 else { return nil }
            
            let baseW = stretchToFull ? canvas.width : (layer.width > 0 ? layer.width : srcW)
            let baseH = stretchToFull ? canvas.height : (layer.height > 0 ? layer.height : srcH)
            let scaledW = baseW * CGFloat(props.valueScaleX)
            let scaledH = baseH * CGFloat(props.valueScaleY)
            guard scaledW > 0, scaledH > 0 else { return nil }
            
            let colored = Self.colorAdjusted(source, props)
            
            let pivotX = CGFloat(props.valuePivotX), pivotY = CGFloat(props.valuePivotY)
            // Pivot inside the scaled clip, in Core Image's y-up space.
            let pivotLocal = CGPoint(x: pivotX * scaledW, y: scaledH - pivotY * scaledH)
            // Pivot on the canvas: located on the UNSCALED clip, so it stays put (Android's rule).
            let pivotCanvasDown = CGPoint(x: CGFloat(props.valuePosX) + pivotX * baseW,
                                          y: CGFloat(props.valuePosY) + pivotY * baseH)
            let pivotCanvas = CGPoint(x: pivotCanvasDown.x, y: canvas.height - pivotCanvasDown.y)
            let theta = CGFloat(props.value(.rotInRadians))
            
            // scale → move pivot to origin → rotate → move pivot to its canvas position.
            // Android's positive angle is clockwise on a y-down canvas = -theta in y-up space.
            let transform = CGAffineTransform(scaleX: scaledW / srcW, y: scaledH / srcH)
                .concatenating(CGAffineTransform(translationX: -pivotLocal.x, y: -pivotLocal.y))
                .concatenating(CGAffineTransform(rotationAngle: -theta))
                .concatenating(CGAffineTransform(translationX: pivotCanvas.x, y: pivotCanvas.y))
            return colored.transformed(by: transform)
        }
        
        // MARK: Helpers
        
        private static func colorAdjusted(_ image: CIImage, _ p: VideoProperties) -> CIImage {
            var out = image
            if p.valueSaturation != 1 || p.valueBrightness != 0 {
                out = out.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: p.valueSaturation,
                    kCIInputBrightnessKey: p.valueBrightness,
                    kCIInputContrastKey: 1.0
                ])
            }
            if p.valueHue != 0 {
                out = out.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: p.valueHue * .pi / 180])
            }
            if abs(p.valueTemperature - 6500) > 1 {
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(p.valueTemperature), y: 0),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0)
                ])
            }
            if p.valueOpacity < 1 {
                out = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, p.valueOpacity)))
                ])
            }
            return out
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
