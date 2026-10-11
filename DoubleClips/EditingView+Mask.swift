import SwiftUI
import CoreImage
import UIKit
import Combine

// MARK: - Clip masks (iOS addition, CapCut-style)
//
// A mask limits where a clip (video / image / text) is visible. It lives in the clip's OWN box, after the
// clip's scale and before its rotation / position, so it moves, scales and rotates together with the clip
// and a circle stays a circle however the clip is stretched.
//
// Coordinates (all stored as fractions, so a mask survives a change of clip or canvas size):
//   centerX / centerY   centre of the shape as a fraction of the box width / height (0.5, 0.5 = middle)
//   width / height      size of the shape as a fraction of the box's SHORTER side (m = min(boxW, boxH))
//   rotation            degrees, clockwise
//   feather             soft edge, fraction of m (0 ... 0.5)
//   roundness           rectangle corners, 0 (square) ... 1 (pill)
//   invert              show everything outside the shape instead
// Shapes: linear = a straight edge through the centre (the side the rotation's "up" points to is kept),
//         mirror = a band through the centre (`height` = the band's thickness), circle (ellipse), rectangle,
//         heart, star.
//
// Persistence: `mask` key on the clip JSON, absent = no mask. Other platforms ignore the key (and drop it
// when they re-save the project) until they implement it.

extension EditingView {
    
    // MARK: Model
    
    struct ClipMask: Codable, Equatable {
        
        enum Shape: String, Codable, CaseIterable {
            case linear, mirror, circle, rectangle, heart, star
            
            var title: String {
                switch self {
                case .linear: return "Linear"
                case .mirror: return "Mirror"
                case .circle: return "Circle"
                case .rectangle: return "Rectangle"
                case .heart: return "Heart"
                case .star: return "Star"
                }
            }
            
            /// Linear has no extent; mirror only a thickness.
            var hasWidth: Bool { self != .linear && self != .mirror }
            var hasHeight: Bool { self != .linear }
        }
        
        var shape: Shape = .circle
        var centerX: Float = 0.5
        var centerY: Float = 0.5
        var width: Float = 0.6
        var height: Float = 0.6
        var rotation: Float = 0
        var feather: Float = 0
        var roundness: Float = 0
        var invert: Bool = false
        
        init(shape: Shape = .circle) {
            self.shape = shape
            switch shape {
            case .linear: width = 0; height = 0
            case .mirror: width = 0; height = 0.35
            case .circle: width = 0.6; height = 0.6
            case .rectangle: width = 0.8; height = 0.5
            case .heart, .star: width = 0.7; height = 0.7
            }
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shape = (try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? .circle
            centerX = try c.decodeIfPresent(Float.self, forKey: .centerX) ?? 0.5
            centerY = try c.decodeIfPresent(Float.self, forKey: .centerY) ?? 0.5
            width = try c.decodeIfPresent(Float.self, forKey: .width) ?? 0.6
            height = try c.decodeIfPresent(Float.self, forKey: .height) ?? 0.6
            rotation = try c.decodeIfPresent(Float.self, forKey: .rotation) ?? 0
            feather = try c.decodeIfPresent(Float.self, forKey: .feather) ?? 0
            roundness = try c.decodeIfPresent(Float.self, forKey: .roundness) ?? 0
            invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        }
        
        /// The same placement, another shape (keeps position, rotation, feather, invert).
        func withShape(_ newShape: Shape) -> ClipMask {
            var m = ClipMask(shape: newShape)
            m.centerX = centerX; m.centerY = centerY
            m.rotation = rotation; m.feather = feather; m.invert = invert
            return m
        }
    }
    
    // MARK: Keyframes
    
    /// One keyframe of the mask, at `time` seconds into the clip. `values` holds only the parameters this keyframe
    /// animates (MaskParam raw name -> value in the panel's units), so a keyframe on Position X leaves the rest alone.
    /// A parameter with no keyframe keeps the static value on `ClipMask`; between two keyframes the value follows the
    /// earlier one's easing, before the first / after the last it holds, exactly like the clip's own keyframes.
    struct MaskKeyframe: Codable, Equatable {
        var time: Float
        var easing: EasingType = Constants.KEYFRAME_DEFAULT_EASING
        var values: [String: Float] = [:]
    }
    
    // MARK: Geometry (shared by the renderer, the canvas overlay and the editor icons)
    
    /// The clip's box on the canvas: its top-left corner and its two edge directions, from the clip's quad.
    /// "Local" points are in box pixels (x along the top edge, y down the left edge); box pixels and canvas
    /// pixels are the same size, so no extra scale is needed.
    struct MaskFrame {
        let origin: CGPoint
        let ex: CGPoint
        let ey: CGPoint
        let width: CGFloat
        let height: CGFloat
        
        init?(quad q: [CGPoint]) {
            guard q.count == 4 else { return nil }
            let wx = q[1].x - q[0].x, wy = q[1].y - q[0].y
            let hx = q[3].x - q[0].x, hy = q[3].y - q[0].y
            let w = hypot(wx, wy), h = hypot(hx, hy)
            guard w > 1, h > 1 else { return nil }
            origin = q[0]
            ex = CGPoint(x: wx / w, y: wy / w)
            ey = CGPoint(x: hx / h, y: hy / h)
            width = w
            height = h
        }
        
        func canvas(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + ex.x * p.x + ey.x * p.y, y: origin.y + ex.y * p.x + ey.y * p.y)
        }
        func localDelta(_ d: CGPoint) -> CGPoint {
            CGPoint(x: d.x * ex.x + d.y * ex.y, y: d.x * ey.x + d.y * ey.y)
        }
        func local(fromCanvas p: CGPoint) -> CGPoint {
            localDelta(CGPoint(x: p.x - origin.x, y: p.y - origin.y))
        }
        /// Local box pixels -> canvas pixels as one transform.
        var toCanvas: CGAffineTransform {
            CGAffineTransform(a: ex.x, b: ex.y, c: ey.x, d: ey.y, tx: origin.x, ty: origin.y)
        }
    }
    
    struct MaskHandle: Identifiable {
        /// 0-3 corners (TL, TR, BR, BL), 4 top, 5 right, 6 bottom, 7 left, 8 rotate, 9 feather.
        let id: Int
        let local: CGPoint
        
        static let rotate = 8, feather = 9
    }
    
    enum MaskGeometry {
        
        /// Centre and half extents in box pixels.
        static func metrics(_ mask: ClipMask, size: CGSize) -> (center: CGPoint, hw: CGFloat, hh: CGFloat, m: CGFloat) {
            let m = min(size.width, size.height)
            let center = CGPoint(x: CGFloat(mask.centerX) * size.width, y: CGFloat(mask.centerY) * size.height)
            let hw = max(CGFloat(mask.width) * m / 2, 0.5)
            let hh = max(CGFloat(mask.height) * m / 2, 0.5)
            return (center, hw, hh, m)
        }
        
        private static func placement(_ mask: ClipMask, center: CGPoint) -> CGAffineTransform {
            // Rotation first (about the origin), then the move to the centre: y is down, so + is clockwise.
            CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(mask.rotation) * .pi / 180)
        }
        
        /// The visible area (before invert / feather), in box pixels.
        static func fillPath(_ mask: ClipMask, size: CGSize) -> CGPath {
            let (center, hw, hh, _) = metrics(mask, size: size)
            let big = hypot(size.width, size.height) * 2
            let local = CGMutablePath()
            switch mask.shape {
            case .linear:
                local.addRect(CGRect(x: -big, y: -big, width: big * 2, height: big))
            case .mirror:
                local.addRect(CGRect(x: -big, y: -hh, width: big * 2, height: hh * 2))
            case .circle:
                local.addEllipse(in: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2))
            case .rectangle:
                let r = min(CGFloat(max(mask.roundness, 0)) * min(hw, hh), min(hw, hh))
                local.addRoundedRect(in: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2),
                                     cornerWidth: r, cornerHeight: r)
            case .heart:
                let steps = 96
                for i in 0...steps {
                    let t = Double(i) / Double(steps) * 2 * Double.pi
                    let x = 16 * pow(sin(t), 3)
                    let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                    let p = CGPoint(x: CGFloat(x / 16) * hw, y: -CGFloat((y + 2.6) / 14.4) * hh)
                    if i == 0 { local.move(to: p) } else { local.addLine(to: p) }
                }
                local.closeSubpath()
            case .star:
                for k in 0..<10 {
                    let angle = -Double.pi / 2 + Double(k) * Double.pi / 5
                    let r: Double = k % 2 == 0 ? 1 : 0.42
                    let p = CGPoint(x: CGFloat(cos(angle) * r) * hw, y: CGFloat(sin(angle) * r) * hh)
                    if k == 0 { local.move(to: p) } else { local.addLine(to: p) }
                }
                local.closeSubpath()
            }
            var t = placement(mask, center: center)
            return local.copy(using: &t) ?? local
        }
        
        /// What the canvas overlay draws: the outline of a closed shape, the line(s) of linear / mirror.
        static func guidePath(_ mask: ClipMask, size: CGSize) -> CGPath {
            switch mask.shape {
            case .linear, .mirror:
                let (center, _, hh, _) = metrics(mask, size: size)
                let big = hypot(size.width, size.height) * 2
                let local = CGMutablePath()
                if mask.shape == .linear {
                    local.move(to: CGPoint(x: -big, y: 0)); local.addLine(to: CGPoint(x: big, y: 0))
                } else {
                    local.move(to: CGPoint(x: -big, y: -hh)); local.addLine(to: CGPoint(x: big, y: -hh))
                    local.move(to: CGPoint(x: -big, y: hh)); local.addLine(to: CGPoint(x: big, y: hh))
                }
                var t = placement(mask, center: center)
                return local.copy(using: &t) ?? local
            default:
                return fillPath(mask, size: size)
            }
        }
        
        /// Handles of the shape in box pixels. `fit` = canvas-to-screen scale, so the rotate / feather knobs
        /// sit a fixed distance on screen from the edge.
        static func handles(_ mask: ClipMask, size: CGSize, fit: CGFloat) -> [MaskHandle] {
            let (c, hw, hh, _) = metrics(mask, size: size)
            let a = CGFloat(mask.rotation) * .pi / 180
            let ax = CGPoint(x: cos(a), y: sin(a)), ay = CGPoint(x: -sin(a), y: cos(a))
            func pt(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
                CGPoint(x: c.x + ax.x * sx + ay.x * sy, y: c.y + ax.y * sx + ay.y * sy)
            }
            let extentY: CGFloat = mask.shape.hasHeight ? hh : 0
            let off = 30 / max(fit, 0.0001)
            var list: [MaskHandle] = []
            if mask.shape.hasWidth {
                list += [MaskHandle(id: 0, local: pt(-hw, -hh)), MaskHandle(id: 1, local: pt(hw, -hh)),
                         MaskHandle(id: 2, local: pt(hw, hh)), MaskHandle(id: 3, local: pt(-hw, hh)),
                         MaskHandle(id: 5, local: pt(hw, 0)), MaskHandle(id: 7, local: pt(-hw, 0))]
            }
            if mask.shape.hasHeight {
                list += [MaskHandle(id: 4, local: pt(0, -hh)), MaskHandle(id: 6, local: pt(0, hh))]
            }
            list += [MaskHandle(id: MaskHandle.rotate, local: pt(0, -(extentY + off))),
                     MaskHandle(id: MaskHandle.feather, local: pt(0, extentY + off))]
            return list
        }
    }
    
    // MARK: Canvas editing state
    
    /// Whether the preview is showing the mask's handles instead of the clip's own selection box.
    /// A shared object, like `LiveOverrides`, so the clip editor panel and the preview overlay see the same flag.
    final class MaskEditState: ObservableObject {
        static let shared = MaskEditState()
        @Published var isEditing = false
        /// Bumped on every live change (canvas drag, ruler, typed value) so the panel's numbers follow.
        @Published var tick = 0
        /// Re-renders the paused preview; set by the editor when the panel opens.
        var refresh: (() -> Void)?
    }
    
    /// One gesture on the mask: a handle drag, a move, or a pinch / twist. Live values go through
    /// `LiveOverrides` (so dragging re-renders without rebuilding the player item); the end is ONE undo step.
    /// A parameter the mask animates gets a keyframe at the playhead (or the one there changes); one it doesn't
    /// is just its static value, so a move never adds a keyframe for the size.
    final class MaskEditSession: ObservableObject {
        @Published var tick = 0
        private(set) var target: Clip?
        
        private var startStatic = ClipMask()
        private var startKeys: [MaskKeyframe] = []
        /// What is on screen at the playhead when the gesture starts (static values + animated ones).
        private var start = ClipMask()
        private var localTime: Float = 0
        private var frameRate = 30
        private var frame: MaskFrame?
        private var fit: CGFloat = 1
        private var handle: Int?
        private var handleStartLocal = CGPoint.zero
        private var translation = CGSize.zero
        private var scale: CGFloat = 1
        private var rotation: CGFloat = 0      // radians
        
        var isActive: Bool { target != nil }
        
        /// `canvasPoint`: where the finger first touched, in canvas pixels.
        func begin(clip: Clip, playhead: Float, frameRate: Int, frame: MaskFrame, canvasPoint: CGPoint, fit: CGFloat) {
            guard let staticMask = clip.mask else { return }
            target = clip
            startStatic = staticMask
            startKeys = clip.maskKeys
            localTime = max(0, min(playhead - clip.startTime, clip.duration))
            self.frameRate = frameRate
            start = startKeys.applied(to: staticMask, atLocal: localTime)
            self.frame = frame
            self.fit = max(fit, 0.0001)
            translation = .zero; scale = 1; rotation = 0
            handle = nil
            let size = CGSize(width: frame.width, height: frame.height)
            let touch = frame.local(fromCanvas: canvasPoint)
            let radius = Constants.CANVAS_HANDLE_HIT_POINTS / self.fit
            var best: CGFloat = radius
            for h in MaskGeometry.handles(start, size: size, fit: self.fit) {
                let d = hypot(h.local.x - touch.x, h.local.y - touch.y)
                if d <= best { best = d; handle = h.id; handleStartLocal = h.local }
            }
        }
        
        func pan(_ t: CGSize) { translation = t; recompute() }
        func pinch(_ s: CGFloat) { guard handle == nil else { return }; scale = s; recompute() }
        func rotate(_ r: CGFloat) { guard handle == nil else { return }; rotation = r; recompute() }
        
        private func recompute() {
            guard let clip = target, let frame else { return }
            var m = start
            let size = CGSize(width: frame.width, height: frame.height)
            let (center, startHW, startHH, box) = MaskGeometry.metrics(start, size: size)
            let delta = frame.localDelta(CGPoint(x: translation.width / fit, y: translation.height / fit))
            let a = CGFloat(start.rotation) * .pi / 180
            let ax = CGPoint(x: cos(a), y: sin(a)), ay = CGPoint(x: -sin(a), y: cos(a))
            let minSize: Float = 0.02
            
            if let h = handle {
                let p = CGPoint(x: handleStartLocal.x + delta.x, y: handleStartLocal.y + delta.y)
                let d = CGPoint(x: p.x - center.x, y: p.y - center.y)
                let lx = d.x * ax.x + d.y * ax.y
                let ly = d.x * ay.x + d.y * ay.y
                switch h {
                case MaskHandle.rotate:
                    var deg = Float(atan2(d.y, d.x) * 180 / .pi) + 90
                    if deg > 180 { deg -= 360 }
                    let nearest = (deg / 90).rounded() * 90
                    if abs(deg - nearest) <= 3 { deg = nearest }
                    m.rotation = deg
                case MaskHandle.feather:
                    let along = delta.x * ay.x + delta.y * ay.y
                    m.feather = min(max(start.feather + Float(along / max(box, 1)), 0), 0.5)
                case 4, 6:
                    m.height = max(minSize, Float(2 * abs(ly) / max(box, 1)))
                case 5, 7:
                    m.width = max(minSize, Float(2 * abs(lx) / max(box, 1)))
                default:    // corners scale both sizes together
                    let f = Float(hypot(lx, ly) / max(hypot(startHW, startHH), 1))
                    m.width = max(minSize, start.width * f)
                    m.height = max(minSize, start.height * f)
                }
            } else {
                m.centerX = start.centerX + Float(delta.x / frame.width)
                m.centerY = start.centerY + Float(delta.y / frame.height)
                if scale != 1 {
                    if start.shape.hasWidth { m.width = max(minSize, start.width * Float(scale)) }
                    if start.shape.hasHeight { m.height = max(minSize, start.height * Float(scale)) }
                }
                if rotation != 0 {
                    var deg = start.rotation + Float(rotation * 180 / .pi)
                    deg = (deg + 540).truncatingRemainder(dividingBy: 360) - 180
                    let nearest = (deg / 90).rounded() * 90
                    if abs(deg - nearest) <= 3 { deg = nearest }
                    m.rotation = deg
                }
            }
            
            // Per parameter: animated ones get a keyframe at the playhead, the others change their static value.
            var staticMask = startStatic
            var keys = startKeys
            for param in MaskParam.allCases {
                let newValue = param.get(m)
                guard newValue != param.get(start) else { continue }
                if keys.isAnimated(param) {
                    keys.setKey(param, atLocal: localTime, value: newValue, frameRate: frameRate)
                } else {
                    param.set(&staticMask, newValue)
                }
            }
            
            LiveOverrides.shared.set(LiveClipState(properties: clip.videoProperties, keyframes: clip.keyframes,
                                                   mask: staticMask, maskKeys: keys), for: clip.id)
            tick += 1
            MaskEditState.shared.tick += 1
        }
        
        func finish(commandManager: CommandManager, onChanged: @escaping () -> Void) {
            guard let clip = target else { return }
            let beforeMask = startStatic, beforeKeys = startKeys
            let live = LiveOverrides.shared.state(for: clip.id)
            defer {
                target = nil
                handle = nil
                LiveOverrides.shared.clear(clip.id)
                tick += 1
            }
            guard let afterMask = live?.mask, let afterKeys = live?.maskKeys,
                  afterMask != beforeMask || afterKeys != beforeKeys else { return }
            commandManager.execute(GenericCommand(
                description: "Mask: \(clip.clipName)",
                undo: { clip.mask = beforeMask; clip.maskKeys = beforeKeys; onChanged() },
                redo: { clip.mask = afterMask; clip.maskKeys = afterKeys; onChanged() }
            ))
            MaskEditState.shared.tick += 1
        }
    }
    
    // MARK: Canvas overlay
    
    /// The mask's outline and handles over the preview. Draws only; touches go through the gesture surface.
    struct MaskOverlay: View {
        let mask: ClipMask
        let frame: MaskFrame
        let fit: CGFloat
        let origin: CGPoint
        
        var body: some View {
            let size = CGSize(width: frame.width, height: frame.height)
            let toScreen = frame.toCanvas
                .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            let outline = Path(MaskGeometry.guidePath(mask, size: size)).applying(toScreen)
            let handles = MaskGeometry.handles(mask, size: size, fit: fit)
            
            ZStack {
                outline.stroke(Color.black.opacity(0.45), lineWidth: 3.5)
                outline.stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.6, dash: mask.feather > 0.001 ? [7, 4] : []))
                
                ForEach(handles) { h in
                    knob(h.id)
                        .position(Self.point(h.local, toScreen))
                }
            }
        }
        
        private static func point(_ p: CGPoint, _ t: CGAffineTransform) -> CGPoint { p.applying(t) }
        
        @ViewBuilder
        private func knob(_ id: Int) -> some View {
            switch id {
            case MaskHandle.rotate:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.mdPrimary))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            case MaskHandle.feather:
                Image(systemName: "drop.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.mdSecondary))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            default:
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.8))
            }
        }
    }
    
    // MARK: Mask panel (toolbar "Mask")
    
    /// Icon of a shape for the tiles.
    struct MaskIconShape: Shape {
        let shape: ClipMask.Shape
        
        func path(in rect: CGRect) -> Path {
            var m = ClipMask(shape: shape)
            switch shape {
            case .linear: m.rotation = 25
            case .mirror: m.rotation = 25; m.height = 0.4
            case .rectangle: m.width = 0.75; m.height = 0.55
            default: m.width = 0.7; m.height = 0.7
            }
            return Path(MaskGeometry.fillPath(m, size: rect.size)).offsetBy(dx: rect.minX, dy: rect.minY)
        }
    }
    
    /// A number the panel edits, in the units the user sees. The same values change when the shape is dragged on
    /// the canvas, so the numbers always show what the gesture does.
    enum MaskParam: String, CaseIterable {
        case x, y, width, height, rotation, feather, roundness
        
        func title(for shape: ClipMask.Shape) -> String {
            switch self {
            case .x: return "Position X"
            case .y: return "Position Y"
            case .width: return "Width"
            case .height: return shape == .mirror ? "Thickness" : "Height"
            case .rotation: return "Rotation"
            case .feather: return "Feather"
            case .roundness: return "Corner"
            }
        }
        
        /// Percent of the clip's box (position) / of its shorter side (size), degrees, 0...100 (feather, corner).
        var range: ClosedRange<Float> {
            switch self {
            case .x, .y: return -50...150
            case .width, .height: return 1...200
            case .rotation: return -180...180
            case .feather, .roundness: return 0...100
            }
        }
        
        /// How much one tick of the ruler is worth.
        var unitsPerTick: Float {
            switch self {
            case .x, .y: return 1
            case .width, .height: return 1
            case .rotation: return 1
            case .feather, .roundness: return 1
            }
        }
        
        func get(_ m: ClipMask) -> Float {
            switch self {
            case .x: return m.centerX * 100
            case .y: return m.centerY * 100
            case .width: return m.width * 100
            case .height: return m.height * 100
            case .rotation: return m.rotation
            case .feather: return m.feather * 200
            case .roundness: return m.roundness * 100
            }
        }
        
        func set(_ m: inout ClipMask, _ value: Float) {
            let v = min(max(value, range.lowerBound), range.upperBound)
            switch self {
            case .x: m.centerX = v / 100
            case .y: m.centerY = v / 100
            case .width: m.width = v / 100
            case .height: m.height = v / 100
            case .rotation: m.rotation = v
            case .feather: m.feather = v / 200
            case .roundness: m.roundness = v / 100
            }
        }
    }
    
    // MARK: Ruler slider (CapCut style)
    
    /// A ruler of ticks that slides under a fixed cursor: drag it sideways and the value under the cursor changes,
    /// with a light tick of feedback for every step. Dragging right lowers the value, like CapCut (the ruler follows the finger).
    struct RulerSlider: View {
        @Binding var value: Float
        let range: ClosedRange<Float>
        var unitsPerTick: Float = 1
        var onEditingBegan: () -> Void = {}
        var onEditingEnded: () -> Void = {}
        
        @State private var dragStart: Float?
        @State private var lastTick = 0
        private let tickSpacing: CGFloat = 10
        private static let feedback = UISelectionFeedbackGenerator()
        
        var body: some View {
            Canvas { context, size in
                let mid = size.width / 2
                let center = value / unitsPerTick
                let span = Int(ceil(mid / tickSpacing)) + 2
                let base = Int(center.rounded())
                for i in (base - span)...(base + span) {
                    let x = mid + CGFloat(Float(i) - center) * tickSpacing
                    guard x >= 0, x <= size.width else { continue }
                    let major = i % 5 == 0
                    let h: CGFloat = major ? 18 : 11
                    let edge = min(abs(x - mid) / max(mid, 1), 1)
                    let fade = 1 - pow(edge, 2.5)
                    let tickValue = Float(i) * unitsPerTick
                    let inside = tickValue >= range.lowerBound - 0.001 && tickValue <= range.upperBound + 0.001
                    let opacity = (inside ? (major ? 0.85 : 0.4) : 0.1) * fade
                    context.fill(Path(CGRect(x: x - 0.75, y: (size.height - h) / 2, width: 1.5, height: h)),
                                 with: .color(.white.opacity(opacity)))
                }
                context.fill(Path(roundedRect: CGRect(x: mid - 1.25, y: (size.height - 28) / 2, width: 2.5, height: 28),
                                  cornerRadius: 1.2),
                             with: .color(Color.mdSecondary))
            }
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        if dragStart == nil {
                            dragStart = value
                            lastTick = Int((value / unitsPerTick).rounded())
                            Self.feedback.prepare()
                            onEditingBegan()
                        }
                        let raw = (dragStart ?? value) - Float(g.translation.width) * unitsPerTick / Float(tickSpacing)
                        let clamped = min(max(raw, range.lowerBound), range.upperBound)
                        value = (clamped * 10).rounded() / 10
                        let tick = Int((value / unitsPerTick).rounded())
                        if tick != lastTick { lastTick = tick; Self.feedback.selectionChanged() }
                    }
                    .onEnded { _ in
                        if dragStart != nil { dragStart = nil; onEditingEnded() }
                    }
            )
        }
    }
    
    // MARK: Panel
    
    struct MaskPanel: View {
        @ObservedObject var clip: Clip
        let commandManager: CommandManager
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        @ObservedObject private var state = MaskEditState.shared
        
        enum Tab: String { case position = "Position", size = "Size", rotate = "Rotate", feather = "Feather", corner = "Corner" }
        
        /// The static mask and its keyframes together: what one undo step swaps.
        private struct Snapshot: Equatable {
            var mask: ClipMask?
            var keys: [MaskKeyframe]
        }
        
        @State private var tab: Tab = .position
        @State private var before: Snapshot?
        @State private var dragging = false
        
        private var snapshot: Snapshot { Snapshot(mask: clip.mask, keys: clip.maskKeys) }
        
        /// Seconds into the clip the playhead is at, kept inside the clip.
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        
        /// The mask as it is right now at the playhead: its animated values, and the live ones while a canvas drag /
        /// ruler drag runs.
        private var current: ClipMask? {
            _ = state.tick
            return clip.resolvedMask(at: clip.startTime + localTime, live: LiveOverrides.shared.state(for: clip.id))
        }
        
        private var currentKeys: [MaskKeyframe] {
            _ = state.tick
            return LiveOverrides.shared.state(for: clip.id)?.maskKeys ?? clip.maskKeys
        }
        
        var body: some View {
            let mask = current
            VStack(spacing: 12) {
                shapeRow(mask)
                if let mask {
                    tabBar(mask)
                    ForEach(rows(mask), id: \.self) { param in row(param, mask) }
                    HStack {
                        Button {
                            setSnapshot(mask: ClipMask(shape: mask.shape), keys: [])
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 13)).foregroundColor(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Toggle("Invert", isOn: Binding(
                            get: { clip.mask?.invert ?? false },
                            set: { newValue in
                                guard var m = clip.mask else { return }
                                m.invert = newValue
                                setSnapshot(mask: m, keys: clip.maskKeys)
                            }
                        ))
                        .toggleStyle(.switch)
                        .tint(Color.mdPrimary)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .fixedSize()
                    }
                } else {
                    Text("Pick a shape to show only part of the clip. Drag it on the preview, or type the numbers. The diamond beside a value animates it.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear { state.isEditing = true }
            .onDisappear { state.isEditing = false }
        }
        
        // MARK: Shapes
        
        private func shapeRow(_ mask: ClipMask?) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { setSnapshot(mask: nil, keys: []) } label: {
                        tile(title: "None", selected: mask == nil) {
                            Image(systemName: "circle.slash").font(.system(size: 18)).foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(ClipMask.Shape.allCases, id: \.self) { shape in
                        Button {
                            setSnapshot(mask: clip.mask?.withShape(shape) ?? ClipMask(shape: shape), keys: clip.maskKeys)
                        } label: {
                            tile(title: shape.title, selected: mask?.shape == shape) {
                                MaskIconShape(shape: shape).fill(Color.white.opacity(0.9)).padding(9).clipped()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        
        private func tile<Icon: View>(title: String, selected: Bool, @ViewBuilder _ icon: () -> Icon) -> some View {
            VStack(spacing: 4) {
                icon()
                    .frame(width: 52, height: 52)
                    .background(selected ? Color.mdPrimary.opacity(0.22) : Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : .white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        
        // MARK: Tabs + rows
        
        private func tabs(_ mask: ClipMask) -> [Tab] {
            var list: [Tab] = [.position]
            if mask.shape.hasHeight { list.append(.size) }
            list.append(.rotate)
            list.append(.feather)
            if mask.shape == .rectangle { list.append(.corner) }
            return list
        }
        
        private func activeTab(_ mask: ClipMask) -> Tab {
            tabs(mask).contains(tab) ? tab : .position
        }
        
        private func tabBar(_ mask: ClipMask) -> some View {
            let active = activeTab(mask)
            return HStack(spacing: 22) {
                ForEach(tabs(mask), id: \.rawValue) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 5) {
                            Text(t.rawValue)
                                .font(.system(size: 14, weight: t == active ? .semibold : .regular))
                                .foregroundColor(t == active ? .white : .white.opacity(0.5))
                            Rectangle()
                                .fill(t == active ? Color.mdSecondary : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        
        private func rows(_ mask: ClipMask) -> [MaskParam] {
            switch activeTab(mask) {
            case .position: return [.x, .y]
            case .size: return mask.shape.hasWidth ? [.width, .height] : [.height]
            case .rotate: return [.rotation]
            case .feather: return [.feather]
            case .corner: return [.roundness]
            }
        }
        
        private func row(_ param: MaskParam, _ mask: ClipMask) -> some View {
            HStack(spacing: 6) {
                Text(param.title(for: mask.shape))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    .frame(width: 64, alignment: .leading)
                RulerSlider(
                    value: Binding(get: { param.get(mask) }, set: { setLive(param, $0) }),
                    range: param.range, unitsPerTick: param.unitsPerTick,
                    onEditingBegan: beginDrag, onEditingEnded: endDrag)
                NumberField(label: "", value: Binding(
                    get: { param.get(mask) },
                    set: { newValue in beginDrag(); setLive(param, newValue); endDrag() }
                )) {}
                .frame(width: 60)
                KeyDiamond(mode: keyMode(param), enabled: playheadInsideClip) { toggleKey(param) }
            }
        }
        
        // MARK: Keyframes
        
        private func keyMode(_ param: MaskParam) -> KeyDiamond.Mode {
            let keys = currentKeys
            guard keys.isAnimated(param) else { return .off }
            return keys.keyIndex(atLocal: localTime, animating: param) != nil ? .onKey : .animated
        }
        
        /// The diamond: animates the value from the playhead (a keyframe with its current value), or takes the keyframe
        /// there away (the last one leaves the value where it was).
        private func toggleKey(_ param: MaskParam) {
            guard playheadInsideClip, var m = clip.mask else { return }
            var keys = clip.maskKeys
            if keys.keyIndex(atLocal: localTime, animating: param) != nil {
                if let removed = keys.removeKey(param, atLocal: localTime), !keys.isAnimated(param) {
                    param.set(&m, removed)
                }
            } else {
                let value = current.map { param.get($0) } ?? param.get(m)
                keys.setKey(param, atLocal: localTime, value: value, frameRate: frameRate)
            }
            setSnapshot(mask: m, keys: keys)
        }
        
        // MARK: Editing
        
        /// A ruler drag or a typed value: the preview follows live (through LiveOverrides, no player rebuild),
        /// and the whole edit becomes ONE undo step when it ends. A value the mask animates gets a keyframe at the
        /// playhead (or the one there changes); any other is its static value.
        private func beginDrag() {
            guard !dragging else { return }
            dragging = true
            before = snapshot
        }
        
        private func setLive(_ param: MaskParam, _ value: Float) {
            guard let staticMask = clip.mask else { return }
            let live = LiveOverrides.shared.state(for: clip.id)
            var m = live?.mask ?? staticMask
            var keys = live?.maskKeys ?? clip.maskKeys
            if keys.isAnimated(param) {
                keys.setKey(param, atLocal: localTime, value: value, frameRate: frameRate)
            } else {
                param.set(&m, value)
            }
            LiveOverrides.shared.set(LiveClipState(properties: clip.videoProperties, keyframes: clip.keyframes,
                                                   mask: m, maskKeys: keys), for: clip.id)
            state.tick += 1
            state.refresh?()
        }
        
        private func endDrag() {
            guard dragging else { return }
            dragging = false
            let live = LiveOverrides.shared.state(for: clip.id)
            LiveOverrides.shared.clear(clip.id)
            let start = before
            before = nil
            state.tick += 1
            guard let start, let m = live?.mask, let keys = live?.maskKeys else { return }
            let after = Snapshot(mask: m, keys: keys)
            guard after != start else { return }
            commit(before: start, after: after)
        }
        
        private func setSnapshot(mask: ClipMask?, keys: [MaskKeyframe]) {
            let old = snapshot
            let new = Snapshot(mask: mask, keys: mask == nil ? [] : keys)
            guard old != new else { return }
            commit(before: old, after: new)
        }
        
        private func commit(before old: Snapshot, after new: Snapshot) {
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Mask: \(clip.clipName)",
                undo: { target.mask = old.mask; target.maskKeys = old.keys; onChanged() },
                redo: { target.mask = new.mask; target.maskKeys = new.keys; onChanged() }
            ))
            state.tick += 1
        }
    }
}

// MARK: - Rendering (Core Image)

extension EditingView.ClipCompositor {
    
    private static let clipMaskCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 12
        return cache
    }()
    
    /// `image` limited to the mask. `image` is the clip already scaled to `size` (extent origin 0,0), still
    /// unrotated, so the mask follows the clip's later rotation and move for free.
    static func applyClipMask(_ mask: EditingView.ClipMask, to image: CIImage, size: CGSize) -> CIImage {
        guard let picture = clipMaskImage(mask, size: size) else { return image }
        let box = CGRect(origin: .zero, size: size)
        let clear = CIImage(color: .clear).cropped(to: box)
        return masked(image, over: clear, mask: picture).cropped(to: box)
    }
    
    /// The mask of an effect clip at `time` (its box is the whole canvas), with a gesture's live state and keyframes applied.
    static func effectMask(_ layer: EditingView.RenderLayer, time: Float) -> EditingView.ClipMask? {
        let live = EditingView.LiveOverrides.shared.state(for: layer.clipID)
        guard let base = live?.mask ?? layer.mask else { return nil }
        return (live?.maskKeys ?? layer.maskKeys).applied(to: base, atLocal: time - layer.startTime)
    }
    
    /// White where the clip shows, black where it doesn't; `size` pixels, origin (0, 0). Cached while it doesn't change.
    static func clipMaskImage(_ mask: EditingView.ClipMask, size: CGSize) -> CIImage? {
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return nil }
        let key = String(format: "%@|%.0fx%.0f|%.4f|%.4f|%.4f|%.4f|%.2f|%.4f|%.3f|%d",
                         mask.shape.rawValue, size.width, size.height, mask.centerX, mask.centerY, mask.width,
                         mask.height, mask.rotation, mask.feather, mask.roundness, mask.invert ? 1 : 0) as NSString
        if let hit = clipMaskCache.object(forKey: key) { return hit }
        
        // Drawn at most 2048 px on the long side, then scaled up: big clips don't pay for a full-size bitmap.
        let s = min(1, 2048 / max(size.width, size.height))
        let w = max(1, Int(ceil(size.width * s))), h = max(1, Int(ceil(size.height * s)))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(gray: mask.invert ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Draw in box pixels with y down.
        let sx = CGFloat(w) / size.width, sy = CGFloat(h) / size.height
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: sx, y: -sy)
        context.addPath(EditingView.MaskGeometry.fillPath(mask, size: size))
        context.setFillColor(gray: mask.invert ? 0 : 1, alpha: 1)
        context.fillPath()
        guard let bitmap = context.makeImage() else { return nil }
        
        var picture = CIImage(cgImage: bitmap)
        let sigma = CGFloat(mask.feather) * min(size.width, size.height) * sx * 0.5
        if sigma > 0.3 {
            picture = picture.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        picture = picture.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
        clipMaskCache.setObject(picture, forKey: key)
        return picture
    }
}

// MARK: - Mask keyframe maths

extension Array where Element == EditingView.MaskKeyframe {
    
    func isAnimated(_ param: EditingView.MaskParam) -> Bool {
        contains { $0.values[param.rawValue] != nil }
    }
    
    /// The animated value of `param` at `local` seconds into the clip; nil when it has no keyframe.
    func value(_ param: EditingView.MaskParam, atLocal local: Float) -> Float? {
        let k = param.rawValue
        var prev: EditingView.MaskKeyframe?
        for next in self {
            guard let nextValue = next.values[k] else { continue }
            guard let before = prev, let a = before.values[k] else {
                if local < next.time { return nextValue }       // before the first keyframe: holds its value
                prev = next
                continue
            }
            if local < next.time {
                let span = next.time - before.time
                let raw: Float = span > 0 ? (local - before.time) / span : 0
                let t = Swift.max(0, Swift.min(1, raw))
                return a + (nextValue - a) * before.easing.apply(t)
            }
            prev = next
        }
        return prev?.values[k]
    }
    
    /// `mask` with every animated parameter replaced by its value at `local` seconds into the clip.
    func applied(to mask: EditingView.ClipMask, atLocal local: Float) -> EditingView.ClipMask {
        guard !isEmpty else { return mask }
        var m = mask
        for param in EditingView.MaskParam.allCases {
            if let v = value(param, atLocal: local) { param.set(&m, v) }
        }
        return m
    }
    
    /// Index of the keyframe that holds `param` at `local` (within the keyframe spacing), if any.
    func keyIndex(atLocal local: Float, animating param: EditingView.MaskParam) -> Int? {
        indices.first { abs(self[$0].time - local) <= EditingView.minimumKeyframeSpacing
            && self[$0].values[param.rawValue] != nil }
    }
    
    /// Gives `param` the value at `local`: changes its keyframe there, or adds the value to another keyframe at the
    /// same time, or creates a keyframe (snapped to the project's frame grid).
    mutating func setKey(_ param: EditingView.MaskParam, atLocal local: Float, value: Float, frameRate: Int) {
        let k = param.rawValue
        if let i = keyIndex(atLocal: local, animating: param) { self[i].values[k] = value; return }
        var t = local
        if frameRate > 0 {
            let fps = Float(frameRate)
            t = (local * fps).rounded() / fps
        }
        if let i = firstIndex(where: { abs($0.time - t) <= EditingView.minimumKeyframeSpacing }) {
            self[i].values[k] = value
            return
        }
        append(EditingView.MaskKeyframe(time: t, values: [k: value]))
        sort { $0.time < $1.time }
    }
    
    /// Takes `param`'s keyframe at `local` away (the keyframe goes too when it held nothing else).
    /// Returns the value it held, so the parameter can stay there as a static value.
    @discardableResult
    mutating func removeKey(_ param: EditingView.MaskParam, atLocal local: Float) -> Float? {
        guard let i = keyIndex(atLocal: local, animating: param) else { return nil }
        let v = self[i].values[param.rawValue]
        self[i].values[param.rawValue] = nil
        if self[i].values.isEmpty { remove(at: i) }
        return v
    }
}

extension EditingView.Clip {
    /// The mask as drawn at `playhead` (global seconds): its static values, the animated ones taken from the keyframes.
    /// A gesture's live state wins over the clip's own.
    func resolvedMask(at playhead: Float, live: EditingView.LiveClipState? = nil) -> EditingView.ClipMask? {
        guard let base = live?.mask ?? mask else { return nil }
        return (live?.maskKeys ?? maskKeys).applied(to: base, atLocal: playhead - startTime)
    }
}
