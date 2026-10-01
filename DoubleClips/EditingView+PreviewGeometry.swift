import UIKit

// MARK: - Preview geometry + live overrides
//
// Shared by the on-canvas editing layer (hit testing, selection box) so touch targets match
// exactly what `ClipCompositor` draws. Same maths as OpenGLEdit.buildClipMvp: PosX/PosY is the
// unscaled top-left corner in canvas pixels (+Y down); scale and rotation happen around the
// normalized pivot; rotation is clockwise degrees.

extension EditingView {
    
    /// Properties + keyframes a gesture is currently producing, before they are committed.
    struct LiveClipState {
        var properties: VideoProperties
        var keyframes: AnimatedProperty
    }
    
    /// Thread-safe side channel: the main thread writes while a gesture is in flight, the
    /// compositor's render queue reads. That is what makes dragging feel live without rebuilding
    /// the AVPlayerItem on every touch move. Cleared on commit, after the rebuild took over.
    final class LiveOverrides {
        static let shared = LiveOverrides()
        private let lock = NSLock()
        private var states: [UUID: LiveClipState] = [:]
        
        func set(_ state: LiveClipState, for id: UUID) {
            lock.lock(); states[id] = state; lock.unlock()
        }
        func state(for id: UUID) -> LiveClipState? {
            lock.lock(); defer { lock.unlock() }
            return states[id]
        }
        func clear(_ id: UUID) {
            lock.lock(); states[id] = nil; lock.unlock()
        }
    }
    
    enum ClipGeometry {
        
        /// Corners TL, TR, BR, BL in canvas pixels (y down).
        static func quad(baseW: CGFloat, baseH: CGFloat, props: VideoProperties) -> [CGPoint] {
            let scaledW = baseW * CGFloat(props.valueScaleX)
            let scaledH = baseH * CGFloat(props.valueScaleY)
            let px = CGFloat(props.valuePivotX), py = CGFloat(props.valuePivotY)
            let pivot = CGPoint(x: CGFloat(props.valuePosX) + px * baseW,
                                y: CGFloat(props.valuePosY) + py * baseH)
            let theta = CGFloat(props.value(.rotInRadians))
            let c = cos(theta), s = sin(theta)
            func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let x = (u - px) * scaledW, y = (v - py) * scaledH
                return CGPoint(x: pivot.x + x * c - y * s, y: pivot.y + x * s + y * c)
            }
            return [map(0, 0), map(1, 0), map(1, 1), map(0, 1)]
        }
        
        /// Text is drawn centered on the canvas + PosX/PosY, unscaled and unrotated (drawtext).
        static func textQuad(text: String, fontSize: CGFloat, props: VideoProperties, canvas: CGSize) -> [CGPoint] {
            let size = textSize(text, fontSize: fontSize)
            let cx = canvas.width / 2 + CGFloat(props.valuePosX)
            let cy = canvas.height / 2 + CGFloat(props.valuePosY)
            let l = cx - size.width / 2, r = cx + size.width / 2
            let t = cy - size.height / 2, b = cy + size.height / 2
            return [CGPoint(x: l, y: t), CGPoint(x: r, y: t), CGPoint(x: r, y: b), CGPoint(x: l, y: b)]
        }
        
        /// Same font + padding as the compositor's text image.
        static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
            let s = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: max(fontSize, 1))
            ]).size()
            return CGSize(width: ceil(s.width) + 4, height: ceil(s.height) + 4)
        }
        
        /// Convex-quad hit test (works for mirrored/negative scales too).
        static func contains(_ p: CGPoint, quad: [CGPoint]) -> Bool {
            guard quad.count == 4 else { return false }
            var area: CGFloat = 0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                area += a.x * b.y - b.x * a.y
            }
            if abs(area) < 1 { return false } // collapsed (scale 0)
            var sign = 0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                let s = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
                if s == 0 { continue }
                if sign == 0 { sign = s } else if sign != s { return false }
            }
            return true
        }
    }
}

extension EditingView.Clip {
    
    var isVisualClip: Bool { type == .video || type == .image || type == .text }
    
    func isActive(at time: Float) -> Bool { time >= startTime && time < startTime + duration }
    
    /// Canvas-space quad at `time`, using the gesture's live state when one exists.
    func previewQuad(at time: Float, canvas: CGSize, stretchToFull: Bool,
                     live: EditingView.LiveClipState? = nil) -> [CGPoint]? {
        let base = live?.properties ?? videoProperties
        let keys = live?.keyframes ?? keyframes
        let props = keys.resolved(base: base, clipStartTime: startTime, at: time)
        
        switch type {
        case .video, .image:
            // Same fallbacks as ClipCompositor.place; clips without a stored size use the canvas.
            let baseW = stretchToFull ? canvas.width : (width > 0 ? CGFloat(width) : canvas.width)
            let baseH = stretchToFull ? canvas.height : (height > 0 ? CGFloat(height) : canvas.height)
            return EditingView.ClipGeometry.quad(baseW: baseW, baseH: baseH, props: props)
        case .text:
            return EditingView.ClipGeometry.textQuad(text: textContent ?? "", fontSize: CGFloat(fontSize ?? 30),
                                                      props: props, canvas: canvas)
        default:
            return nil
        }
    }
}
