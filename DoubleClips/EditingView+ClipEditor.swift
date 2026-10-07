import SwiftUI

// MARK: - Clip editor panels
//
// iOS counterpart of ClipEditSpecificAreaScreen (+ TextEditSpecificAreaScreen).
// Every change goes through CommandManager so it is undoable, and calls `onChanged`
// so the preview can refresh.

extension EditingView {
    
    // MARK: Number field
    
    struct NumberField: View {
        let label: String
        @Binding var value: Float
        var onCommit: () -> Void = {}
        @State private var text: String = ""
        @FocusState private var focused: Bool
        
        var body: some View {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)
                TextField("", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focused)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                    .onSubmit(commit)
                    .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { newValue in if !focused { text = Self.format(newValue) } }
        }
        
        private func commit() {
            if let parsed = Float(text.trimmingCharacters(in: .whitespaces)), parsed != value {
                value = parsed
                onCommit()
            }
            text = Self.format(value)
        }
        
        static func format(_ v: Float) -> String {
            let s = String(format: "%.2f", v)
            return s.contains(".") ? s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : s
        }
    }
    
    // MARK: Slider with reset + undo registration
    
    struct PropertySlider: View {
        let label: String
        @Binding var value: Float
        let range: ClosedRange<Float>
        var resetTo: Float? = nil
        var onEditingBegan: () -> Void = {}
        var onEditingEnded: () -> Void = {}
        
        var body: some View {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)
                
                Slider(
                    value: Binding(get: { Double(value) }, set: { value = Float($0) }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    onEditingChanged: { editing in editing ? onEditingBegan() : onEditingEnded() }
                )
                .accentColor(Color.mdPrimary)
                
                Text(String(format: "%.2f", value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 48, alignment: .trailing)
                
                if let resetTo {
                    Button {
                        onEditingBegan()
                        value = resetTo
                        onEditingEnded()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
    }
    
    // MARK: Section header
    
    private struct SectionTitle: View {
        let text: String
        var body: some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.mdPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }
    
    // MARK: - Clip properties editor
    
    struct ClipPropertiesEditor: View {
        @ObservedObject var clip: EditingView.Clip
        let commandManager: CommandManager
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        
        /// Snapshot taken when a slider drag / field edit begins, so the whole gesture is one undo step.
        @State private var propertiesBefore: EditingView.VideoProperties?
        @State private var keysBefore: EditingView.AnimatedProperty?
        
        /// Animation packs sheet; `registryVersion` bumps when a pack is imported / removed so the
        /// pickers below re-read the animation registry.
        @State private var showAnimationPacks = false
        @State private var registryVersion = 0
        
        private var isVisual: Bool { clip.type == .video || clip.type == .image || clip.type == .text }
        private var hasAudio: Bool { clip.type == .video || clip.type == .audio }
        
        var body: some View {
            VStack(spacing: 12) {
                
                SectionTitle(text: "Clip")
                
                // Trim — only meaningful for media with a source duration.
                if clip.type == .video || clip.type == .audio {
                    NumberField(label: "Start trim", value: trimBinding(start: true)) { onChanged() }
                    NumberField(label: "End trim", value: trimBinding(start: false)) { onChanged() }
                }
                HStack {
                    Text("Duration").font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).frame(width: 80, alignment: .leading)
                    Text(String(format: "%.2fs", clip.duration)).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Text(String(format: "of %.2fs", clip.originalDuration)).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
                
                if isVisual {
                    SectionTitle(text: "Transform")
                    field("Position X", \.valuePosX)
                    field("Position Y", \.valuePosY)
                    field("Rotation", \.valueRot)
                    field("Scale X", \.valueScaleX)
                    field("Scale Y", \.valueScaleY)
                    field("Pivot X", \.valuePivotX)
                    field("Pivot Y", \.valuePivotY)
                    
                    SectionTitle(text: "Look")
                    slider("Opacity", \.valueOpacity, 0...1, reset: 1)
                    slider("Saturation", \.valueSaturation, 0...3, reset: 1)
                    slider("Brightness", \.valueBrightness, -10...10, reset: 0)
                    slider("Temperature", \.valueTemperature, 1000...12000, reset: 6500)
                    field("Hue", \.valueHue)
                }
                
                if clip.type == .video || clip.type == .audio {
                    SectionTitle(text: "Playback")
                    slider("Speed", \.valueSpeed, 0.1...4, reset: 1)
                    field("Volume", \.valueVolume)
                    toggle("Mute audio", clip.isMute) { $0.isMute = $1 }
                    if clip.type == .video {
                        toggle("Reverse", clip.isReverse) { $0.isReverse = $1 }
                    }
                }
                
                SectionTitle(text: "Template")
                toggle("Lock media for template", clip.isLockedForTemplate) { $0.isLockedForTemplate = $1 }
                
                if isVisual {
                    SectionTitle(text: "Animation")
                    animationRow("In", \.inAnimation, .in)
                    animationRow("Out", \.outAnimation, .out)
                    Button { showAnimationPacks = true } label: {
                        Label("Animation packs…", systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.mdPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    
                    SectionTitle(text: "Keyframes (\(clip.keyframes.keyframes.count))")
                    keyframeList
                }
            }
            .sheet(isPresented: $showAnimationPacks) {
                AnimationPackSheet {
                    registryVersion += 1     // pickers re-read the registry
                    onChanged()              // the preview re-renders with what is installed now
                }
            }
        }
        
        // MARK: Property helpers
        
        private func beginEdit() {
            if propertiesBefore == nil {
                propertiesBefore = clip.videoProperties
                keysBefore = clip.keyframes
            }
        }
        
        /// One undo step for a whole slider drag / field edit: the static values and the keyframes together.
        private func endEdit() {
            guard let beforeProps = propertiesBefore, let beforeKeys = keysBefore else { return }
            propertiesBefore = nil
            keysBefore = nil
            let afterProps = clip.videoProperties, afterKeys = clip.keyframes
            guard beforeProps != afterProps || beforeKeys != afterKeys else { return }
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Change properties: \(clip.clipName)",
                undo: { target.videoProperties = beforeProps; target.keyframes = beforeKeys; onChanged() },
                redo: { target.videoProperties = afterProps; target.keyframes = afterKeys; onChanged() }
            ))
            onChanged()
        }
        
        // MARK: Per-property keyframes
        //
        // A property with keyframes shows (and edits) its value AT THE PLAYHEAD: typing or dragging adds a
        // keyframe for that property there, or changes the one that is there. A property without keyframes
        // is edited as before. The diamond beside each row turns the property's animation on at the
        // playhead, or takes its keyframe there off (when it was the last one, the property stays at that value).
        
        /// Seconds into the clip the playhead is at, kept inside the clip.
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        
        private func currentValue(_ type: EditingView.VideoProperties.ValueType,
                                  _ kp: WritableKeyPath<EditingView.VideoProperties, Float>) -> Float {
            clip.keyframes.isAnimated(type)
                ? clip.keyframes.value(for: type, base: clip.videoProperties, clipStartTime: clip.startTime,
                                       at: clip.startTime + localTime)
                : clip.videoProperties[keyPath: kp]
        }
        
        private func writeValue(_ type: EditingView.VideoProperties.ValueType,
                                _ kp: WritableKeyPath<EditingView.VideoProperties, Float>, _ newValue: Float) {
            if clip.keyframes.isAnimated(type) {
                clip.keyframes.setKey(type, atLocal: localTime, value: newValue, base: clip.videoProperties,
                                      clipStartTime: clip.startTime, frameRate: frameRate)
            } else {
                clip.videoProperties[keyPath: kp] = newValue
            }
        }
        
        private func keyMode(_ type: EditingView.VideoProperties.ValueType) -> KeyDiamond.Mode {
            guard clip.keyframes.isAnimated(type) else { return .off }
            return clip.keyframes.keyframeIndex(atLocal: localTime, animating: type) != nil ? .onKey : .animated
        }
        
        private func toggleKey(_ type: EditingView.VideoProperties.ValueType,
                               _ kp: WritableKeyPath<EditingView.VideoProperties, Float>) {
            guard playheadInsideClip else { return }
            let beforeProps = clip.videoProperties, beforeKeys = clip.keyframes
            var props = beforeProps, keys = beforeKeys
            if keys.keyframeIndex(atLocal: localTime, animating: type) != nil {
                if let removed = keys.removeKey(type, atLocal: localTime), !keys.isAnimated(type) {
                    props.setValue(removed, type)     // no longer animated: stays where it was
                }
            } else {
                keys.setKey(type, atLocal: localTime, value: currentValue(type, kp), base: beforeProps,
                            clipStartTime: clip.startTime, frameRate: frameRate)
            }
            guard props != beforeProps || keys != beforeKeys else { return }
            clip.videoProperties = props
            clip.keyframes = keys
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Keyframe \(EditingView.VideoProperties.displayName(for: type)): \(clip.clipName)",
                undo: { target.videoProperties = beforeProps; target.keyframes = beforeKeys; onChanged() },
                redo: { target.videoProperties = props; target.keyframes = keys; onChanged() }
            ))
            onChanged()
        }
        
        /// A property row with its keyframe diamond.
        @ViewBuilder
        private func keyedRow<Content: View>(_ type: EditingView.VideoProperties.ValueType?,
                                             _ kp: WritableKeyPath<EditingView.VideoProperties, Float>,
                                             @ViewBuilder _ content: () -> Content) -> some View {
            HStack(spacing: 4) {
                content()
                if let type {
                    KeyDiamond(mode: keyMode(type), enabled: playheadInsideClip) { toggleKey(type, kp) }
                }
            }
        }
        
        private func binding(_ type: EditingView.VideoProperties.ValueType,
                              _ kp: WritableKeyPath<EditingView.VideoProperties, Float>) -> Binding<Float> {
            Binding(get: { currentValue(type, kp) }, set: { writeValue(type, kp, $0) })
        }
        
        private func field(_ label: String, _ kp: WritableKeyPath<EditingView.VideoProperties, Float>) -> some View {
            let type = EditingView.VideoProperties.channel(for: kp)
            return keyedRow(type, kp) {
                NumberField(label: label, value: Binding(
                    get: { type.map { currentValue($0, kp) } ?? clip.videoProperties[keyPath: kp] },
                    set: { newValue in
                        beginEdit()
                        if let type { writeValue(type, kp, newValue) } else { clip.videoProperties[keyPath: kp] = newValue }
                    }
                )) { endEdit() }
            }
        }
        
        private func slider(_ label: String, _ kp: WritableKeyPath<EditingView.VideoProperties, Float>,
                            _ range: ClosedRange<Float>, reset: Float) -> some View {
            let type = EditingView.VideoProperties.channel(for: kp)
            return keyedRow(type, kp) {
                PropertySlider(
                    label: label,
                    value: Binding(
                        get: { type.map { currentValue($0, kp) } ?? clip.videoProperties[keyPath: kp] },
                        set: { newValue in
                            if let type { writeValue(type, kp, newValue) } else { clip.videoProperties[keyPath: kp] = newValue }
                        }),
                    range: range, resetTo: reset,
                    onEditingBegan: beginEdit, onEditingEnded: endEdit)
            }
        }
        
        private func trimBinding(start: Bool) -> Binding<Float> {
            Binding(
                get: { start ? clip.startClipTrim : clip.endClipTrim },
                set: { newValue in
                    let maxTrim = max(0, clip.originalDuration - (start ? clip.endClipTrim : clip.startClipTrim) - EditingView.minimumKeyframeSpacing)
                    let clamped = min(max(0, newValue), maxTrim)
                    let oldStart = clip.startClipTrim, oldEnd = clip.endClipTrim, oldDur = clip.duration
                    if start { clip.setStartClipTrim(clamped) } else { clip.setEndClipTrim(clamped) }
                    let newStart = clip.startClipTrim, newEnd = clip.endClipTrim, newDur = clip.duration
                    let target = clip
                    // Execute pushes onto the undo stack; state is already applied so redo just re-applies it.
                    commandManager.execute(GenericCommand(
                        description: "Trim: \(clip.clipName)",
                        undo: { target.startClipTrim = oldStart; target.endClipTrim = oldEnd; target.duration = oldDur; onChanged() },
                        redo: { target.startClipTrim = newStart; target.endClipTrim = newEnd; target.duration = newDur; onChanged() }
                    ))
                }
            )
        }
        
        private func toggle(_ label: String, _ current: Bool, _ apply: @escaping (EditingView.Clip, Bool) -> Void) -> some View {
            Toggle(label, isOn: Binding(
                get: { current },
                set: { newValue in
                    let target = clip
                    commandManager.execute(GenericCommand(
                        description: "\(label): \(clip.clipName)",
                        undo: { apply(target, current); onChanged() },
                        redo: { apply(target, newValue); onChanged() }
                    ))
                }
            ))
            .font(.system(size: 13))
            .foregroundColor(.white)
            .tint(Color.mdPrimary)
        }
        
        /// One animation row (Android: AnimationPicker): a type menu + a duration field for one direction.
        /// The choices come from the ClipAnimationLoader registry ("None" plus every installed animation
        /// of this direction) and show each animation's display name while storing its id in
        /// `AnimationClip.type`. Picking a real animation by hand also fills the duration with that
        /// animation's own default; showing a clip never does. A saved id that isn't installed stays
        /// selectable (and is kept) as "<id> (not installed)".
        private func animationRow(_ label: String,
                                  _ kp: ReferenceWritableKeyPath<EditingView.Clip, EditingView.AnimationClip>,
                                  _ direction: ClipAnimation.Direction) -> some View {
            _ = registryVersion      // re-read the registry after packs change
            ClipAnimationStore.loadAll()
            let current = clip[keyPath: kp].type
            let installed = ClipAnimationLoader.list(direction)
            let isNone = current.isEmpty || current == "none"
            let currentName = isNone ? "None"
                : (installed.first(where: { $0.id == current })?.name ?? "\(current) (not installed)")
            
            return HStack {
                Text("\(label) animation").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)
                Menu {
                    Button("None") { setAnimation(kp, id: "none") }
                    ForEach(installed, id: \.id) { animation in
                        Button(animation.name) { setAnimation(kp, id: animation.id) }
                    }
                    if !isNone, !installed.contains(where: { $0.id == current }) {
                        Button("\(current) (not installed)") { setAnimation(kp, id: current) }
                    }
                } label: {
                    HStack {
                        Text(currentName)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }
                NumberField(label: "", value: Binding(
                    get: { clip[keyPath: kp].duration },
                    set: { clip[keyPath: kp].duration = max(0, $0) }
                )) { onChanged() }
                .frame(width: 70)
            }
        }
        
        private func setAnimation(_ kp: ReferenceWritableKeyPath<EditingView.Clip, EditingView.AnimationClip>, id: String) {
            guard clip[keyPath: kp].type != id else { return }
            clip[keyPath: kp].type = id
            if let animation = ClipAnimationLoader.get(id) {
                clip[keyPath: kp].duration = animation.defaultDuration
            }
            onChanged()
        }
        
        // MARK: Keyframes
        
        @ViewBuilder private var keyframeList: some View {
            if clip.keyframes.keyframes.isEmpty {
                Text("No keyframes. Tap the diamond beside a property to animate just that property, or use the Keyframe button in the toolbar to key everything at the playhead.")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(clip.keyframes.keyframes.enumerated()), id: \.offset) { index, key in
                    HStack {
                        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundColor(.white)
                        Text(String(format: "%.2fs", key.time))
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                            .frame(width: 60, alignment: .leading)
                        Text(key.channelSummary)
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                            .frame(maxWidth: 84, alignment: .leading)
                        Picker("Easing", selection: Binding(
                            get: { clip.keyframes.keyframes[safe: index]?.easing ?? .none },
                            set: { newEasing in setEasing(index, newEasing) }
                        )) {
                            ForEach(EditingView.EasingType.allCases, id: \.self) { e in Text(e.displayName).tag(e) }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.mdPrimary)
                        Spacer()
                        Button(role: .destructive) { deleteKeyframe(index) } label: {
                            Image(systemName: "trash").font(.system(size: 13))
                        }
                    }
                }
                Button("Clear all keyframes", role: .destructive) { clearAll() }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        
        private func setEasing(_ index: Int, _ easing: EditingView.EasingType) {
            guard clip.keyframes.keyframes.indices.contains(index) else { return }
            let old = clip.keyframes.keyframes[index].easing
            guard old != easing else { return }
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Easing: \(clip.clipName)",
                undo: { if target.keyframes.keyframes.indices.contains(index) { target.keyframes.keyframes[index].easing = old }; onChanged() },
                redo: { if target.keyframes.keyframes.indices.contains(index) { target.keyframes.keyframes[index].easing = easing }; onChanged() }
            ))
        }
        
        private func deleteKeyframe(_ index: Int) {
            guard clip.keyframes.keyframes.indices.contains(index) else { return }
            let beforeKeys = clip.keyframes, beforeProps = clip.videoProperties
            var afterKeys = beforeKeys
            let removed = afterKeys.keyframes.remove(at: index)
            // A property that loses its last keyframe stays at the value that keyframe gave it.
            var afterProps = beforeProps
            for type in removed.channelList where !afterKeys.isAnimated(type) {
                afterProps.setValue(removed.value.value(type), type)
            }
            clip.keyframes = afterKeys
            clip.videoProperties = afterProps
            let target = clip
            commandManager.execute(GenericCommand(description: "Remove keyframe: \(clip.clipName)",
                undo: { target.keyframes = beforeKeys; target.videoProperties = beforeProps; onChanged() },
                redo: { target.keyframes = afterKeys; target.videoProperties = afterProps; onChanged() }))
            onChanged()
        }
        
        private func clearAll() {
            let before = clip.keyframes
            let target = clip
            commandManager.execute(GenericCommand(description: "Clear keyframes: \(clip.clipName)",
                undo: { target.keyframes = before; onChanged() },
                redo: { target.keyframes = EditingView.AnimatedProperty(); onChanged() }))
        }
    }
}

// MARK: - Keyframe diamond

extension EditingView {
    /// The button beside a property: hollow = not animated, half = animated but no keyframe at the
    /// playhead, filled = a keyframe of this property sits at the playhead.
    struct KeyDiamond: View {
        enum Mode { case off, animated, onKey }
        let mode: Mode
        let enabled: Bool
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                Image(systemName: mode == .onKey ? "diamond.fill" : (mode == .animated ? "diamond.lefthalf.filled" : "diamond"))
                    .font(.system(size: 13))
                    .foregroundColor(mode == .off ? Color.white.opacity(0.5) : Color.mdPrimary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.3)
        }
    }
}

// MARK: - Small helpers

extension EditingView.EasingType {
    /// "EASE_IN_OUT_SINE" -> "Ease In Out Sine"
    var displayName: String {
        rawValue.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
