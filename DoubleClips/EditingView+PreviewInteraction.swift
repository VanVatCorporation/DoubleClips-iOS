import SwiftUI
import UIKit
import Combine

// MARK: - On-canvas editing (Android: ClipRenderer.attachGestureControls)
//
//   tap        → select the clip under the finger
//   1-finger   → move  (PosX / PosY, canvas pixels)
//   pinch      → uniform scale (ScaleX & ScaleY multiplied by the same factor)
//   2-finger twist → rotate (degrees, snaps to 90° within 3°)
//   drag a handle of the selected clip → resize (desktop PreviewGizmo): a corner scales both axes
//              about the opposite corner, an edge handle stretches one axis in the clip's own
//              (rotated) frame about the opposite edge
//   moving / resizing snaps to the canvas edges + centre and to other visible clips, with pink
//              guide lines (Project Settings → Canvas Editing turns it off)
//
// Differences from Android, on purpose:
//   - Deltas are converted from screen points to canvas pixels (Android's own TODO: its moves
//     jitter when the canvas is scaled down to fit the screen).
//   - Every gesture is ONE undoable command (Android has no undo for these).
//   - If the clip has keyframes, the gesture edits the keyframe at the playhead, inserting one
//     first when there is none. Otherwise the change would be overwritten by interpolation.

extension EditingView {
    
    // MARK: Session (state of one gesture)
    
    final class PreviewEditSession: ObservableObject {
        @Published var tick = 0
        @Published var infoText: String?
        /// Canvas x / y of the snap line a move or resize is currently locked to (drawn as a guide).
        @Published var guideX: CGFloat?
        @Published var guideY: CGFloat?
        private(set) var target: Clip?
        
        // Handle resizing + snapping (EditingView+PreviewHandles.swift)
        private var handle: Int?
        private var startQuad: [CGPoint] = []
        private var canvas: CGSize = .zero
        private var stretchToFull = false
        private var snapLines = CanvasGizmo.SnapLines()
        private var snappingOn = true
        private let feedback = UISelectionFeedbackGenerator()
        
        private var startProps = VideoProperties()
        private var startKeys = AnimatedProperty()
        private var basis = VideoProperties()
        private var workingKeys = AnimatedProperty()
        private var keyIndex: Int?
        
        private var translation: CGSize = .zero
        private var scale: CGFloat = 1
        private var rotation: CGFloat = 0 // radians, clockwise
        private var fit: CGFloat = 1
        
        var isActive: Bool { target != nil }
        
        /// `handle`: the resize handle the gesture grabbed (nil = a move / pinch / twist). `otherQuads` are
        /// the other visible clips' boxes at the playhead, which the gesture can snap to.
        func begin(clip: Clip, playhead: Float, fit: CGFloat, frameRate: Int,
                   canvas: CGSize, stretchToFull: Bool, otherQuads: [[CGPoint]], handle: Int? = nil) {
            target = clip
            self.fit = max(fit, 0.0001)
            self.canvas = canvas
            self.stretchToFull = stretchToFull
            self.handle = handle
            translation = .zero; scale = 1; rotation = 0
            startProps = clip.videoProperties
            startKeys = clip.keyframes
            workingKeys = clip.keyframes
            keyIndex = nil
            basis = clip.videoProperties
            snapLines = CanvasGizmo.snapLines(canvas: canvas, others: otherQuads)
            snappingOn = UserDefaults.standard.object(forKey: Constants.PREF_CANVAS_SNAPPING_KEY) as? Bool ?? true
            guideX = nil; guideY = nil
            feedback.prepare()
            // Whatever way `basis` ends up (static values or the keyframe at the playhead), the box the
            // gesture started from:
            defer {
                startQuad = clip.quad(for: basis, canvas: canvas, stretchToFull: stretchToFull) ?? []
                if startQuad.count != 4 { self.handle = nil }
            }
            
            guard !clip.keyframes.keyframes.isEmpty else { return }
            let local = playhead - clip.startTime
            if let idx = workingKeys.keyframes.firstIndex(where: { abs($0.time - local) <= EditingView.minimumKeyframeSpacing }) {
                keyIndex = idx
                basis = workingKeys.keyframes[idx].value
            } else {
                // New keyframe starts from the CURRENT interpolated look so nothing jumps.
                let current = clip.keyframes.resolved(clip: clip, at: playhead)
                let clamped = max(0, min(local, clip.duration))
                workingKeys.keyframes.append(Keyframe(time: clamped, value: current, easing: .none))
                workingKeys.sortKeyframes()
                workingKeys.reassignKeyframes(frameRate: frameRate)
                let tolerance = 1.0 / Float(max(frameRate, 1))
                keyIndex = workingKeys.keyframes.firstIndex(where: { abs($0.time - clamped) <= tolerance })
                basis = current
            }
        }
        
        func pan(_ t: CGSize) { translation = t; recompute() }
        func pinch(_ s: CGFloat) { guard handle == nil else { return }; scale = s; recompute() }
        func rotate(_ r: CGFloat) { guard handle == nil else { return }; rotation = r; recompute() }
        
        private func recompute() {
            guard let clip = target else { return }
            var p = basis
            if let h = handle {
                p = scaledByHandle(h)
            } else {
            p.valuePosX = basis.valuePosX + Float(translation.width / fit)
            p.valuePosY = basis.valuePosY + Float(translation.height / fit)
            
            // Text is a bitmap layer now (TextRenderer), so it scales and rotates like any clip.
            // (Android's drawtext can only move it.)
            do {
                p.valueScaleX = basis.valueScaleX * Float(scale)
                p.valueScaleY = basis.valueScaleY * Float(scale)
                
                var rot = basis.valueRot + Float(rotation * 180 / .pi)
                rot = (rot + 360).truncatingRemainder(dividingBy: 720) - 360 // Android's [-360, 360) wrap
                let snap = Constants.CANVAS_ROTATE_SNAP_DEGREE
                let nearest = (rot / snap).rounded() * snap
                if abs(rot - nearest) <= Constants.CANVAS_ROTATE_SNAP_THRESHOLD_DEGREE { rot = nearest }
                p.valueRot = rot
            }
            // A pure move snaps; combined with a pinch / twist it would fight the gesture.
            if snappingOn, scale == 1, rotation == 0 { snapMove(&p) } else { setGuides(x: nil, y: nil) }
            }
            
            let state: LiveClipState
            if let idx = keyIndex, workingKeys.keyframes.indices.contains(idx) {
                var keys = workingKeys
                keys.keyframes[idx].value = p
                state = LiveClipState(properties: clip.videoProperties, keyframes: keys)
            } else {
                state = LiveClipState(properties: p, keyframes: clip.keyframes)
            }
            LiveOverrides.shared.set(state, for: clip.id)
            
            infoText = String(format: "Pos X: %.0f | Pos Y: %.0f\nScale X: %.2f | Scale Y: %.2f | Rot: %.1f",
                              p.valuePosX, p.valuePosY, p.valueScaleX, p.valueScaleY, p.valueRot)
            tick += 1
        }
        
        // MARK: Resize handles + snapping
        
        /// Desktop PreviewGizmo.scaleTo: the grabbed handle follows the finger along the line from the
        /// opposite handle (the anchor) through where it started; f = how far along that line it now is
        /// (1 = unchanged). Every handle is the same formula: corners scale both axes, top / bottom only Y,
        /// left / right only X; PosX / PosY then shift so the anchor stays where it was.
        private func scaledByHandle(_ h: Int) -> VideoProperties {
            var p = basis
            guard let clip = target, startQuad.count == 4 else { return p }
            let grabbed = CanvasGizmo.handlePoint(startQuad, h)
            let anchor = CanvasGizmo.handlePoint(startQuad, CanvasGizmo.opposite(h))
            // The handle moves by the finger's movement, so a touch beside the dot doesn't make it jump.
            let pointer = CGPoint(x: grabbed.x + translation.width / fit, y: grabbed.y + translation.height / fit)
            let vx = grabbed.x - anchor.x, vy = grabbed.y - anchor.y
            let len2 = vx * vx + vy * vy
            guard len2 > 1e-3 else { return p }
            var f = ((pointer.x - anchor.x) * vx + (pointer.y - anchor.y) * vy) / len2
            f = max(Constants.CANVAS_MIN_SCALE_FACTOR, f)
            if snappingOn {
                let snapped = CanvasGizmo.scaleSnap(anchor: anchor, vx: vx, vy: vy, f: f, lines: snapLines,
                                                    threshold: Constants.CANVAS_SNAP_SCREEN_POINTS / fit)
                f = max(Constants.CANVAS_MIN_SCALE_FACTOR, snapped.f)
                setGuides(x: snapped.lineX, y: snapped.lineY)
            } else {
                setGuides(x: nil, y: nil)
            }
            
            if h < 4 {
                p.valueScaleX = basis.valueScaleX * Float(f)
                p.valueScaleY = basis.valueScaleY * Float(f)
            } else if h == CanvasGizmo.top || h == CanvasGizmo.bottom {
                p.valueScaleY = basis.valueScaleY * Float(f)
            } else {
                p.valueScaleX = basis.valueScaleX * Float(f)
            }
            if let q = clip.quad(for: p, canvas: canvas, stretchToFull: stretchToFull), q.count == 4 {
                let pt = CanvasGizmo.handlePoint(q, CanvasGizmo.opposite(h))
                p.valuePosX += Float(anchor.x - pt.x)
                p.valuePosY += Float(anchor.y - pt.y)
            }
            return p
        }
        
        /// Nudges PosX / PosY so the clip's left / centre / right (and top / middle / bottom) land on a snap
        /// line when within a few screen points.
        private func snapMove(_ p: inout VideoProperties) {
            guard let clip = target,
                  let q = clip.quad(for: p, canvas: canvas, stretchToFull: stretchToFull), q.count == 4 else {
                setGuides(x: nil, y: nil)
                return
            }
            let snap = CanvasGizmo.moveSnap(quad: q, lines: snapLines,
                                            threshold: Constants.CANVAS_SNAP_SCREEN_POINTS / fit)
            if let dx = snap.shiftX { p.valuePosX += Float(dx) }
            if let dy = snap.shiftY { p.valuePosY += Float(dy) }
            setGuides(x: snap.lineX, y: snap.lineY)
        }
        
        /// Shows / hides the guide lines; a light tick when the clip latches onto a new line.
        private func setGuides(x: CGFloat?, y: CGFloat?) {
            if (x != nil && x != guideX) || (y != nil && y != guideY) {
                feedback.selectionChanged()
                feedback.prepare()
            }
            if guideX != x { guideX = x }
            if guideY != y { guideY = y }
        }
        
        /// Commit as a single undo step (or drop silently if nothing changed).
        func finish(commandManager: CommandManager, onChanged: @escaping () -> Void) {
            guard let clip = target else { return }
            defer {
                target = nil
                handle = nil
                LiveOverrides.shared.clear(clip.id)
                infoText = nil
                guideX = nil; guideY = nil
                tick += 1
            }
            guard let state = LiveOverrides.shared.state(for: clip.id) else { return }
            
            let beforeProps = startProps, beforeKeys = startKeys
            let afterProps = state.properties, afterKeys = state.keyframes
            guard beforeProps != afterProps || !Self.sameKeyframes(beforeKeys, afterKeys) else { return }
            
            commandManager.execute(GenericCommand(
                description: "Move/Transform: \(clip.clipName)",
                undo: { clip.videoProperties = beforeProps; clip.keyframes = beforeKeys; onChanged() },
                redo: { clip.videoProperties = afterProps; clip.keyframes = afterKeys; onChanged() }
            ))
        }
        
        private static func sameKeyframes(_ a: AnimatedProperty, _ b: AnimatedProperty) -> Bool {
            guard a.keyframes.count == b.keyframes.count else { return false }
            return !zip(a.keyframes, b.keyframes).contains {
                $0.time != $1.time || $0.value != $1.value || $0.easing != $1.easing
            }
        }
    }
    
    // MARK: UIKit gesture surface
    
    struct PreviewGestureSurface: UIViewRepresentable {
        var onTap: (CGPoint) -> Void
        /// (location in view points, started with two fingers)
        var onBegin: (CGPoint, Bool) -> Void
        var onPan: (CGSize) -> Void
        var onPinch: (CGFloat) -> Void
        var onRotate: (CGFloat) -> Void
        var onEnd: () -> Void
        
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            let c = context.coordinator
            let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
            let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
            pan.maximumNumberOfTouches = 1 // two fingers are pinch/rotate, as on Android
            let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
            let rotation = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.handleRotation(_:)))
            for g in [tap, pan, pinch, rotation] as [UIGestureRecognizer] {
                g.delegate = c
                view.addGestureRecognizer(g)
            }
            return view
        }
        
        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.parent = self
        }
        
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var parent: PreviewGestureSurface
            private var began = Set<ObjectIdentifier>()
            
            init(_ parent: PreviewGestureSurface) { self.parent = parent }
            
            func gestureRecognizer(_ g: UIGestureRecognizer,
                                   shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
            
            @objc func handleTap(_ g: UITapGestureRecognizer) {
                if g.state == .ended { parent.onTap(g.location(in: g.view)) }
            }
            @objc func handlePan(_ g: UIPanGestureRecognizer) {
                // A pan is recognised only after the finger has moved a few points: hit-test (clip /
                // handle) where it first touched, which is the current spot minus the translation so far.
                track(g, twoFinger: false, start: {
                    let l = g.location(in: g.view), t = g.translation(in: g.view)
                    return CGPoint(x: l.x - t.x, y: l.y - t.y)
                }) {
                    let t = g.translation(in: g.view)
                    parent.onPan(CGSize(width: t.x, height: t.y))
                }
            }
            @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
                track(g, twoFinger: true) { parent.onPinch(g.scale) }
            }
            @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
                track(g, twoFinger: true) { parent.onRotate(g.rotation) }
            }
            
            /// One session spans every recognizer that is active at once; it ends with the last one.
            private func track(_ g: UIGestureRecognizer, twoFinger: Bool, start: (() -> CGPoint)? = nil,
                               _ change: () -> Void) {
                let id = ObjectIdentifier(g)
                switch g.state {
                case .began:
                    if began.isEmpty { parent.onBegin(start?() ?? g.location(in: g.view), twoFinger) }
                    began.insert(id)
                    change()
                case .changed:
                    if began.contains(id) { change() }
                case .ended, .cancelled, .failed:
                    if began.remove(id) != nil, began.isEmpty { parent.onEnd() }
                default:
                    break
                }
            }
        }
    }
    
    // MARK: Overlay (selection box + info + gestures)
    
    struct PreviewInteractionLayer: View {
        let timeline: Timeline
        let selectedClipID: UUID?
        let playhead: Float
        let settings: VideoSettings
        let commandManager: CommandManager
        @ObservedObject var session: PreviewEditSession
        let onSelect: (Clip) -> Void
        let onLiveChange: () -> Void
        let onChanged: () -> Void
        
        var body: some View {
            GeometryReader { geo in
                let canvas = CGSize(width: CGFloat(max(settings.videoWidth, 1)), height: CGFloat(max(settings.videoHeight, 1)))
                // Same fit as VideoPlayer's .resizeAspect: centered, letterboxed.
                let fit = max(0.0001, min(geo.size.width / canvas.width, geo.size.height / canvas.height))
                let origin = CGPoint(x: (geo.size.width - canvas.width * fit) / 2,
                                     y: (geo.size.height - canvas.height * fit) / 2)
                
                ZStack(alignment: .bottom) {
                    PreviewGestureSurface(
                        onTap: { point in
                            if let hit = hits(at: point, canvas: canvas, fit: fit, origin: origin).first { onSelect(hit) }
                        },
                        onBegin: { point, twoFinger in
                            let candidates = hits(at: point, canvas: canvas, fit: fit, origin: origin)
                            let selected = visualClips().first { $0.id == selectedClipID && $0.isActive(at: playhead) }
                            
                            // A finger that lands on a handle of the selected clip resizes it; handles
                            // win over the move area (and over clips stacked on top).
                            if !twoFinger, let selected,
                               let quad = selected.previewQuad(at: playhead, canvas: canvas, stretchToFull: settings.isStretchToFull,
                                                               live: LiveOverrides.shared.state(for: selected.id)) {
                                let screen = quad.map { CGPoint(x: origin.x + $0.x * fit, y: origin.y + $0.y * fit) }
                                if let h = CanvasGizmo.hit(screenQuad: screen, at: point) {
                                    session.begin(clip: selected, playhead: playhead, fit: fit, frameRate: settings.frameRate,
                                                  canvas: canvas, stretchToFull: settings.isStretchToFull,
                                                  otherQuads: otherQuads(excluding: selected.id, canvas: canvas), handle: h)
                                    return
                                }
                            }
                            
                            let chosen: Clip?
                            if twoFinger {
                                chosen = selected ?? candidates.first
                            } else if let selected, candidates.contains(where: { $0.id == selected.id }) {
                                chosen = selected   // dragging inside the selected clip never grabs one above it
                            } else {
                                chosen = candidates.first
                            }
                            if let chosen {
                                session.begin(clip: chosen, playhead: playhead, fit: fit, frameRate: settings.frameRate,
                                              canvas: canvas, stretchToFull: settings.isStretchToFull,
                                              otherQuads: otherQuads(excluding: chosen.id, canvas: canvas))
                            }
                        },
                        onPan: { if session.isActive { session.pan($0); onLiveChange() } },
                        onPinch: { if session.isActive { session.pinch($0); onLiveChange() } },
                        onRotate: { if session.isActive { session.rotate($0); onLiveChange() } },
                        onEnd: { session.finish(commandManager: commandManager, onChanged: onChanged) }
                    )
                    
                    selectionBox(canvas: canvas, fit: fit, origin: origin)
                        .allowsHitTesting(false)
                    
                    guides(canvas: canvas, fit: fit, origin: origin)
                        .allowsHitTesting(false)
                    
                    if let info = session.infoText {
                        Text(info)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(6)
                            .padding(.bottom, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        
        // MARK: Helpers
        
        /// Draw order (bottom → top) — identical to the compositor's layer order.
        private func visualClips() -> [Clip] {
            timeline.tracks
                .sorted { $0.timelineIndex < $1.timelineIndex }
                .flatMap { $0.clips.sorted { $0.startTime < $1.startTime } }
                .filter { $0.isVisualClip }
        }
        
        /// The other visible clips' boxes at the playhead: what a move / resize can snap to.
        private func otherQuads(excluding id: UUID, canvas: CGSize) -> [[CGPoint]] {
            visualClips().compactMap { clip in
                guard clip.id != id, clip.isActive(at: playhead) else { return nil }
                return clip.previewQuad(at: playhead, canvas: canvas, stretchToFull: settings.isStretchToFull)
            }
        }
        
        /// Snap guides: pink lines across the canvas while a move / resize is latched onto a line.
        @ViewBuilder
        private func guides(canvas: CGSize, fit: CGFloat, origin: CGPoint) -> some View {
            Path { path in
                if let x = session.guideX {
                    let sx = origin.x + x * fit
                    path.move(to: CGPoint(x: sx, y: origin.y))
                    path.addLine(to: CGPoint(x: sx, y: origin.y + canvas.height * fit))
                }
                if let y = session.guideY {
                    let sy = origin.y + y * fit
                    path.move(to: CGPoint(x: origin.x, y: sy))
                    path.addLine(to: CGPoint(x: origin.x + canvas.width * fit, y: sy))
                }
            }
            .stroke(Color(red: 1, green: 0.25, blue: 0.65), lineWidth: 1)
        }
        
        /// Clips under a view point, topmost first.
        private func hits(at point: CGPoint, canvas: CGSize, fit: CGFloat, origin: CGPoint) -> [Clip] {
            let canvasPoint = CGPoint(x: (point.x - origin.x) / fit, y: (point.y - origin.y) / fit)
            return visualClips().reversed().filter { clip in
                guard clip.isActive(at: playhead),
                      let quad = clip.previewQuad(at: playhead, canvas: canvas, stretchToFull: settings.isStretchToFull,
                                                  live: LiveOverrides.shared.state(for: clip.id)) else { return false }
                return ClipGeometry.contains(canvasPoint, quad: quad)
            }
        }
        
        @ViewBuilder
        private func selectionBox(canvas: CGSize, fit: CGFloat, origin: CGPoint) -> some View {
            if let id = session.target?.id ?? selectedClipID,
               let clip = visualClips().first(where: { $0.id == id }),
               clip.isActive(at: playhead),
               let quad = clip.previewQuad(at: playhead, canvas: canvas, stretchToFull: settings.isStretchToFull,
                                           live: LiveOverrides.shared.state(for: clip.id)) {
                let pts = quad.map { CGPoint(x: origin.x + $0.x * fit, y: origin.y + $0.y * fit) }
                ZStack {
                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    
                    // Edge handles (a short bar along the edge) where the edge is long enough on screen.
                    ForEach(0..<4, id: \.self) { i in
                        if CanvasGizmo.edgeIsLongEnough(pts, edge: i) {
                            let a = pts[i], b = pts[(i + 1) % 4]
                            Capsule().fill(Color.white)
                                .frame(width: 18, height: 6)
                                .overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                                .rotationEffect(.radians(atan2(b.y - a.y, b.x - a.x)))
                                .position(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                        }
                    }
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(Color.white).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                            .position(pts[i])
                    }
                }
            }
        }
    }
}
