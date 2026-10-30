import SwiftUI
import AVFoundation
import CoreImage
import Combine

// MARK: - Background panel (toolbar "Background", ported from desktop's Background tab)
//
// What the panel offers, as on desktop (CapCut's "Remove BG"):
//   - "Remove Background": the AI cut-out switch. A stub on iOS, like on desktop for now: the flag is stored in the clip
//     (`removeBackground`) and nothing draws it yet.
//   - Chroma keys, up to `ChromaKey.maxKeys` of them (CapCut allows one): each a colour that goes transparent, with its own
//     Intensity / Shadow / Feather edge / Clean up edge, 0...100. What they do is described in EditingView+ChromaKey.swift.
//
// Every slider has a keyframe diamond like the other properties (the `chroma*` channels of the clip's keyframes, desktop's names). Not
// animated, a slider edits the key's plain value; animated, it edits the keyframe at the playhead (adding one there when there is none)
// and follows the playhead.
//
// A colour comes from the system colour picker, or from the eyedropper: tap the preview and the colour of the CLIP's own picture
// under the finger is taken (other tracks and an already keyed area don't get in the way).
//
// Every change is ONE undo step that puts back the clip's whole key list AND its keyframes. While a ruler is dragged the preview follows
// live through `LiveOverrides`, without rebuilding the player item.

extension EditingView {
    
    /// Shared by the panel and the preview's gesture layer, like `MaskEditState`.
    final class ChromaEditState: ObservableObject {
        static let shared = ChromaEditState()
        /// Bumped on every live change (ruler, typed value, colour) so the panel's numbers follow.
        @Published var tick = 0
        /// The eyedropper is waiting for a tap on the preview.
        @Published var isPicking = false
        var targetClipID: UUID?
        /// Called by the preview with the tapped spot, as fractions (0...1, y down) of the clip's own box.
        var onSample: ((CGPoint) -> Void)?
        
        func stopPicking() {
            onSample = nil
            if isPicking { isPicking = false }
        }
    }
    
    /// Reads a colour off the clip's own picture.
    enum ChromaSampler {
        
        /// The fractions (u, v) of the clip's box that `point` (canvas pixels, y down) is at, given the box's corners TL, TR, BR, BL
        /// on the canvas (it may be scaled, rotated or mirrored); nil when the point is outside it.
        static func boxPoint(of point: CGPoint, in quad: [CGPoint]) -> CGPoint? {
            guard quad.count == 4 else { return nil }
            let o = quad[0]
            let ex = CGPoint(x: quad[1].x - o.x, y: quad[1].y - o.y)
            let ey = CGPoint(x: quad[3].x - o.x, y: quad[3].y - o.y)
            let det = ex.x * ey.y - ex.y * ey.x
            guard abs(det) > 0.0001 else { return nil }
            let d = CGPoint(x: point.x - o.x, y: point.y - o.y)
            let u = (d.x * ey.y - d.y * ey.x) / det
            let v = (ex.x * d.y - ex.y * d.x) / det
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
            return CGPoint(x: u, y: v)
        }
        
        /// The average colour (r, g, b, 0...1, sRGB) of a few pixels around fractions `uv` of the clip's picture at `localTime`
        /// (seconds into the clip); nil when the picture can't be read. `completion` runs on the main thread.
        static func sample(clip: Clip, projectPath: String, localTime: Float, at uv: CGPoint,
                           completion: @escaping ((r: Float, g: Float, b: Float)?) -> Void) {
            let url = clip.mediaURL(projectPath: projectPath)
            switch clip.type {
            case .image:
                DispatchQueue.global(qos: .userInitiated).async {
                    var result: (r: Float, g: Float, b: Float)?
                    if let picture = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                       let cg = CIContext().createCGImage(picture, from: picture.extent) {
                        result = average(cg, at: uv)
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            case .video:
                // The source second under the playhead: the trim, plus what the clip's speed has consumed.
                let seconds = Double(clip.startClipTrim) + clip.timeMap.sourceOffset(atLocal: Double(max(localTime, 0)))
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
                let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    var result: (r: Float, g: Float, b: Float)?
                    if let image { result = average(image, at: uv) }
                    DispatchQueue.main.async {
                        _ = generator       // alive until the frame has come
                        completion(result)
                    }
                }
            default:
                completion(nil)
            }
        }
        
        /// 5 x 5 pixels around (u, v), averaged by drawing them into one pixel.
        private static func average(_ image: CGImage, at uv: CGPoint) -> (r: Float, g: Float, b: Float)? {
            let w = image.width, h = image.height
            guard w > 0, h > 0 else { return nil }
            let cx = min(max(Int((uv.x * CGFloat(w)).rounded(.down)), 0), w - 1)
            let cy = min(max(Int((uv.y * CGFloat(h)).rounded(.down)), 0), h - 1)
            let x0 = max(0, cx - 2), y0 = max(0, cy - 2)
            let x1 = min(w - 1, cx + 2), y1 = min(h - 1, cy + 2)
            guard let crop = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            let drawn: Bool = pixel.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            guard drawn, pixel[3] > 0 else { return nil }
            let a = Float(pixel[3]) / 255
            return (min(Float(pixel[0]) / 255 / a, 1), min(Float(pixel[1]) / 255 / a, 1), min(Float(pixel[2]) / 255 / a, 1))
        }
    }
    
    /// What a colour change waits on: the system colour picker reports every step of a drag and never says it is done, so the change
    /// is shown live and committed (as one undo step) when it has been still for a moment.
    final class ChromaDragState {
        var before: (keys: [ChromaKey], keyframes: AnimatedProperty)?
        var pendingCommit: DispatchWorkItem?
    }
    
    struct BackgroundPanel: View {
        @ObservedObject var clip: Clip
        let commandManager: CommandManager
        let projectPath: String
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        @ObservedObject private var state = ChromaEditState.shared
        @State private var drag = ChromaDragState()
        
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        
        /// The keys as they are right now: the live ones while a ruler / colour change is in flight.
        private var keys: [ChromaKey] {
            _ = state.tick
            return LiveOverrides.shared.state(for: clip.id)?.chromaKeys ?? clip.chromaKeys
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                removeBackgroundRow
                
                HStack(spacing: 8) {
                    Text(L("Chroma key")).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Text("\(keys.count) / \(ChromaKey.maxKeys)")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Button { addKey() } label: {
                        Label(L("Add key"), systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.1)).cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(keys.count >= ChromaKey.maxKeys ? .white.opacity(0.3) : .white)
                    .disabled(keys.count >= ChromaKey.maxKeys)
                }
                
                if keys.isEmpty {
                    note(L("Add a chroma key, then pick the colour to remove (use the eyedropper on the preview). Add more keys to remove more colours."))
                }
                if state.isPicking {
                    HStack {
                        Image(systemName: "eyedropper").foregroundColor(Color.mdPrimary)
                        Text(L("Tap the colour to remove in the preview."))
                            .font(.system(size: 12)).foregroundColor(.white)
                        Spacer()
                        Button(L("Cancel")) { state.stopPicking() }
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(Color.mdPrimary)
                    }
                    .padding(10)
                    .background(Color.mdPrimary.opacity(0.15)).cornerRadius(8)
                }
                
                ForEach(Array(keys.indices), id: \.self) { index in
                    card(index)
                }
                
                note(L("The keys filter the clip's own picture before its colour grade and masks."))
            }
            .onDisappear {
                state.stopPicking()
                finishDrag()
            }
        }
        
        // MARK: Remove Background (stub)
        
        private var removeBackgroundRow: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Remove Background")).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: Binding(get: { clip.removeBackground }, set: { setRemoveBackground($0) }))
                        .labelsHidden()
                        .tint(Color.mdPrimary)
                }
                note(L("The cut-out is not drawn on iOS yet; the switch is stored in the clip."))
            }
        }
        
        private func setRemoveBackground(_ on: Bool) {
            let old = clip.removeBackground
            guard old != on else { return }
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Remove Background: \(clip.clipName)",
                undo: { target.removeBackground = old; onChanged() },
                redo: { target.removeBackground = on; onChanged() }
            ))
        }
        
        // MARK: One key
        
        @ViewBuilder
        private func card(_ index: Int) -> some View {
            if let key = keys[safe: index] {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { key.enabled }, set: { setEnabled(index, $0) }))
                            .labelsHidden()
                            .tint(Color.mdPrimary)
                        Text(Lf("Key %d", Int32(index + 1))).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Spacer()
                        Button(L("Reset")) { resetKey(index) }
                            .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                        Button { removeKey(index) } label: {
                            Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack(spacing: 8) {
                        Text(L("Color")).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                            .frame(width: 64, alignment: .leading)
                        ColorPicker("", selection: Binding(get: { swatch(key) }, set: { colorChanged(index, $0) }),
                                    supportsOpacity: false)
                            .labelsHidden()
                        Text(key.color.uppercased()).font(.system(size: 12, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Button { startPicking(index) } label: {
                            Label(L("Pick"), systemImage: "eyedropper")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.white.opacity(0.1)).cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                    }
                    
                    ForEach(ChromaParam.allCases, id: \.self) { param in
                        row(index, param)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
                .opacity(key.enabled ? 1 : 0.55)
            }
        }
        
        private func row(_ index: Int, _ param: ChromaParam) -> some View {
            HStack(spacing: 6) {
                Text(L(param.title))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    .frame(width: 64, alignment: .leading)
                    .lineLimit(2).minimumScaleFactor(0.8)
                RulerSlider(
                    value: Binding(get: { valueNow(index, param) }, set: { setLive(index, param, $0) }),
                    range: 0...ChromaKey.scaleMax, unitsPerTick: 1,
                    onEditingBegan: beginDrag, onEditingEnded: endDrag)
                NumberField(label: "", value: Binding(
                    get: { valueNow(index, param).rounded() },
                    set: { newValue in beginDrag(); setLive(index, param, newValue); endDrag() }
                )) {}
                .frame(width: 60)
                KeyDiamond(mode: keyMode(index, param), enabled: playheadInsideClip) { toggleKey(index, param) }
            }
        }
        
        private func note(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        
        private func swatch(_ key: ChromaKey) -> Color {
            let c = key.rgb
            return Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b))
        }
        
        // MARK: Values and keyframes
        
        /// A slider at the playhead: the keyframed value when some keyframe holds it, else the key's plain value.
        private func valueNow(_ index: Int, _ param: ChromaParam) -> Float {
            _ = state.tick
            let live = LiveOverrides.shared.state(for: clip.id)
            let list = live?.chromaKeys ?? clip.chromaKeys
            guard list.indices.contains(index) else { return 0 }
            let frames = live?.keyframes ?? clip.keyframes
            if let type = VideoProperties.ValueType.chroma(index, param), frames.isAnimated(type) {
                return frames.value(for: type, base: VideoProperties(), clipStartTime: clip.startTime,
                                    at: clip.startTime + localTime)
            }
            return list[index].get(param)
        }
        
        private func keyMode(_ index: Int, _ param: ChromaParam) -> KeyDiamond.Mode {
            _ = state.tick
            guard let type = VideoProperties.ValueType.chroma(index, param) else { return .off }
            let frames = LiveOverrides.shared.state(for: clip.id)?.keyframes ?? clip.keyframes
            guard frames.isAnimated(type) else { return .off }
            return frames.keyframeIndex(atLocal: localTime, animating: type) != nil ? .onKey : .animated
        }
        
        /// The diamond: animate this slider from the playhead on (a keyframe with its current value), or take the keyframe there away
        /// (the last one leaves the slider where it was).
        private func toggleKey(_ index: Int, _ param: ChromaParam) {
            guard playheadInsideClip, clip.chromaKeys.indices.contains(index),
                  let type = VideoProperties.ValueType.chroma(index, param) else { return }
            let now = valueNow(index, param)
            let local = localTime
            edit("Keyframe Chroma Key") { keys, frames in
                if frames.keyframeIndex(atLocal: local, animating: type) != nil {
                    if let removed = frames.removeKey(type, atLocal: local), !frames.isAnimated(type) {
                        keys[index].set(param, removed)
                    }
                } else {
                    frames.setKey(type, atLocal: local, value: now, base: clip.videoProperties,
                                  clipStartTime: clip.startTime, frameRate: frameRate)
                }
            }
        }
        
        // MARK: Live editing (rulers, typed numbers, colour)
        
        private func beginDrag() {
            if drag.before == nil { drag.before = (clip.chromaKeys, clip.keyframes) }
        }
        
        /// A ruler step or a typed value: the preview follows live. A slider the key animates edits the keyframe at the playhead
        /// (adding one there when none is); any other is the key's plain value.
        private func setLive(_ index: Int, _ param: ChromaParam, _ value: Float) {
            beginDrag()
            let live = LiveOverrides.shared.state(for: clip.id)
            var list = live?.chromaKeys ?? clip.chromaKeys
            var frames = live?.keyframes ?? clip.keyframes
            guard list.indices.contains(index), let type = VideoProperties.ValueType.chroma(index, param) else { return }
            let v = min(max(value.isNaN ? 0 : value.rounded(), 0), ChromaKey.scaleMax)
            if frames.isAnimated(type) {
                frames.setKey(type, atLocal: localTime, value: v, base: clip.videoProperties,
                              clipStartTime: clip.startTime, frameRate: frameRate)
            } else {
                list[index].set(param, v)
            }
            pushLive(list, frames)
        }
        
        private func pushLive(_ list: [ChromaKey], _ frames: AnimatedProperty) {
            LiveOverrides.shared.set(LiveClipState(properties: clip.videoProperties, keyframes: frames, chromaKeys: list), for: clip.id)
            state.tick += 1
            MaskEditState.shared.refresh?()
        }
        
        private func endDrag() {
            guard let start = drag.before else { return }
            drag.before = nil
            let live = LiveOverrides.shared.state(for: clip.id)
            LiveOverrides.shared.clear(clip.id)
            state.tick += 1
            guard let live, let list = live.chromaKeys, list != start.keys || live.keyframes != start.keyframes else {
                MaskEditState.shared.refresh?()
                return
            }
            commit("Change Chroma Key", before: start, after: (list, live.keyframes))
        }
        
        /// Commits a colour change that is still waiting (the panel is closing).
        private func finishDrag() {
            drag.pendingCommit?.cancel()
            drag.pendingCommit = nil
            endDrag()
        }
        
        /// The system picker's colour: shown live, committed once it has been still for a moment.
        private func colorChanged(_ index: Int, _ color: Color) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let hex = ChromaKey.toHex(r: Float(r), g: Float(g), b: Float(b))
            let live = LiveOverrides.shared.state(for: clip.id)
            var list = live?.chromaKeys ?? clip.chromaKeys
            guard list.indices.contains(index), list[index].color.uppercased() != hex else { return }
            beginDrag()
            list[index].color = hex
            pushLive(list, live?.keyframes ?? clip.keyframes)
            drag.pendingCommit?.cancel()
            let work = DispatchWorkItem { [drag] in
                drag.pendingCommit = nil
                endDrag()
            }
            drag.pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        
        // MARK: The eyedropper
        
        private func startPicking(_ index: Int) {
            let target = clip
            let path = projectPath
            let local = localTime
            state.targetClipID = clip.id
            state.onSample = { uv in
                ChromaSampler.sample(clip: target, projectPath: path, localTime: local, at: uv) { rgb in
                    ChromaEditState.shared.stopPicking()
                    guard let rgb else { return }
                    let hex = ChromaKey.toHex(r: rgb.r, g: rgb.g, b: rgb.b)
                    guard target.chromaKeys.indices.contains(index), target.chromaKeys[index].color.uppercased() != hex else { return }
                    let before = (keys: target.chromaKeys, keyframes: target.keyframes)
                    var list = before.keys
                    list[index].color = hex
                    let manager = commandManager
                    let changed = onChanged
                    manager.execute(GenericCommand(
                        description: "Pick Chroma Key Color: \(target.clipName)",
                        undo: { target.chromaKeys = before.keys; changed() },
                        redo: { target.chromaKeys = list; changed() }))
                    ChromaEditState.shared.tick += 1
                }
            }
            state.isPicking = true
        }
        
        // MARK: Edits (one undo step each)
        
        private func addKey() {
            edit("Add Chroma Key") { keys, _ in
                if keys.count < ChromaKey.maxKeys { keys.append(ChromaKey()) }
            }
        }
        
        private func removeKey(_ index: Int) {
            edit("Remove Chroma Key") { keys, frames in
                guard keys.indices.contains(index) else { return }
                keys.remove(at: index)
                frames.chromaKeyRemoved(index)      // the keys after it move down one place, and so do their keyframes
            }
        }
        
        private func resetKey(_ index: Int) {
            edit("Reset Chroma Key") { keys, frames in
                guard keys.indices.contains(index) else { return }
                frames.clearChromaKey(index)         // the sliders are plain values again ...
                keys[index].intensity = ChromaKey.defaultIntensity     // ... at their defaults; the colour stays: it is what the key is for
                keys[index].shadow = 0
                keys[index].feather = 0
                keys[index].cleanUpEdge = 0
            }
        }
        
        private func setEnabled(_ index: Int, _ on: Bool) {
            edit(on ? "Enable Chroma Key" : "Disable Chroma Key") { keys, _ in
                guard keys.indices.contains(index) else { return }
                keys[index].enabled = on
            }
        }
        
        /// One undo step: `change` edits copies of the clip's key list and keyframes, which then replace them.
        private func edit(_ name: String, _ change: (inout [ChromaKey], inout AnimatedProperty) -> Void) {
            var list = clip.chromaKeys
            var frames = clip.keyframes
            let before = (keys: list, keyframes: frames)
            change(&list, &frames)
            guard list != before.keys || frames != before.keyframes else { return }
            commit(name, before: before, after: (list, frames))
        }
        
        private func commit(_ name: String, before: (keys: [ChromaKey], keyframes: AnimatedProperty),
                            after: (keys: [ChromaKey], keyframes: AnimatedProperty)) {
            let target = clip
            let changed = onChanged
            commandManager.execute(GenericCommand(
                description: "\(name): \(clip.clipName)",
                undo: { target.chromaKeys = before.keys; target.keyframes = before.keyframes; changed() },
                redo: { target.chromaKeys = after.keys; target.keyframes = after.keyframes; changed() }
            ))
            state.tick += 1
        }
    }
}
