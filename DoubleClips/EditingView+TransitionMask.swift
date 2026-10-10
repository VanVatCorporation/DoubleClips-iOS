import CoreImage
import UIKit

// MARK: - Mask transitions ("mode": "mask" in animations/transitions/*.json)
//
// Both clips are drawn for the whole window (A with the `from` channels, B with the `to` channels, either may be left out) and
// B is revealed through a mask picture: white = B, black = A. The mask is one of a fixed set of shapes, parameterized (and
// animated) by the file; `reveal` (0...1 over the window) says how much of B is showing:
//   wipe     angle (degrees, direction the edge travels, 180 = right to left), softness (fraction of the length), flag normalized
//            (angle in canvas proportions, for the diagonals)
//   circle   cx, cy (0...1 from the left / top), softness (fraction of the radius), flag invert (B outside the circle)
//   noise    softness, grain (pixels): every pixel flips at its own moment
//   slices   angle (direction B grows inside each strip), count: strips along that direction
//   clock    start (degrees clockwise from 12 o'clock): a sweeping hand

extension EditingView.ClipCompositor {
    
    /// The mask picture (canvas-sized, white where B shows) for a transition at `progress` (0...1).
    static func transitionMask(_ mask: EffectFilter, progress p: CGFloat, canvas: CGRect) -> CIImage {
        func v(_ name: String) -> CGFloat {
            guard let curve = mask.curves[name] else { return 0 }
            return CGFloat(curve.at(Double(p)))
        }
        let black = CIImage(color: .black).cropped(to: canvas)
        let white = CIImage(color: .white).cropped(to: canvas)
        let r = min(max(v("reveal"), 0), 1)
        if r <= 0 { return black }
        if r >= 1 { return white }
        let w = canvas.width, h = canvas.height
        let c = CGPoint(x: canvas.midX, y: canvas.midY)
        let fallback = r > 0.5 ? white : black
        
        switch mask.op {
        case "wipe":
            let theta = v("angle") * .pi / 180
            let dx = cos(theta), dy = sin(theta)
            let normalized = mask.flags.contains("normalized")
            // s runs from -0.5 (the back edge) to +0.5 (the front edge) along the direction; B is where s <= edge.
            let gx = normalized ? dx / w : dx
            let gy = normalized ? dy / h : dy
            let denom = normalized ? abs(dx) + abs(dy) : abs(w * dx) + abs(h * dy)
            let g2 = gx * gx + gy * gy
            guard denom > 0, g2 > 0 else { return fallback }
            let half = max(v("softness") / 2, 0.5 * g2.squareRoot() / denom)
            let edge = -0.5 + r
            func point(_ s: CGFloat) -> CIVector {
                let t = s * denom / g2
                return CIVector(x: c.x + gx * t, y: c.y + gy * t)
            }
            guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": point(edge - half), "inputPoint1": point(edge + half),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black
            ])?.outputImage else { return fallback }
            return gradient.cropped(to: canvas)
            
        case "circle":
            let center = CGPoint(x: canvas.minX + w * v("cx"), y: canvas.maxY - h * v("cy"))
            let far = max(hypot(center.x - canvas.minX, center.y - canvas.minY), hypot(center.x - canvas.maxX, center.y - canvas.minY),
                          hypot(center.x - canvas.minX, center.y - canvas.maxY), hypot(center.x - canvas.maxX, center.y - canvas.maxY))
            let invert = mask.flags.contains("invert")
            let radius = far * (invert ? 1 - r : r)
            let soft = max(2, far * v("softness"))
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": radius, "inputRadius1": radius + soft,
                "inputColor0": invert ? CIColor.black : CIColor.white,
                "inputColor1": invert ? CIColor.white : CIColor.black
            ])?.outputImage else { return fallback }
            return gradient.cropped(to: canvas)
            
        case "noise":
            // A fixed noise picture compared with a rising threshold: B where noise > 1 - reveal.
            guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return fallback }
            let grain = max(1, v("grain"))
            let source = grain > 1.01
                ? noise.samplingNearest().transformed(by: CGAffineTransform(scaleX: grain, y: grain))
                : noise
            let gain = 1 / max(v("softness"), 0.001)
            let bias = -gain * (1 - r)
            return source.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ]).cropped(to: canvas)
            
        case "slices":
            // Built along the direction of travel (x axis), then turned and moved onto the canvas.
            let theta = v("angle") * .pi / 180
            let count = max(1, Int(v("count").rounded()))
            let length = abs(w * cos(theta)) + abs(h * sin(theta))
            let band = length / CGFloat(count)
            let span = hypot(w, h)
            var strips = CIImage(color: .black).cropped(to: CGRect(x: -span, y: -span, width: span * 2, height: span * 2))
            for k in 0..<count {
                let rect = CGRect(x: -length / 2 + CGFloat(k) * band, y: -span, width: band * r, height: span * 2)
                strips = CIImage(color: .white).cropped(to: rect).composited(over: strips)
            }
            return strips.transformed(by: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: theta)).cropped(to: canvas)
            
        case "clock":
            // A pie slice drawn into a grey bitmap: from the start angle, clockwise, `reveal` of a full turn.
            let width = Int(ceil(w)), height = Int(ceil(h))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return fallback }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 1, alpha: 1)
            let center = CGPoint(x: w / 2, y: h / 2)
            let startAngle = CGFloat.pi / 2 - v("start") * .pi / 180
            context.move(to: center)
            context.addArc(center: center, radius: hypot(w, h), startAngle: startAngle,
                           endAngle: startAngle - 2 * .pi * r, clockwise: true)
            context.closePath()
            context.fillPath()
            guard let image = context.makeImage() else { return fallback }
            return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY)).cropped(to: canvas)
            
        default:
            return fallback
        }
    }
}
