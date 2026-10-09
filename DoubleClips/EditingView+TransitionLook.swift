import CoreImage
import UIKit

// MARK: - The "look" stack shared by the clip pipeline and data-driven transition styles
//
// `streakStack` is the part of ClipCompositor.place that works on the picture AFTER it sits in canvas space: edge
// fill, edge slide, squeeze, motion blur, blur. `looked` applies a whole ClipAnimationFrame to a plain full-canvas
// picture (what the transition style tiles use; the real render goes through `place`, which does the same things
// about the clip's own pivot instead of the canvas centre).

extension EditingView.ClipCompositor {
    
    /// `placed` is the clip's picture in canvas space (Core Image's y axis points up). `canvas` is the output rect.
    static func streakStack(_ picture: CIImage, anim: ClipAnimationFrame, canvas: CGRect) -> CIImage {
        var placed = picture
        guard placed.extent.width.isFinite, placed.extent.height.isFinite, !placed.extent.isEmpty else { return placed }
        
        // Edge fill (iOS only): the picture's edge pixels cover the whole canvas, so a shrunken picture leaves no
        // black margin (CapCut's Glitch Blur shrinks A and B without showing one).
        if anim.edgeFill > 0.5 {
            placed = placed.clampedToExtent().cropped(to: canvas)
        }
        
        // Edge slide (iOS only): the picture slides inside its own box, the edge pixels stretch into the gap.
        // `edgeSlide` is horizontal (+ = right), `edgeSlideY` vertical (+ = down; Core Image's y points up).
        let slide = CGFloat(anim.edgeSlideFraction) * canvas.width
        let slideY = -CGFloat(anim.edgeSlideYFraction) * canvas.height
        if abs(slide) > 0.5 || abs(slideY) > 0.5 {
            let box = placed.extent
            placed = placed.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: slide, y: slideY))
                .cropped(to: box)
        }
        
        // Squeeze (iOS only): the picture is compressed horizontally toward its anchor (0 = left edge, 1 = right
        // edge) and the edge pixels smear into the space it leaves, like being pulled into a black hole.
        let squeeze = CGFloat(anim.squeezeX)
        if abs(squeeze - 1) > 0.002 {
            let box = placed.extent
            let anchorX = box.minX + CGFloat(anim.squeezeAnchor) * box.width
            let about = CGAffineTransform(translationX: -anchorX, y: 0)
                .concatenating(CGAffineTransform(scaleX: squeeze, y: 1))
                .concatenating(CGAffineTransform(translationX: anchorX, y: 0))
            placed = placed.clampedToExtent().transformed(by: about).cropped(to: box)
        }
        
        // Motion blur (iOS only): streaks along `blurAngle` (0 = horizontal), edges clamped so the picture
        // doesn't fade at its border.
        let streak = CGFloat(anim.motionBlurWidthFraction) * canvas.width
        if streak > 0.5 {
            let box = placed.extent
            let radius = streak * Constants.MOTION_BLUR_RADIUS_FACTOR
            // Long streaks (Shake Slide reaches most of the canvas width) are blurred on a shrunken copy: the filter is
            // happiest below about 60 px, and the result is smooth anyway.
            let shrink = max(1, radius / 60)
            let down = CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink)
            let up = CGAffineTransform(scaleX: shrink, y: shrink)
            placed = placed.clampedToExtent()
                .transformed(by: down)
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius / shrink,
                                                             kCIInputAngleKey: CGFloat(anim.blurAngleDegrees) * .pi / 180])
                .transformed(by: up)
                .cropped(to: box)
        }
        
        // Blur sigma is a fraction of the canvas WIDTH, applied to the drawn layer in canvas pixels.
        let sigma = CGFloat(anim.blurWidthFraction) * canvas.width
        if sigma > 0.25 {
            placed = placed.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
        }
        return placed
    }
    
    /// A plain full-canvas picture with a frame's channels applied (tiles / previews).
    static func looked(_ image: CIImage, anim: ClipAnimationFrame, canvas: CGRect) -> CIImage {
        var out = colorAdjusted(image, EditingView.VideoProperties(), anim: anim)
        if anim.hasWarp { out = warped(out, anim: anim) }
        
        let scale = CGFloat(anim.scale)
        let angle = CGFloat(anim.rotationDegrees) * .pi / 180
        let shiftX = CGFloat(anim.offsetX) * canvas.width
        let shiftY = -CGFloat(anim.offsetY) * canvas.height          // offsetY is + = down, Core Image's y points up
        if scale != 1 || angle != 0 || shiftX != 0 || shiftY != 0 {
            let transform = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(rotationAngle: -angle))
                .concatenating(CGAffineTransform(translationX: canvas.midX + shiftX, y: canvas.midY + shiftY))
            out = out.transformed(by: transform)
        }
        return streakStack(out, anim: anim, canvas: canvas).cropped(to: canvas)
    }
    
    /// The data-driven blend: one picture, A before the style's cut and B after it, each with its side's look.
    static func dataDrivenBlend(_ from: CIImage, _ to: CIImage, style: TransitionStyle,
                                progress p: CGFloat, canvas: CGRect) -> CIImage {
        let showFrom = Double(p) < style.cut
        let frame = (showFrom ? style.from : style.to).evaluate(Float(p))
        return looked(showFrom ? from : to, anim: frame, canvas: canvas)
    }
}
