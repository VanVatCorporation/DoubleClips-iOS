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
                    slider("Brightness", \.valueBrightness, -1...1, reset: 0)
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
                    animationRow("In", \.inAnimation)
                    
                    SectionTitle(text: "Keyframes (\(clip.keyframes.keyframes.count))")
                    keyframeList
                }
            }
        }
        
        // MARK: Property helpers
        
        private func beginEdit() {
            if propertiesBefore == nil { propertiesBefore = clip.videoProperties }
        }
        
        private func endEdit() {
            guard let before = propertiesBefore else { return }
            propertiesBefore = nil
            let after = clip.videoProperties
            guard before != after else { return }
            // Editing a value while the playhead sits on a keyframe edits that keyframe too,
            // otherwise the change would be overridden by the keyframe interpolation.
            let idxBefore = keyframeIndexAtPlayhead()
            let keysBefore = clip.keyframes
            if let idx = idxBefore { clip.keyframes.keyframes[idx].value = after }
            let keysAfter = clip.keyframes
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Change properties: \(clip.clipName)",
                undo: { target.videoProperties = before; target.keyframes = keysBefore; onChanged() },
                redo: { target.videoProperties = after; target.keyframes = keysAfter; onChanged() }
            ))
            onChanged()
        }
        
        private func keyframeIndexAtPlayhead() -> Int? {
            clip.keyframes.keyframes.firstIndex { abs(($0.time + clip.startTime) - playhead) <= EditingView.minimumKeyframeSpacing }
        }
        
        private func binding(_ kp: WritableKeyPath<EditingView.VideoProperties, Float>) -> Binding<Float> {
            Binding(get: { clip.videoProperties[keyPath: kp] }, set: { clip.videoProperties[keyPath: kp] = $0 })
        }
        
        private func field(_ label: String, _ kp: WritableKeyPath<EditingView.VideoProperties, Float>) -> some View {
            NumberField(label: label, value: Binding(
                get: { clip.videoProperties[keyPath: kp] },
                set: { newValue in beginEdit(); clip.videoProperties[keyPath: kp] = newValue }
            )) { endEdit() }
        }
        
        private func slider(_ label: String, _ kp: WritableKeyPath<EditingView.VideoProperties, Float>,
                            _ range: ClosedRange<Float>, reset: Float) -> some View {
            PropertySlider(label: label, value: binding(kp), range: range, resetTo: reset,
                           onEditingBegan: beginEdit, onEditingEnded: endEdit)
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
        
        private func animationRow(_ label: String, _ kp: ReferenceWritableKeyPath<EditingView.Clip, EditingView.AnimationClip>) -> some View {
            HStack {
                Text("\(label) type").font(.system(size: 12)).foregroundColor(.white.opacity(0.8)).frame(width: 80, alignment: .leading)
                Picker("", selection: Binding(
                    get: { clip[keyPath: kp].type },
                    set: { clip[keyPath: kp].type = $0; onChanged() }
                )) {
                    Text("none").tag("none")
                    Text("unfold").tag("unfold")
                }
                .pickerStyle(.segmented)
                NumberField(label: "", value: Binding(
                    get: { clip[keyPath: kp].duration },
                    set: { clip[keyPath: kp].duration = max(0, $0) }
                )) { onChanged() }
                .frame(width: 70)
            }
        }
        
        // MARK: Keyframes
        
        @ViewBuilder private var keyframeList: some View {
            if clip.keyframes.keyframes.isEmpty {
                Text("No keyframes. Use the Keyframe button in the toolbar to add one at the playhead.")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(clip.keyframes.keyframes.enumerated()), id: \.offset) { index, key in
                    HStack {
                        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundColor(.white)
                        Text(String(format: "%.2fs", key.time))
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                            .frame(width: 60, alignment: .leading)
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
            let before = clip.keyframes
            var after = before; after.keyframes.remove(at: index)
            let target = clip
            commandManager.execute(GenericCommand(description: "Remove keyframe: \(clip.clipName)",
                undo: { target.keyframes = before; onChanged() },
                redo: { target.keyframes = after; onChanged() }))
        }
        
        private func clearAll() {
            let before = clip.keyframes
            let target = clip
            commandManager.execute(GenericCommand(description: "Clear keyframes: \(clip.clipName)",
                undo: { target.keyframes = before; onChanged() },
                redo: { target.keyframes = EditingView.AnimatedProperty(); onChanged() }))
        }
    }
    
    // MARK: - Text clip editor (TextEditSpecificAreaScreen)
    
    struct TextClipEditor: View {
        @ObservedObject var clip: EditingView.Clip
        let commandManager: CommandManager
        let onChanged: () -> Void
        @State private var draft: String = ""
        @State private var sizeBefore: Float?
        
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("TEXT").font(.system(size: 11, weight: .bold)).foregroundColor(Color.mdPrimary)
                TextField("Text", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .onSubmit(commitText)
                    .onChange(of: draft) { _ in /* live-edit the model, undo registered on commit */ clip.textContent = draft }
                
                PropertySlider(
                    label: "Font size",
                    value: Binding(get: { clip.fontSize ?? 30 }, set: { clip.fontSize = $0 }),
                    range: 8...200,
                    resetTo: 30,
                    onEditingBegan: { if sizeBefore == nil { sizeBefore = clip.fontSize ?? 30 } },
                    onEditingEnded: commitSize
                )
            }
            .onAppear { draft = clip.textContent ?? ""; committedText = draft }
            .onDisappear(perform: commitText)
        }
        
        @State private var committedText: String = ""
        
        private func commitText() {
            let old = committedText
            let new = draft
            guard old != new else { return }
            committedText = new
            let target = clip
            commandManager.execute(GenericCommand(description: "Edit text",
                undo: { target.textContent = old; onChanged() },
                redo: { target.textContent = new; onChanged() }))
        }
        
        private func commitSize() {
            guard let before = sizeBefore else { return }
            sizeBefore = nil
            let after = clip.fontSize ?? 30
            guard before != after else { return }
            let target = clip
            commandManager.execute(GenericCommand(description: "Font size",
                undo: { target.fontSize = before; onChanged() },
                redo: { target.fontSize = after; onChanged() }))
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
