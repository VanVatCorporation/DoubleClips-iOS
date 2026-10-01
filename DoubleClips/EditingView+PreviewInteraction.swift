import SwiftUI
import UIKit
import Combine

// MARK: - On-canvas editing (Android: ClipRenderer.attachGestureControls)
//
//   tap        → select the clip under the finger
//   1-finger   → move  (PosX / PosY, canvas pixels)
//   pinch      → uniform scale (ScaleX & ScaleY multiplied by the same factor)
//   2-finger twist → rotate (degrees, snaps to 90° within 3°)
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
        private(set) var target: Clip?
        
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
        
        func begin(clip: Clip, playhead: Float, fit: CGFloat, frameRate: Int) {
            target = clip
            self.fit = max(fit, 0.0001)
            translation = .zero; scale = 1; rotation = 0
            startProps = clip.videoProperties
            startKeys = clip.keyframes
            workingKeys = clip.keyframes
            keyIndex = nil
            basis = clip.videoProperties
            
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
        func pinch(_ s: CGFloat) { scale = s; recompute() }
        func rotate(_ r: CGFloat) { rotation = r; recompute() }
        
        private func recompute() {
            guard let clip = target else { return }
            var p = basis
            p.valuePosX = basis.valuePosX + Float(translation.width / fit)
            p.valuePosY = basis.valuePosY + Float(translation.height / fit)
            
            // Text is drawn by drawtext on Android: move only.
            if clip.type != .text {
                p.valueScaleX = basis.valueScaleX * Float(scale)
                p.valueScaleY = basis.valueScaleY * Float(scale)
                
                var rot = basis.valueRot + Float(rotation * 180 / .pi)
                rot = (rot + 360).truncatingRemainder(dividingBy: 720) - 360 // Android's [-360, 360) wrap
                let snap = Constants.CANVAS_ROTATE_SNAP_DEGREE
                let nearest = (rot / snap).rounded() * snap
                if abs(rot - nearest) <= Constants.CANVAS_ROTATE_SNAP_THRESHOLD_DEGREE { rot = nearest }
                p.valueRot = rot
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
        
        /// Commit as a single undo step (or drop silently if nothing changed).
        func finish(commandManager: CommandManager, onChanged: @escaping () -> Void) {
            guard let clip = target else { return }
            defer {
                target = nil
                LiveOverrides.shared.clear(clip.id)
                infoText = nil
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
                track(g, twoFinger: false) {
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
            private func track(_ g: UIGestureRecognizer, twoFinger: Bool, _ change: () -> Void) {
                let id = ObjectIdentifier(g)
                switch g.state {
                case .began:
                    if began.isEmpty { parent.onBegin(g.location(in: g.view), twoFinger) }
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
                            let chosen: Clip?
                            if twoFinger {
                                chosen = selected ?? candidates.first
                            } else if let selected, candidates.contains(where: { $0.id == selected.id }) {
                                chosen = selected   // dragging inside the selected clip never grabs one above it
                            } else {
                                chosen = candidates.first
                            }
                            if let chosen {
                                session.begin(clip: chosen, playhead: playhead, fit: fit, frameRate: settings.frameRate)
                            }
                        },
                        onPan: { if session.isActive { session.pan($0); onLiveChange() } },
                        onPinch: { if session.isActive { session.pinch($0); onLiveChange() } },
                        onRotate: { if session.isActive { session.rotate($0); onLiveChange() } },
                        onEnd: { session.finish(commandManager: commandManager, onChanged: onChanged) }
                    )
                    
                    selectionBox(canvas: canvas, fit: fit, origin: origin)
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
                    
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(Color.white).frame(width: 9, height: 9).position(pts[i])
                    }
                }
            }
        }
    }
}
