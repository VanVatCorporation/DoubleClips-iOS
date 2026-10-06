import UIKit

// MARK: - Canvas gizmo math: resize handles + snapping
//
// Port of the desktop PreviewGizmo (handle ids, `anchor + f * (grabbed - anchor)` scaling, snap lines),
// for touch. All of it is plain geometry on the clip's quad (corners TL, TR, BR, BL in canvas pixels,
// y down) that EditingView.ClipGeometry already computes, so it works for rotated and mirrored clips.
//
// Handle ids: 0-3 are the corners (TL, TR, BR, BL), 4-7 the edge midpoints (top, right, bottom, left);
// edge 4 + i runs from corner i to corner i + 1.

enum CanvasGizmo {
    
    static let top = 4, right = 5, bottom = 6, left = 7
    
    static func handlePoint(_ q: [CGPoint], _ h: Int) -> CGPoint {
        if h < 4 { return q[h] }
        let a = h - top, b = (a + 1) % 4
        return CGPoint(x: (q[a].x + q[b].x) / 2, y: (q[a].y + q[b].y) / 2)
    }
    
    static func opposite(_ h: Int) -> Int {
        h < 4 ? (h + 2) % 4 : top + ((h - top + 2) % 4)
    }
    
    static func center(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: (q[0].x + q[2].x) / 2, y: (q[0].y + q[2].y) / 2)
    }
    
    /// An edge handle is only offered when the edge is long enough on screen that it wouldn't sit on
    /// the corner handles (`screenQuad` is in screen points).
    static func edgeIsLongEnough(_ screenQuad: [CGPoint], edge i: Int) -> Bool {
        let a = screenQuad[i], b = screenQuad[(i + 1) % 4]
        return hypot(b.x - a.x, b.y - a.y) >= Constants.CANVAS_EDGE_MIN_SCREEN_LENGTH
    }
    
    /// The handle under `point` (same space as `screenQuad`: screen points), or nil. Corners win over edges.
    static func hit(screenQuad q: [CGPoint], at point: CGPoint) -> Int? {
        guard q.count == 4 else { return nil }
        let radius = Constants.CANVAS_HANDLE_HIT_POINTS
        var best: (id: Int, distance: CGFloat)?
        for h in 0..<4 {
            let d = hypot(point.x - q[h].x, point.y - q[h].y)
            if d <= radius, d < (best?.distance ?? .infinity) { best = (h, d) }
        }
        if let best { return best.id }
        for i in 0..<4 where edgeIsLongEnough(q, edge: i) {
            let m = handlePoint(q, top + i)
            let d = hypot(point.x - m.x, point.y - m.y)
            if d <= radius, d < (best?.distance ?? .infinity) { best = (top + i, d) }
        }
        return best?.id
    }
    
    // MARK: Snapping
    
    struct SnapLines {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
    }
    
    static func bounds(_ q: [CGPoint]) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        (q.map(\.x).min() ?? 0, q.map(\.x).max() ?? 0, q.map(\.y).min() ?? 0, q.map(\.y).max() ?? 0)
    }
    
    /// What a gesture can snap to: the canvas edges and centre, plus every other visible clip's
    /// edges and centre (the bounding box of its quad).
    static func snapLines(canvas: CGSize, others: [[CGPoint]]) -> SnapLines {
        var lines = SnapLines(xs: [0, canvas.width / 2, canvas.width], ys: [0, canvas.height / 2, canvas.height])
        for q in others where q.count == 4 {
            let b = bounds(q)
            lines.xs += [b.minX, (b.minX + b.maxX) / 2, b.maxX]
            lines.ys += [b.minY, (b.minY + b.maxY) / 2, b.maxY]
        }
        return lines
    }
    
    /// Moving: the shift that puts the quad's left / centre / right (and top / middle / bottom) on a snap
    /// line when one is within `threshold` canvas pixels. A nil shift = nothing to snap to on that axis.
    static func moveSnap(quad q: [CGPoint], lines: SnapLines, threshold: CGFloat)
        -> (shiftX: CGFloat?, lineX: CGFloat?, shiftY: CGFloat?, lineY: CGFloat?) {
        let b = bounds(q)
        let movingX = [b.minX, (b.minX + b.maxX) / 2, b.maxX]
        let movingY = [b.minY, (b.minY + b.maxY) / 2, b.maxY]
        func best(_ moving: [CGFloat], _ candidates: [CGFloat]) -> (shift: CGFloat, line: CGFloat)? {
            var found: (shift: CGFloat, line: CGFloat)?
            var distance = threshold + 1
            for m in moving {
                for line in candidates where abs(line - m) < distance {
                    distance = abs(line - m)
                    found = (line - m, line)
                }
            }
            return distance <= threshold ? found : nil
        }
        let x = best(movingX, lines.xs), y = best(movingY, lines.ys)
        return (x?.shift, x?.line, y?.shift, y?.line)
    }
    
    /// Scaling: the grabbed handle moves along `anchor + f * (vx, vy)`. Returns the f (near `f`) that
    /// puts it exactly on a snap line, if one is within `threshold` canvas pixels, and which line.
    static func scaleSnap(anchor: CGPoint, vx: CGFloat, vy: CGFloat, f: CGFloat, lines: SnapLines,
                          threshold: CGFloat) -> (f: CGFloat, lineX: CGFloat?, lineY: CGFloat?) {
        var best = CGFloat.greatestFiniteMagnitude
        var snapped = f
        var lineX: CGFloat?, lineY: CGFloat?
        if abs(vx) > 1e-6 {
            for line in lines.xs {
                let fl = (line - anchor.x) / vx
                let distance = abs(fl - f) * abs(vx)         // how far the handle is from the line, in canvas px
                if fl > Constants.CANVAS_MIN_SCALE_FACTOR, distance < best, distance <= threshold {
                    best = distance; snapped = fl; lineX = line; lineY = nil
                }
            }
        }
        if abs(vy) > 1e-6 {
            for line in lines.ys {
                let fl = (line - anchor.y) / vy
                let distance = abs(fl - f) * abs(vy)
                if fl > Constants.CANVAS_MIN_SCALE_FACTOR, distance < best, distance <= threshold {
                    best = distance; snapped = fl; lineY = line; lineX = nil
                }
            }
        }
        return (snapped, lineX, lineY)
    }
}
