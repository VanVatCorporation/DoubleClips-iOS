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
    
    // Every drawn style is a file (animations/transitions/*.json: TransitionStyleLoader); a style without one plays as a cross fade.
    
    static func blend(_ a: CIImage?, _ b: CIImage?, style: String, progress: CGFloat, canvas: CGRect) -> CIImage? {
        if a == nil && b == nil { return nil }
        let p = min(max(progress, 0), 1)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        /// Canvas-sized, so masks and crops line up even when a clip covers only part of the canvas.
        func full(_ image: CIImage?) -> CIImage {
            (image ?? clear).composited(over: clear).cropped(to: canvas)
        }
        let from = full(a), to = full(b)
        
        // A style defined by a JSON file wins over everything below.
        if let definition = TransitionStyleLoader.get(style) {
            return dataDrivenBlend(from, to, style: definition, progress: p, canvas: canvas)
        }

        // A style without a file (Android's others, a newer version's): cross fade, like Android's shader does for a style it doesn't know.
        return crossFade(from, to, progress: p)
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
    
    /// `top` where the mask is white, `bottom` where it is black.
    static func masked(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bottom,
            kCIInputMaskImageKey: mask
        ])
    }
}
