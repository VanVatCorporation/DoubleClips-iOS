import CoreImage
import UIKit

// MARK: - Transition blend (Core Image)
//
// Counterpart of Android's TransitionBlendShader: `from` and `to` are the two clips, each already
// drawn on a canvas-sized, transparent-where-empty picture; the result is one canvas-sized picture
// that becomes the track's layer. `progress` runs 0 -> 1 across the window.
//
// Directions follow FFmpeg's xfade names (what Android's FFmpeg export does):
//   wipeleft   B is revealed from the right edge, sweeping left   (wiperight: mirrored)
//   slideleft  both pictures move left together, B enters from the right (slideright: mirrored)
//   slideup    both pictures move up together, B enters from the bottom  (slidedown: mirrored)
// Android's GPU shader is documented there as "not re-verified"; if its slideup / slidedown look
// reversed against FFmpeg, that is on its side.
//
// Styles Android lists that aren't drawn here (radial, slices, pixelize, ...) fall back to a cross
// fade, exactly like Android's shader does for a style it doesn't know.

extension EditingView.ClipCompositor {
    
    /// Keys `blend` draws itself. Everything else renders as a cross fade.
    static let drawnTransitionStyles: Set<String> = [
        "fade", "dissolve", "wipeleft", "wiperight", "slideleft", "slideright", "slideup", "slidedown",
        "fadeblack", "fadewhite", "fadegrays", "circleopen", "circleclose",
        "glitchblur"        // iOS only (see DoubleClips-Glitch-Blur-and-Shake-Slide-Notes.md)
    ]
    
    static func blend(_ a: CIImage?, _ b: CIImage?, style: String, progress: CGFloat, canvas: CGRect) -> CIImage? {
        if a == nil && b == nil { return nil }
        let p = min(max(progress, 0), 1)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        /// Canvas-sized, so masks and crops line up even when a clip covers only part of the canvas.
        func full(_ image: CIImage?) -> CIImage {
            (image ?? clear).composited(over: clear).cropped(to: canvas)
        }
        let from = full(a), to = full(b)
        let w = canvas.width, h = canvas.height
        
        switch style {
        case "wipeleft":
            let edge = canvas.minX + w * (1 - p)
            let revealed = CGRect(x: edge, y: canvas.minY, width: canvas.maxX - edge, height: h)
            let kept = CGRect(x: canvas.minX, y: canvas.minY, width: edge - canvas.minX, height: h)
            return to.cropped(to: revealed).composited(over: from.cropped(to: kept))
            
        case "wiperight":
            let edge = canvas.minX + w * p
            let revealed = CGRect(x: canvas.minX, y: canvas.minY, width: edge - canvas.minX, height: h)
            let kept = CGRect(x: edge, y: canvas.minY, width: canvas.maxX - edge, height: h)
            return to.cropped(to: revealed).composited(over: from.cropped(to: kept))
            
        case "slideleft":
            return pushed(from, to, fromShift: CGPoint(x: -w * p, y: 0), toShift: CGPoint(x: w * (1 - p), y: 0))
        case "slideright":
            return pushed(from, to, fromShift: CGPoint(x: w * p, y: 0), toShift: CGPoint(x: -w * (1 - p), y: 0))
        case "slideup":      // Core Image's y axis points up
            return pushed(from, to, fromShift: CGPoint(x: 0, y: h * p), toShift: CGPoint(x: 0, y: -h * (1 - p)))
        case "slidedown":
            return pushed(from, to, fromShift: CGPoint(x: 0, y: -h * p), toShift: CGPoint(x: 0, y: h * (1 - p)))
            
        case "fadeblack":
            return throughColor(from, to, color: .black, progress: p, canvas: canvas)
        case "fadewhite":
            return throughColor(from, to, color: .white, progress: p, canvas: canvas)
        case "fadegrays":
            // Both pictures lose their colour toward the middle, cross fading as they go.
            let gray: (CIImage, CGFloat) -> CIImage = { image, saturation in
                image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: max(0, saturation)])
            }
            return crossFade(gray(from, 1 - 2 * p), gray(to, 2 * p - 1), progress: p)
            
        case "circleopen", "circleclose":
            let maxRadius = hypot(w, h) / 2
            let open = style == "circleopen"
            let radius = max(0, maxRadius * (open ? p : 1 - p))
            let inside = open ? CIColor.white : CIColor.black     // circleopen: B inside, circleclose: B outside
            let outside = open ? CIColor.black : CIColor.white
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: canvas.midX, y: canvas.midY),
                "inputRadius0": radius,
                "inputRadius1": radius + 2,
                "inputColor0": inside,
                "inputColor1": outside
            ])?.outputImage else { return crossFade(from, to, progress: p) }
            return masked(to, over: from, mask: gradient.cropped(to: canvas))
            
        case "glitchblur":
            return glitchBlur(from, to, progress: p, canvas: canvas)
            
        case "dissolve":
            // Every pixel flips from A to B at its own moment: a fixed noise picture compared with
            // a rising threshold (Android only approximates dissolve with a fade).
            guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return crossFade(from, to, progress: p) }
            let gain: CGFloat = 1000
            let bias = -gain * (1 - p)
            let mask = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ]).cropped(to: canvas)
            return masked(to, over: from, mask: mask)
            
        default:    // fade and every style that isn't drawn here
            return crossFade(from, to, progress: p)
        }
    }
    
    // MARK: Glitch Blur
    //
    // Read off CapCut's "Glitch Blur" (reference frames at 60 fps, 1.1 s): no cross dissolve at all. A is
    // swept into a streaked blur (diagonal motion blur, red / blue pulled apart along the streaks, washed
    // out toward white, shrinking a little), the picture HARD-CUTS to B at the peak, and B arrives in the same
    // streaked blur and settles. So: intensity rises to 1 at the cut and falls again, and the picture under it
    // is A before the cut and B after it. All the numbers are in Constants.GLITCH_*.
    
    private static func glitchBlur(_ from: CIImage, _ to: CIImage, progress p: CGFloat, canvas: CGRect) -> CIImage {
        let cut = min(max(Constants.GLITCH_BLUR_CUT, 0.05), 0.95)
        let outgoing = p < cut
        let base = outgoing ? from : to
        let u = outgoing ? p / cut : (1 - p) / (1 - cut)                 // 0 ... 1, 1 at the cut
        let intensity = pow(min(max(u, 0), 1), outgoing ? Constants.GLITCH_BLUR_IN_POWER : Constants.GLITCH_BLUR_OUT_POWER)
        guard intensity > 0.002 else { return base }
        let w = canvas.width
        
        // Scale about the centre: A shrinks, B starts a little large.
        let scale = outgoing ? 1 - Constants.GLITCH_ZOOM_OUT * intensity : 1 + Constants.GLITCH_ZOOM_IN * intensity
        let about = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
        var picture = base.transformed(by: about)
        
        // Streaks (edges clamped so the shrunken picture doesn't leave a hole).
        let angle = Constants.GLITCH_BLUR_ANGLE_DEGREES * .pi / 180
        let streak = intensity * Constants.GLITCH_BLUR_LENGTH_FRACTION * w
        if streak > 0.5 {
            picture = picture.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: streak * Constants.MOTION_BLUR_RADIUS_FACTOR,
                                                             kCIInputAngleKey: angle])
                .cropped(to: canvas)
        } else {
            picture = picture.cropped(to: canvas)
        }
        
        // Red and blue pulled apart along the streaks.
        let pull = intensity * Constants.GLITCH_FRINGE_FRACTION * w
        if pull > 0.25 {
            picture = rgbSplit(picture, dx: pull * cos(angle), dy: pull * sin(angle), canvas: canvas)
        }
        
        // Washed out: more light, less depth.
        let gain = 1 + Constants.GLITCH_EXPOSURE_GAIN * intensity
        let lift = Constants.GLITCH_EXPOSURE_LIFT * intensity
        return picture.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
        ]).cropped(to: canvas)
    }
    
    /// Red moves by +(dx, dy), blue by -(dx, dy), green stays (Core Image's y axis points up).
    private static func rgbSplit(_ image: CIImage, dx: CGFloat, dy: CGFloat, canvas: CGRect) -> CIImage {
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat, shift: CGPoint) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: shift.x, y: shift.y))
            .cropped(to: canvas)
        }
        let red = channel(1, 0, 0, alpha: 0, shift: CGPoint(x: dx, y: dy))
        let green = channel(0, 1, 0, alpha: 1, shift: .zero)
        let blue = channel(0, 0, 1, alpha: 0, shift: CGPoint(x: -dx, y: -dy))
        // The three channels simply add back up to one picture; alpha comes from the unshifted green.
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: canvas)
    }
    
    // MARK: Building blocks
    
    /// `from` fades out while `to` fades in (premultiplied add, so soft edges stay right).
    private static func crossFade(_ from: CIImage, _ to: CIImage, progress p: CGFloat) -> CIImage {
        let out = scaledAlpha(from, 1 - p)
        let incoming = scaledAlpha(to, p)
        return incoming.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out])
    }
    
    private static func scaledAlpha(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, min(1, alpha)))
        ])
    }
    
    /// Both pictures slide together as one strip; whatever isn't covered stays transparent.
    private static func pushed(_ from: CIImage, _ to: CIImage, fromShift: CGPoint, toShift: CGPoint) -> CIImage {
        to.transformed(by: CGAffineTransform(translationX: toShift.x, y: toShift.y))
            .composited(over: from.transformed(by: CGAffineTransform(translationX: fromShift.x, y: fromShift.y)))
    }
    
    /// A fades to a solid colour in the first half, B fades in from it in the second.
    private static func throughColor(_ from: CIImage, _ to: CIImage, color: CIColor, progress p: CGFloat, canvas: CGRect) -> CIImage {
        let solid = CIImage(color: color).cropped(to: canvas)
        if p < 0.5 {
            return scaledAlpha(from, 1 - 2 * p).composited(over: solid)
        }
        return scaledAlpha(to, 2 * p - 1).composited(over: solid)
    }
    
    /// `top` where the mask is white, `bottom` where it is black.
    private static func masked(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bottom,
            kCIInputMaskImageKey: mask
        ])
    }
}
