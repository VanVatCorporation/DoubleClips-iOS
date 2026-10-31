import SwiftUI
import Combine

// MARK: - Motion panel (toolbar "Motion", ported from the desktop's Motion tab)
//
//  - Optical flow: the frame rate the clip's in-between frames are made at (typed, any positive number). When it is above the
//    project's frame rate the extra frames can't be shown: the panel says so.
//  - Motion blur: Blur and Blend (0...100, each with the keyframe diamond like every other slider: the `motionBlur` / `motionBlend`
//    channels), the streak Direction, and Speed: how many times the blur is applied (typed, 1 or more).
//
// Every change is ONE undo step that puts back the clip's two switches, its plain slider values and its keyframes. While a ruler is
// dragged the preview follows live through `LiveOverrides` (the sliders are ordinary properties, so no rebuild is needed); the
// switches, Direction, Speed and the frame rate rebuild the player item, because they change which footage the composition carries.

extension EditingView {
    
    final class MotionEditState: ObservableObject {
        static let shared = MotionEditState()
        /// Bumped on every live change so the panel's numbers follow.
        @Published var tick = 0
    }
    
    struct MotionPanel: View {
        @ObservedObject var clip: Clip
        let commandManager: CommandManager
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        @ObservedObject private var state = MotionEditState.shared
        @State private var dragBefore: Snap?
        @State private var fpsText = ""
        @State private var passesText = ""
        @FocusState private var fpsFocused: Bool
        @FocusState private var passesFocused: Bool
        
        /// What one undo step puts back.
        private struct Snap: Equatable {
            var properties: VideoProperties
            var keys: AnimatedProperty
            var flow: ClipOpticalFlow?
            var blur: ClipMotionBlur?
            
            func restore(_ clip: Clip) {
                clip.videoProperties = properties
                clip.keyframes = keys
                clip.opticalFlow = flow
                clip.motionBlur = blur
            }
        }
        
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                opticalFlowBlock
                Divider().background(Color.white.opacity(0.15))
                motionBlurBlock
            }
            .onAppear { syncTexts() }
            .onChange(of: clip.opticalFlow) { _, _ in if !fpsFocused { syncTexts() } }
            .onChange(of: clip.motionBlur) { _, _ in if !passesFocused { syncTexts() } }
            .onDisappear { commitFPS(); commitPasses(); endDrag() }
            .toolbar {
                // The number pads have no Return key: Done closes the keyboard, which applies the typed number.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("Done")) { fpsFocused = false; passesFocused = false }
                }
            }
        }
        
        private func syncTexts() {
            fpsText = ClipOpticalFlow.format(clip.opticalFlow?.effectiveFPS ?? ClipOpticalFlow.defaultFPS)
            passesText = String(clip.motionBlur?.effectivePasses ?? 1)
        }
        
        // MARK: Optical flow
        
        private var opticalFlowBlock: some View {
            VStack(alignment: .leading, spacing: 10) {
                header("Optical flow", on: clip.hasOpticalFlow) { setOpticalFlow($0) }
                if let flow = clip.opticalFlow, flow.enabled {
                    HStack {
                        Text(L("Frame rate (fps)")).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                        Spacer()
                        TextField("", text: $fpsText)
                            .focused($fpsFocused)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 80)
                            .padding(6)
                            .background(Color.white.opacity(0.1)).cornerRadius(6)
                            .onChange(of: fpsFocused) { _, focused in if !focused { commitFPS() } }
                    }
                    if flow.effectiveFPS > Float(frameRate) + 0.001 {
                        Text(Lf("The project plays at %d fps, so frames above that rate are not shown. Raise the project's frame rate in the project settings.", Int32(frameRate)))
                            .font(.system(size: 11)).foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    note(L("Frames are made by following how things move between two source frames. Slow the clip down to see it."))
                } else {
                    note(L("Makes smooth in-between frames when the clip is slowed down, by following how things move."))
                }
            }
        }
        
        private func setOpticalFlow(_ on: Bool) {
            guard on != clip.hasOpticalFlow else { return }
            change(on ? "Switch On Optical Flow" : "Switch Off Optical Flow") { s in
                if s.flow == nil { s.flow = ClipOpticalFlow() }
                s.flow?.enabled = on
            }
        }
        
        private func commitFPS() {
            let typed = Float(fpsText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            defer { syncTexts() }       // not a usable rate: shows what is kept
            guard let typed, typed.isFinite, typed > 0, let live = clip.opticalFlow, abs(typed - live.effectiveFPS) > 1e-4 else { return }
            change("Change Optical Flow Frame Rate") { $0.flow?.fps = typed }
        }
        
        // MARK: Motion blur
        
        private var motionBlurBlock: some View {
            VStack(alignment: .leading, spacing: 12) {
                header("Motion blur", on: clip.hasMotionBlur) { setMotionBlur($0) }
                if let blur = clip.motionBlur, blur.enabled {
                    sliderRow("Blur", .motionBlur)
                    sliderRow("Blend", .motionBlend)
                    
                    HStack {
                        Text(L("Direction")).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Picker("", selection: Binding(get: { blur.directionValue },
                                                      set: { setDirection($0) })) {
                            ForEach(ClipMotionBlur.Direction.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 230)
                    }
                    
                    HStack {
                        Text(L("Speed (times)")).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                        Spacer()
                        TextField("", text: $passesText)
                            .focused($passesFocused)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 70)
                            .padding(6)
                            .background(Color.white.opacity(0.1)).cornerRadius(6)
                            .onChange(of: passesFocused) { _, focused in if !focused { commitPasses() } }
                    }
                    note(L("Speed is how many times the blur is applied: more times, more obvious streaks."))
                } else {
                    note(L("Streaks moving things along their path, using the same flow between frames. It works on this clip only."))
                }
            }
        }
        
        private func setMotionBlur(_ on: Bool) {
            guard on != clip.hasMotionBlur else { return }
            change(on ? "Switch On Motion Blur" : "Switch Off Motion Blur") { s in
                if s.blur == nil { s.blur = ClipMotionBlur() }
                s.blur?.enabled = on
            }
        }
        
        private func setDirection(_ direction: ClipMotionBlur.Direction) {
            guard let live = clip.motionBlur, live.directionValue != direction else { return }
            change("Change Motion Blur Direction") { $0.blur?.directionValue = direction }
        }
        
        private func commitPasses() {
            let typed = Int(passesText.trimmingCharacters(in: .whitespaces))
            defer { syncTexts() }
            guard let typed, typed >= 1, let live = clip.motionBlur, typed != live.effectivePasses else { return }
            change("Change Motion Blur Speed") { $0.blur?.passes = typed }
        }
        
        // MARK: Blur / Blend sliders with keyframes
        
        private func sliderRow(_ title: String, _ type: VideoProperties.ValueType) -> some View {
            HStack(spacing: 6) {
                Text(L(title))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    .frame(width: 64, alignment: .leading)
                RulerSlider(value: Binding(get: { valueNow(type) }, set: { setLive(type, $0) }),
                            range: 0...ClipMotionBlur.scaleMax, unitsPerTick: 1,
                            onEditingBegan: beginDrag, onEditingEnded: endDrag)
                NumberField(label: "", value: Binding(
                    get: { valueNow(type).rounded() },
                    set: { newValue in beginDrag(); setLive(type, newValue); endDrag() }
                )) {}
                .frame(width: 60)
                KeyDiamond(mode: keyMode(type), enabled: playheadInsideClip) { toggleKey(type) }
            }
        }
        
        private func live() -> (properties: VideoProperties, keys: AnimatedProperty) {
            let l = LiveOverrides.shared.state(for: clip.id)
            return (l?.properties ?? clip.videoProperties, l?.keyframes ?? clip.keyframes)
        }
        
        private func valueNow(_ type: VideoProperties.ValueType) -> Float {
            _ = state.tick
            let (props, keys) = live()
            if keys.isAnimated(type) {
                return keys.value(for: type, base: props, clipStartTime: clip.startTime, at: clip.startTime + localTime)
            }
            return props.value(type)
        }
        
        private func keyMode(_ type: VideoProperties.ValueType) -> KeyDiamond.Mode {
            _ = state.tick
            let keys = live().keys
            guard keys.isAnimated(type) else { return .off }
            return keys.keyframeIndex(atLocal: localTime, animating: type) != nil ? .onKey : .animated
        }
        
        /// The diamond: animate this slider from here on (a keyframe with its current value), or take the keyframe there away (the
        /// last one leaves the slider where it was).
        private func toggleKey(_ type: VideoProperties.ValueType) {
            guard playheadInsideClip else { return }
            let now = valueNow(type)
            let local = localTime
            let start = clip.startTime, rate = frameRate
            change("Keyframe \(VideoProperties.displayName(for: type))") { s in
                if s.keys.keyframeIndex(atLocal: local, animating: type) != nil {
                    if let removed = s.keys.removeKey(type, atLocal: local), !s.keys.isAnimated(type) {
                        s.properties.setValue(removed, type)
                    }
                } else {
                    s.keys.setKey(type, atLocal: local, value: now, base: s.properties, clipStartTime: start, frameRate: rate)
                }
            }
        }
        
        private func beginDrag() {
            if dragBefore == nil { dragBefore = snap() }
        }
        
        /// A ruler step or a typed value: the preview follows live. An animated slider edits the keyframe at the playhead (adding one
        /// there when none is); any other is the clip's plain value.
        private func setLive(_ type: VideoProperties.ValueType, _ value: Float) {
            beginDrag()
            var (props, keys) = live()
            let v = min(max(value.isNaN ? 0 : value.rounded(), 0), ClipMotionBlur.scaleMax)
            if keys.isAnimated(type) {
                keys.setKey(type, atLocal: localTime, value: v, base: clip.videoProperties,
                            clipStartTime: clip.startTime, frameRate: frameRate)
            } else {
                props.setValue(v, type)
            }
            LiveOverrides.shared.set(LiveClipState(properties: props, keyframes: keys), for: clip.id)
            state.tick += 1
            MaskEditState.shared.refresh?()
        }
        
        private func endDrag() {
            guard let start = dragBefore else { return }
            dragBefore = nil
            let l = LiveOverrides.shared.state(for: clip.id)
            LiveOverrides.shared.clear(clip.id)
            state.tick += 1
            guard let l else { MaskEditState.shared.refresh?(); return }
            var after = start
            after.properties = l.properties
            after.keys = l.keyframes
            guard after != start else { MaskEditState.shared.refresh?(); return }
            commit("Change Motion Blur", before: start, after: after)
        }
        
        // MARK: Undo
        
        private func snap() -> Snap {
            Snap(properties: clip.videoProperties, keys: clip.keyframes, flow: clip.opticalFlow, blur: clip.motionBlur)
        }
        
        /// One undo step: runs `mutate` on a copy of the clip's motion state and commits it.
        private func change(_ name: String, _ mutate: (inout Snap) -> Void) {
            let before = snap()
            var after = before
            mutate(&after)
            guard after != before else { return }
            commit(name, before: before, after: after)
        }
        
        private func commit(_ name: String, before: Snap, after: Snap) {
            let target = clip
            let changed = onChanged
            after.restore(target)
            commandManager.execute(GenericCommand(
                description: "\(name): \(clip.clipName)",
                undo: { before.restore(target); changed() },
                redo: { after.restore(target); changed() }))
            changed()
        }
        
        // MARK: Small pieces
        
        private func header(_ title: String, on: Bool, _ toggle: @escaping (Bool) -> Void) -> some View {
            HStack {
                Text(L(title)).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: toggle)).labelsHidden().tint(Color.mdPrimary)
            }
        }
        
        private func note(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
