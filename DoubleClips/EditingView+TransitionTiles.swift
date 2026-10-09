import SwiftUI
import CoreImage
import UIKit

// MARK: - Transition preview tiles
//
// The transition panel's style grid, like the effects grid: every tile shows the style drawn live by
// the same blend the compositor uses (ClipCompositor.blend), on two stand-in pictures, A (blue / teal)
// and B (orange / pink), frozen halfway through. The selected tile loops 0 -> 1 so the style can be
// seen moving. Styles iOS doesn't draw yet show the cross fade they really play as.

enum TransitionTileRenderer {
    
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static var side: CGFloat { CGFloat(Constants.TRANSITION_TILE_PIXELS) }
    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()
    
    private static let pictures: (CIImage, CIImage)? = {
        guard let a = picture("A", [UIColor(red: 0.18, green: 0.42, blue: 1.0, alpha: 1), UIColor(red: 0.0, green: 0.76, blue: 0.66, alpha: 1)]),
              let b = picture("B", [UIColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1), UIColor(red: 0.95, green: 0.2, blue: 0.55, alpha: 1)])
        else { return nil }
        return (a, b)
    }()
    
    private static func picture(_ letter: String, _ colors: [UIColor]) -> CIImage? {
        let size = side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let cg = ctx.cgContext
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors.map { $0.cgColor } as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.5, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92)
            ]
            let text = letter as NSString
            let box = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - box.width) / 2, y: (size - box.height) / 2), withAttributes: attributes)
        }
        return image.cgImage.map { CIImage(cgImage: $0) }
    }
    
    /// The blend of A and B at `progress` for a stored style key.
    static func image(style key: String, progress: CGFloat) -> UIImage? {
        guard let (a, b) = pictures else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let normalized = TransitionPlan.normalizedStyle(key)
        let result = normalized == "none"
            ? a
            : EditingView.ClipCompositor.blend(a, b, style: normalized, progress: progress, canvas: canvas)
        guard let output = result, let cg = context.createCGImage(output, from: canvas) else { return nil }
        return UIImage(cgImage: cg)
    }
    
    /// Halfway through, cached.
    static func staticImage(style key: String) -> UIImage? {
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let made = image(style: key, progress: 0.5) else { return nil }
        lock.lock(); cache[key] = made; lock.unlock()
        return made
    }
}

struct TransitionPreviewTile: View {
    let styleKey: String
    /// Loop the transition (the selected tile) instead of showing it halfway.
    let animating: Bool
    
    var body: some View {
        ZStack {
            if animating {
                TimelineView(.animation) { timeline in
                    let loop = Constants.TRANSITION_TILE_LOOP_SECONDS
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop) / loop
                    // A short rest on A, the move, a short rest on B.
                    let progress = phase < 0.15 ? 0 : (phase > 0.85 ? 1 : (phase - 0.15) / 0.7)
                    picture(TransitionTileRenderer.image(style: styleKey, progress: CGFloat(progress)))
                }
            } else {
                picture(TransitionTileRenderer.staticImage(style: styleKey))
            }
        }
    }
    
    @ViewBuilder
    private func picture(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.white.opacity(0.1)
        }
    }
}
