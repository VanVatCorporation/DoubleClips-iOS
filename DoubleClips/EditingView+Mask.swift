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
    }
    
    /// One gesture on the mask: a handle drag, a move, or a pinch / twist. Live values go through
    /// `LiveOverrides` (so dragging re-renders without rebuilding the player item); the end is ONE undo step.
    final class MaskEditSession: ObservableObject {
        @Published var tick = 0
        private(set) var target: Clip?
        
        private var start = ClipMask()
        private var frame: MaskFrame?
        private var fit: CGFloat = 1
        private var handle: Int?
        private var handleStartLocal = CGPoint.zero
        private var translation = CGSize.zero
        private var scale: CGFloat = 1
        private var rotation: CGFloat = 0      // radians
        
        var isActive: Bool { target != nil }
        
        /// `canvasPoint`: where the finger first touched, in canvas pixels.
        func begin(clip: Clip, mask: ClipMask, frame: MaskFrame, canvasPoint: CGPoint, fit: CGFloat) {
            target = clip
            start = mask
            self.frame = frame
            self.fit = max(fit, 0.0001)
            translation = .zero; scale = 1; rotation = 0
            handle = nil
            let size = CGSize(width: frame.width, height: frame.height)
            let touch = frame.local(fromCanvas: canvasPoint)
            let radius = Constants.CANVAS_HANDLE_HIT_POINTS / self.fit
            var best: CGFloat = radius
            for h in MaskGeometry.handles(mask, size: size, fit: self.fit) {
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
            
            LiveOverrides.shared.set(LiveClipState(properties: clip.videoProperties, keyframes: clip.keyframes, mask: m),
                                     for: clip.id)
            tick += 1
        }
        
        func finish(commandManager: CommandManager, onChanged: @escaping () -> Void) {
            guard let clip = target else { return }
            let before = start
            let after = LiveOverrides.shared.state(for: clip.id)?.mask
            defer {
                target = nil
                handle = nil
                LiveOverrides.shared.clear(clip.id)
                tick += 1
            }
            guard let after, after != before else { return }
            commandManager.execute(GenericCommand(
                description: "Mask: \(clip.clipName)",
                undo: { clip.mask = before; onChanged() },
                redo: { clip.mask = after; onChanged() }
            ))
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
    
    // MARK: Editor section (clip properties panel)
    
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
    
    struct MaskEditor: View {
        @ObservedObject var clip: Clip
        let commandManager: CommandManager
        let onChanged: () -> Void
        @ObservedObject private var maskEdit = MaskEditState.shared
        
        @State private var sliderBefore: ClipMask?
        @State private var sliderActive = false
        
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        
        var body: some View {
            VStack(spacing: 10) {
                LazyVGrid(columns: columns, spacing: 8) {
                    noneTile
                    ForEach(ClipMask.Shape.allCases, id: \.self) { shape in tile(shape) }
                }
                
                if let mask = clip.mask {
                    PropertySlider(label: "Feather", value: value(\.feather), range: 0...0.5, resetTo: 0,
                                   onEditingBegan: beginSlider, onEditingEnded: endSlider)
                    if mask.shape == .rectangle {
                        PropertySlider(label: "Roundness", value: value(\.roundness), range: 0...1, resetTo: 0,
                                       onEditingBegan: beginSlider, onEditingEnded: endSlider)
                    }
                    Toggle("Invert", isOn: Binding(
                        get: { clip.mask?.invert ?? false },
                        set: { newValue in
                            let before = clip.mask
                            clip.mask?.invert = newValue
                            commit(before: before, after: clip.mask)
                        }
                    ))
                    .font(.system(size: 13)).foregroundColor(.white)
                    .tint(Color.mdPrimary)
                    
                    Toggle("Edit on canvas", isOn: $maskEdit.isEditing)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .tint(Color.mdPrimary)
                    
                    Text("Drag the shape to move it, its handles to resize, the arrow to rotate and the drop to soften the edge. Pinch and twist work too.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onDisappear { maskEdit.isEditing = false }
        }
        
        private var noneTile: some View {
            Button { setMask(nil) } label: {
                tileFrame(selected: clip.mask == nil, title: "None") {
                    Image(systemName: "circle.slash").font(.system(size: 18)).foregroundColor(.white.opacity(0.8))
                }
            }
            .buttonStyle(.plain)
        }
        
        private func tile(_ shape: ClipMask.Shape) -> some View {
            Button {
                let new = clip.mask?.withShape(shape) ?? ClipMask(shape: shape)
                setMask(new)
                maskEdit.isEditing = true
            } label: {
                tileFrame(selected: clip.mask?.shape == shape, title: shape.title) {
                    MaskIconShape(shape: shape)
                        .fill(Color.white.opacity(0.9))
                        .padding(8)
                        .clipped()
                }
            }
            .buttonStyle(.plain)
        }
        
        private func tileFrame<Icon: View>(selected: Bool, title: String, @ViewBuilder _ icon: () -> Icon) -> some View {
            VStack(spacing: 4) {
                icon()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
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
        
        // MARK: Editing helpers
        
        private func value(_ kp: WritableKeyPath<ClipMask, Float>) -> Binding<Float> {
            Binding(get: { clip.mask?[keyPath: kp] ?? 0 },
                    set: { clip.mask?[keyPath: kp] = $0 })
        }
        
        private func beginSlider() {
            guard !sliderActive else { return }
            sliderActive = true
            sliderBefore = clip.mask
        }
        
        private func endSlider() {
            guard sliderActive else { return }
            sliderActive = false
            commit(before: sliderBefore, after: clip.mask)
            sliderBefore = nil
        }
        
        private func setMask(_ new: ClipMask?) {
            let before = clip.mask
            guard before != new else { return }
            clip.mask = new
            if new == nil { maskEdit.isEditing = false }
            commit(before: before, after: new)
        }
        
        /// The value is already on the clip; this records the undo step and refreshes the preview.
        private func commit(before: ClipMask?, after: ClipMask?) {
            guard before != after else { return }
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Mask: \(clip.clipName)",
                undo: { target.mask = before; onChanged() },
                redo: { target.mask = after; onChanged() }
            ))
            onChanged()
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
