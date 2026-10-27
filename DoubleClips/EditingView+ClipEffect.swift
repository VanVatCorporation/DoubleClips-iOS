import SwiftUI
import CoreImage

// MARK: - Inner clip effect (Clip.clipEffect)
//
// Android's "Effect" section of the clip editor (ClipEffectPicker + OpenGLEdit.ownEffectOf): an effect that touches
// THIS clip only, as opposed to an effect clip (EditingView+Effects.swift), which is an adjustment layer over
// every track drawn before it.
//
//   - The clip is drawn alone onto a transparent canvas-sized layer, the effect filters that layer, and the
//     result goes onto the frame like any other picture. Whatever is below the clip stays untouched, and the
//     clip's own transform, mask, animations and blend mode all happen before / after as usual.
//   - Same styles (animations/effects/*.json), same live tile grid and the same strength (with its keyframe
//     diamond, the `strength` keyframe channel) as an effect clip. A clip never has both, so they share the channel.
//   - `clipEffect` is the same JSON object Android writes: { type, style, duration, offset, params: { intensity } }.
//     `offset` is seconds AFTER THE CLIP'S START (not the timeline), `duration` the length of that window,
//     0 = "until the clip's end", so it keeps following the clip when it is trimmed or stretched.
//   - Works on video, image and text clips, in a transition (each side keeps its own effect) and in export, because
//     it lives in the one compositor both use.

extension EditingView {
    
    /// What the render thread needs of a clip's own effect (value types only).
    struct OwnEffect: Equatable {
        var style: String
        /// Seconds after the clip's start.
        var offset: Float
        /// Window length in seconds; <= 0 = until the clip's end.
        var duration: Float
        /// The static strength (a keyframed strength replaces it).
        var intensity: Float
    }
}

extension EditingView.Clip {
    
    /// The clip's own effect as a render snapshot; nil = none (or "none").
    var ownEffect: EditingView.OwnEffect? {
        guard let effect = clipEffect else { return nil }
        let style = effect.style.trimmingCharacters(in: .whitespaces)
        guard !style.isEmpty, style.lowercased() != "none" else { return nil }
        return EditingView.OwnEffect(style: style, offset: Float(max(effect.offset, 0)),
                                     duration: Float(max(effect.duration, 0)), intensity: effect.intensity)
    }
    
    /// Splitting a clip at `local` seconds: the effect window is cut with the clip, so the right half doesn't start the
    /// effect over (Android copies it to both halves unchanged). Returns the effect of the left and of the right half.
    static func splitClipEffect(_ effect: EditingView.EffectTemplate?, atLocal local: Double)
        -> (left: EditingView.EffectTemplate?, right: EditingView.EffectTemplate?) {
        guard let effect else { return (nil, nil) }
        let eps = 0.0005
        let start = max(effect.offset, 0)
        let untilEnd = effect.duration <= 0
        let end = start + effect.duration                    // only meaningful when !untilEnd
        
        // Left half: the part of the window before the cut.
        var left: EditingView.EffectTemplate? = effect
        if start >= local - eps {
            left = nil                                       // the window opens at or after the cut
        } else if untilEnd || end >= local - eps {
            left?.duration = 0                               // it reaches the end of the half: keep following it
        }
        
        // Right half: the part after the cut, measured from the cut.
        var right: EditingView.EffectTemplate? = effect
        if !untilEnd && end <= local + eps {
            right = nil                                      // the window closed before the cut
        } else {
            let newStart = max(start - local, 0)
            right?.offset = newStart
            right?.duration = untilEnd ? 0 : (end - local) - newStart
        }
        return (left, right)
    }
}

// MARK: - Compositor hook

extension EditingView.ClipCompositor {
    
    /// Filters one clip's picture with the clip's own effect, when its window is open at `time`. `picture` is whatever
    /// `place()` made of the clip (any extent); it goes onto a transparent canvas-sized layer first, so the effect sees
    /// the clip alone and edge clamping can't smear its borders over the canvas.
    static func applyOwnEffect(to picture: CIImage, layer: EditingView.RenderLayer,
                               live: EditingView.LiveClipState?, time: Float, canvas: CGRect) -> CIImage {
        guard let own = live?.ownEffect ?? layer.ownEffect else { return picture }
        
        // The window, inside the clip.
        let room = max(layer.duration - own.offset, 0)
        let length = own.duration > 0 ? min(own.duration, room) : room
        guard length > 0 else { return picture }
        var local = time - layer.startTime - own.offset
        // The picture also shows a little outside the clip while it takes part in a transition: an effect that
        // starts with the clip / runs to its end keeps going there instead of popping off.
        if local < 0 { if own.offset <= 0.0005 { local = 0 } else { return picture } }
        if local >= length { if own.duration <= 0 { local = length } else { return picture } }
        
        let keyframes = live?.keyframes ?? layer.keyframes
        var strength = own.intensity
        if keyframes.isAnimated(.strength) {
            var base = layer.baseProperties
            base.valueStrength = own.intensity
            strength = keyframes.value(for: .strength, base: base, clipStartTime: layer.startTime, at: time)
        }
        
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let isolated = picture.composited(over: clear).cropped(to: canvas)
        let progress = length > 0 ? min(max(local / length, 0), 1) : 0
        return EffectRenderer.apply(style: own.style, intensity: CGFloat(max(strength, 0)), to: isolated,
                                    progress: CGFloat(progress), time: time, elapsed: local, canvas: canvas)
            .cropped(to: canvas)
    }
}

// MARK: - Picker sheet (None + every style as a live tile)

extension EditingView {
    
    struct ClipEffectPickerSheet: View {
        /// The canonical key of the current style; nil = none.
        let current: String?
        let onPick: (String?) -> Void
        @Environment(\.dismiss) private var dismiss
        
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                                    count: Constants.STYLE_GRID_COLUMNS)
        
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Clip effect").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").foregroundColor(Color.mdPrimary).font(.system(size: 18, weight: .bold))
                    }
                }
                .padding()
                .background(Color(hex: "#1A1A1A"))
                
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        noneTile
                        ForEach(EffectCatalog.styles) { style in
                            tile(title: style.title, author: style.author, selected: current == style.key) {
                                EffectPreviewTile(styleKey: style.key, intensity: 1)
                            } action: { onPick(style.key); dismiss() }
                        }
                    }
                    .padding()
                }
                .background(Color(hex: "#111111"))
            }
            .background(Color(hex: "#111111"))
        }
        
        private var noneTile: some View {
            tile(title: "None", author: "No effect", selected: current == nil) {
                ZStack {
                    Color(hex: "#26262B")
                    Image(systemName: "nosign").font(.system(size: 26)).foregroundColor(.white.opacity(0.55))
                }
            } action: { onPick(nil); dismiss() }
        }
        
        private func tile<Preview: View>(title: String, author: String, selected: Bool,
                                         @ViewBuilder preview: () -> Preview,
                                         action: @escaping () -> Void) -> some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 4) {
                    preview()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color.mdPrimary)
                                    .background(Circle().fill(Color.white).padding(3))
                                    .padding(5)
                            }
                        }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(author)
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Editor section (clip and text editors)

extension EditingView {
    
    /// "EFFECT" block of the clip editor: the style (opens the grid), its strength with a keyframe diamond, and the window
    /// inside the clip where it shows. Edits go through the CommandManager, one undo step each.
    struct ClipEffectSection: View {
        @ObservedObject var clip: EditingView.Clip
        let commandManager: CommandManager
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        
        @State private var showPicker = false
        /// Snapshot at the start of a strength drag (one undo step for the whole drag).
        @State private var dragStart: (effect: EffectTemplate?, keys: AnimatedProperty)?
        /// The value the slider shows while it is being dragged.
        @State private var dragValue: Float?
        
        private var effect: EffectTemplate? {
            guard clip.ownEffect != nil else { return nil }
            return clip.clipEffect
        }
        private var styleKey: String? { effect.map { EffectCatalog.canonicalKey($0.style) } }
        private var catalogStyle: EffectCatalog.Style? { effect.flatMap { EffectCatalog.style(for: $0.style) } }
        
        // MARK: Body
        
        var body: some View {
            VStack(spacing: 10) {
                HStack {
                    Text("Effect").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                        .frame(width: 80, alignment: .leading)
                    Button { showPicker = true } label: {
                        HStack {
                            Text(currentName).font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "square.grid.2x2").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Color.white.opacity(0.08)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                if let effect {
                    if let label = catalogStyle?.intensityLabel {
                        HStack(spacing: 4) {
                            PropertySlider(
                                label: label,
                                value: Binding(get: { dragValue ?? strengthNow }, set: { liveStrength($0) }),
                                range: catalogStyle?.intensityRange ?? 0.2...3,
                                resetTo: 1,
                                onEditingBegan: beginStrength,
                                onEditingEnded: endStrength)
                            KeyDiamond(mode: strengthKeyMode, enabled: playheadInsideClip) { toggleStrengthKey() }
                        }
                    }
                    NumberField(label: "Start", value: Binding(get: { Float(effect.offset) }, set: { setWindow(start: $0) })) { onChanged() }
                    NumberField(label: "Length", value: Binding(get: { Float(windowLength) }, set: { setWindow(length: $0) })) { onChanged() }
                    if catalogStyle == nil {
                        Text("This effect (\"\(effect.style)\") isn't known to this version. It is kept in the project and drawn by the platform that made it.")
                            .font(.system(size: 11)).foregroundColor(.orange.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Start and Length are seconds inside this clip. Only this clip is filtered; an effect clip filters every track drawn before it.")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sheet(isPresented: $showPicker) {
                ClipEffectPickerSheet(current: styleKey, onPick: { setStyle($0) })
                    .presentationDetents([.medium, .large])
            }
        }
        
        private var currentName: String {
            guard let effect else { return "None" }
            return catalogStyle?.title ?? "\(effect.style) (not installed)"
        }
        
        /// The shown length: the window's own, or what is left of the clip when it runs to the end.
        private var windowLength: Double {
            guard let effect else { return 0 }
            let room = max(Double(clip.duration) - max(effect.offset, 0), 0)
            return effect.duration > 0 ? min(effect.duration, room) : room
        }
        
        // MARK: Style
        
        /// nil = "None". A new style starts at its own default strength; "None" takes the strength keyframes off too.
        private func setStyle(_ key: String?) {
            let effectBefore = clip.clipEffect, keysBefore = clip.keyframes
            var effectAfter: EffectTemplate?
            var keysAfter = keysBefore
            if let key {
                guard styleKey != key else { return }
                var next = clip.clipEffect ?? EffectTemplate(type: nil, style: key, duration: 0, offset: 0)
                next.style = key
                next.intensity = 1
                effectAfter = next
            } else {
                guard clip.clipEffect != nil else { return }
                effectAfter = nil
                while keysAfter.isAnimated(.strength),
                      let time = keysAfter.keyframes.first(where: { $0.animates(.strength) })?.time,
                      keysAfter.removeKey(.strength, atLocal: time) != nil { }
            }
            clip.clipEffect = effectAfter
            clip.keyframes = keysAfter
            let target = clip
            let changed = onChanged
            let (effectNow, keysNow) = (effectAfter, keysAfter)
            commandManager.execute(GenericCommand(description: "Clip effect: \(clip.clipName)",
                undo: { target.clipEffect = effectBefore; target.keyframes = keysBefore; changed() },
                redo: { target.clipEffect = effectNow; target.keyframes = keysNow; changed() }))
            changed()
        }
        
        // MARK: Window
        
        /// Start / length typed in seconds. A window that reaches the clip's end is stored as length 0 ("until the end").
        private func setWindow(start: Float? = nil, length: Float? = nil) {
            guard var next = clip.clipEffect else { return }
            let before = clip.clipEffect
            var newStart = start.map { Double($0) } ?? max(next.offset, 0)
            if newStart < 0 || newStart.isNaN { newStart = 0 }
            if newStart >= Double(clip.duration) { newStart = 0 }              // it would never show: back to the start
            let room = Double(clip.duration) - newStart
            let wanted = length.map { Double($0) } ?? (next.duration > 0 ? next.duration : room)
            next.offset = newStart
            next.duration = (wanted <= 0 || wanted >= room - 0.001) ? 0 : wanted
            guard next.offset != before?.offset || next.duration != before?.duration else { return }
            clip.clipEffect = next
            let target = clip
            let changed = onChanged
            let after = next
            commandManager.execute(GenericCommand(description: "Clip effect window: \(clip.clipName)",
                undo: { target.clipEffect = before; changed() },
                redo: { target.clipEffect = after; changed() }))
        }
        
        // MARK: Strength and its keyframes
        
        private var localTime: Float { min(max(playhead - clip.startTime, 0), clip.duration) }
        private var playheadInsideClip: Bool {
            playhead >= clip.startTime - 0.001 && playhead <= clip.startTime + clip.duration + 0.001
        }
        private var strengthAnimated: Bool { clip.keyframes.isAnimated(.strength) }
        
        private var staticStrength: Float { clip.clipEffect?.intensity ?? 1 }
        
        /// The clip's properties with the static strength in the strength slot (what keyframe maths falls back to).
        private var strengthBase: VideoProperties {
            var properties = clip.videoProperties
            properties.valueStrength = staticStrength
            return properties
        }
        
        private var strengthNow: Float {
            strengthAnimated
                ? clip.keyframes.value(for: .strength, base: strengthBase, clipStartTime: clip.startTime,
                                       at: clip.startTime + localTime)
                : staticStrength
        }
        
        private var strengthKeyMode: KeyDiamond.Mode {
            guard strengthAnimated else { return .off }
            return clip.keyframes.keyframeIndex(atLocal: localTime, animating: .strength) != nil ? .onKey : .animated
        }
        
        private func beginStrength() {
            if dragStart == nil { dragStart = (clip.clipEffect, clip.keyframes) }
        }
        
        /// The slider moves: the preview follows through LiveOverrides (no player rebuild). Once the strength is animated the
        /// slider edits the value at the playhead (adding a key there when there is none), like every other property.
        private func liveStrength(_ value: Float) {
            beginStrength()
            dragValue = value
            let live = LiveOverrides.shared.state(for: clip.id)
            var keys = live?.keyframes ?? clip.keyframes
            guard var own = live?.ownEffect ?? clip.ownEffect else { return }
            if keys.isAnimated(.strength) {
                keys.setKey(.strength, atLocal: localTime, value: value, base: strengthBase,
                            clipStartTime: clip.startTime, frameRate: frameRate)
            } else {
                own.intensity = value
            }
            LiveOverrides.shared.set(LiveClipState(properties: clip.videoProperties, keyframes: keys, ownEffect: own), for: clip.id)
            MaskEditState.shared.refresh?()
        }
        
        private func endStrength() {
            defer { dragValue = nil }
            guard let start = dragStart else { return }
            dragStart = nil
            let live = LiveOverrides.shared.state(for: clip.id)
            LiveOverrides.shared.clear(clip.id)
            guard let live, let own = live.ownEffect, var next = clip.clipEffect else { return }
            next.intensity = own.intensity
            let keysAfter = live.keyframes
            guard abs(next.intensity - (start.effect?.intensity ?? 1)) > 0.0005 || keysAfter != start.keys else {
                MaskEditState.shared.refresh?()
                return
            }
            clip.clipEffect = next
            clip.keyframes = keysAfter
            let target = clip
            let changed = onChanged
            let after = next
            let (effectBefore, keysBefore) = (start.effect, start.keys)
            commandManager.execute(GenericCommand(description: "Clip effect strength: \(clip.clipName)",
                undo: { target.clipEffect = effectBefore; target.keyframes = keysBefore; changed() },
                redo: { target.clipEffect = after; target.keyframes = keysAfter; changed() }))
            changed()
        }
        
        /// The diamond: animate the strength from here on, or take the keyframe at the playhead off (the last one leaves the
        /// strength where it was).
        private func toggleStrengthKey() {
            guard playheadInsideClip, var next = clip.clipEffect else { return }
            let keysBefore = clip.keyframes, effectBefore = clip.clipEffect
            var keys = keysBefore
            if keys.keyframeIndex(atLocal: localTime, animating: .strength) != nil {
                if let removed = keys.removeKey(.strength, atLocal: localTime), !keys.isAnimated(.strength) {
                    next.intensity = removed
                }
            } else {
                keys.setKey(.strength, atLocal: localTime, value: strengthNow, base: strengthBase,
                            clipStartTime: clip.startTime, frameRate: frameRate)
            }
            guard keys != keysBefore || abs(next.intensity - (effectBefore?.intensity ?? 1)) > 0.0005 else { return }
            clip.keyframes = keys
            clip.clipEffect = next
            let target = clip
            let changed = onChanged
            let after = next
            commandManager.execute(GenericCommand(description: "Keyframe Strength: \(clip.clipName)",
                undo: { target.keyframes = keysBefore; target.clipEffect = effectBefore; changed() },
                redo: { target.keyframes = keys; target.clipEffect = after; changed() }))
            changed()
        }
    }
}
