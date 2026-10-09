import SwiftUI

// MARK: - Transitions: catalogue, knot UI and editor panel
//
// Android: when two clips on a track touch, a blue knot appears between them (hidden while a clip
// is selected). Tapping it opens the transition editor: style, duration, mode, "apply to all".
// The data lives on the first clip (Clip.endTransition / endTransitionEnabled).
//
// iOS keeps all of that and adds: a style grid with a note on what is drawn exactly, a duration
// slider limited to what fits, a plain-words explanation of the three modes, "Remove",
// "Play transition", and every change is undoable.

// MARK: Catalogue

enum TransitionCatalog {
    struct Style: Identifiable {
        /// The key exactly as Android's FXRegistry stores it (two of its keys really end in a space;
        /// writing them verbatim keeps the Android spinner able to find them).
        let key: String
        let title: String
        var id: String { key }
        var normalized: String { TransitionPlan.normalizedStyle(key) }
        /// Drawn by this app's blend (and by Android's GPU export for the first eight).
        var isDrawn: Bool { key == "none" || EditingView.ClipCompositor.drawnTransitionStyles.contains(normalized) || TransitionStyleLoader.get(normalized) != nil }
    }
    
    /// Android's registry, in a fixed, grouped order (its own spinner order is a HashMap's).
    static let styles: [Style] = [
        Style(key: "none", title: "None"),
        Style(key: "fade", title: "Cross Fade"),
        Style(key: "dissolve", title: "Dissolve"),
        Style(key: "fadeblack", title: "Fade Black"),
        Style(key: "fadewhite", title: "Fade White"),
        Style(key: "fadegrays", title: "Fade Gray"),
        Style(key: "glitchblur", title: "Glitch Blur"),
        Style(key: "wipeleft", title: "Wipe Left"),
        Style(key: "wiperight", title: "Wipe Right"),
        Style(key: "slideleft", title: "Slide Left"),
        Style(key: "slideright", title: "Slide Right"),
        Style(key: "slideup", title: "Slide Up"),
        Style(key: "slidedown", title: "Slide Down"),
        Style(key: "circleopen ", title: "Circle Open"),
        Style(key: "circleclose", title: "Circle Close"),
        Style(key: "radial ", title: "Radial"),
        Style(key: "pixelize", title: "Pixelize"),
        Style(key: "hlslice", title: "Horizontal Left Slice"),
        Style(key: "hrslice", title: "Horizontal Right Slice"),
        Style(key: "vuslice", title: "Vertical Up Slice"),
        Style(key: "vdslice", title: "Vertical Down Slice"),
        Style(key: "hblur", title: "Horizontal Blur"),
        Style(key: "rectcrop", title: "Rect Crop"),
        Style(key: "circlecrop", title: "Circle Crop"),
        Style(key: "distance", title: "Distance"),
        Style(key: "diagtl", title: "Diagonal Top-Left Wipe"),
        Style(key: "diagbl", title: "Diagonal Bottom-Left Wipe"),
        Style(key: "revealup", title: "Reveal Up"),
        Style(key: "custom_expose", title: "Expose [Custom]"),
        Style(key: "custom_two-stage-slide", title: "Two Stage Slide [Custom]"),
        Style(key: "custom_radial-shockwave", title: "Radial Shockwave [Custom]"),
        Style(key: "custom_massive-effect", title: "Massive Effect [Custom]"),
        Style(key: "custom_fake-glass-shatter", title: "Fake Glass Shatter [Custom]")
    ]
    
    static func title(for storedKey: String?) -> String {
        let normalized = TransitionPlan.normalizedStyle(storedKey)
        return styles.first(where: { $0.normalized == normalized })?.title ?? (storedKey ?? "None")
    }
}

extension EditingView.TransitionClip.TransitionMode {
    var title: String {
        switch self {
        case .endFirst: return "End first"
        case .overlap: return "Overlap"
        case .beginSecond: return "Begin second"
        }
    }
    
    var explanation: String {
        switch self {
        case .endFirst: return "The blend finishes right before the cut: the first clip's last moments blend into the second clip's opening footage."
        case .overlap: return "The blend runs up to the cut: the second clip slides in while the first one ends."
        case .beginSecond: return "The blend starts at the cut: the first clip carries on while the second one is already playing."
        }
    }
}

/// What the knot and the editor need to know about a clip that can carry a transition.
enum TransitionEditing {
    
    static func make(a: EditingView.Clip, b: EditingView.Clip) -> EditingView.TransitionClip {
        let d = Constants.TRANSITION_DEFAULT_SECONDS
        let start = b.startTime - d / 2
        return EditingView.TransitionClip(
            trackIndex: a.trackIndex, startTime: start, duration: d,
            effect: EditingView.EffectTemplate(style: "none", duration: Double(d), offset: Double(start)),
            mode: .overlap)
    }
    
    /// Android's knot position fields mirror the cut; keep them in step when duration changes.
    static func normalized(_ t: EditingView.TransitionClip, cut: Float) -> EditingView.TransitionClip {
        var out = t
        out.startTime = cut - out.duration / 2
        out.effect.duration = Double(out.duration)
        out.effect.offset = Double(out.startTime)
        return out
    }
}

// MARK: - Knot

struct TransitionKnotView: View {
    let style: String?
    var body: some View {
        let active = TransitionPlan.normalizedStyle(style) != "none"
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.mdPrimary : Color(hex: "#3A3A3C"))
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(active ? 0.0 : 0.5), lineWidth: 1)
            Image(systemName: "rectangle.2.swap")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: Constants.TRANSITION_KNOT_SIZE, height: Constants.TRANSITION_KNOT_SIZE)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .frame(width: Constants.TRANSITION_KNOT_HIT, height: Constants.TRANSITION_KNOT_HIT)
        .contentShape(Rectangle())
    }
}

// MARK: - Editor panel

extension EditingView {
    
    struct TransitionPanel: View {
        @ObservedObject var clipA: EditingView.Clip
        let clipB: EditingView.Clip
        @ObservedObject var track: EditingView.Track
        let commandManager: CommandManager
        let onChanged: () -> Void
        let onPlay: (Float) -> Void
        let onClose: () -> Void
        
        @State private var durationBefore: Float?
        
        private var transition: EditingView.TransitionClip {
            clipA.endTransition ?? TransitionEditing.make(a: clipA, b: clipB)
        }
        
        private var cut: Float { clipA.startTime + clipA.duration }
        
        private var maxDuration: Float {
            // Never a zero-width slider range, even for a very short clip.
            max(Constants.TRANSITION_MIN_SECONDS + 0.05,
                min(Constants.TRANSITION_MAX_SECONDS,
                    TransitionPlan.maxDuration(mode: transition.mode, a: clipA, b: clipB)))
        }
        
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Transition")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button { onPlay(max(0, windowStart - 0.6)) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .padding(.trailing, 6)
                    Button(action: onClose) {
                        Image(systemName: "checkmark")
                            .foregroundColor(Color.mdPrimary)
                            .font(.system(size: 18, weight: .bold))
                    }
                }
                .padding()
                .background(Color(hex: "#1A1A1A"))
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        styleGrid
                        durationSection
                        modeSection
                        actions
                    }
                    .padding()
                }
                .background(Color(hex: "#111111"))
            }
            .frame(height: Constants.TRANSITION_PANEL_HEIGHT)
            .transition(.move(edge: .bottom))
            .onAppear(perform: ensureTransition)
        }
        
        private var windowStart: Float {
            TransitionPlan.windowRange(mode: transition.mode, cut: cut,
                                       duration: min(transition.duration, maxDuration)).start
        }
        
        // MARK: Sections
        
        private var styleGrid: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("STYLE").font(.system(size: 11, weight: .bold)).foregroundColor(Color.mdPrimary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                         count: Constants.STYLE_GRID_COLUMNS), spacing: 10) {
                    ForEach(TransitionCatalog.styles) { style in
                        let selected = TransitionPlan.normalizedStyle(transition.effect.style) == style.normalized
                        Button { setStyle(style.key) } label: { tile(style, selected: selected) }
                            .buttonStyle(.plain)
                    }
                }
                let current = TransitionPlan.normalizedStyle(transition.effect.style)
                if current != "none",
                   !(TransitionCatalog.styles.first(where: { $0.normalized == current })?.isDrawn ?? false) {
                    Text("Not drawn on iOS yet: this one plays as a cross fade here. The style is kept in the project for Android and desktop.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange.opacity(0.9))
                }
            }
        }
        
        /// One style of the grid: A -> B drawn live halfway (the selected one loops), and its name.
        private func tile(_ style: TransitionCatalog.Style, selected: Bool) -> some View {
            VStack(spacing: 4) {
                TransitionPreviewTile(styleKey: style.key, animating: selected)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1)
                    )
                    .overlay {
                        if style.key == "none" {
                            Image(systemName: "nosign").font(.system(size: 22, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Plays as a cross fade on iOS (the tile shows exactly that).
                        if !style.isDrawn {
                            Text("≈")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Color.orange.opacity(0.85)))
                                .padding(3)
                        }
                    }
                Text(style.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(style.isDrawn ? 1 : 0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 26, alignment: .top)
            }
        }
        
        private var durationSection: some View {
            let limit = maxDuration
            return PropertySlider(
                label: "Duration (s)",
                value: Binding(
                    get: { min(transition.duration, limit) },
                    set: { liveDuration($0) }),
                range: Constants.TRANSITION_MIN_SECONDS...limit,
                resetTo: Constants.TRANSITION_DEFAULT_SECONDS,
                onEditingBegan: { if durationBefore == nil { durationBefore = transition.duration } },
                onEditingEnded: commitDuration)
        }
        
        private var modeSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("TIMING").font(.system(size: 11, weight: .bold)).foregroundColor(Color.mdPrimary)
                Picker("Timing", selection: Binding(get: { transition.mode }, set: { setMode($0) })) {
                    ForEach([EditingView.TransitionClip.TransitionMode.endFirst, .overlap, .beginSecond], id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(transition.mode.explanation)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        
        private var actions: some View {
            HStack(spacing: 10) {
                Button { applyToAll() } label: {
                    Label("Apply to all on this track", systemImage: "square.stack.3d.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                }
                Button(role: .destructive) { setStyle("none") } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                }
                .disabled(TransitionPlan.normalizedStyle(transition.effect.style) == "none")
            }
        }
        
        // MARK: Editing
        
        /// Android creates the transition as soon as two clips touch; do the same when it is opened.
        private func ensureTransition() {
            if clipA.endTransition == nil { clipA.endTransition = TransitionEditing.make(a: clipA, b: clipB) }
            if !clipA.endTransitionEnabled { clipA.endTransitionEnabled = true }
        }
        
        private func snapshot(_ clip: EditingView.Clip) -> (EditingView.TransitionClip?, Bool) {
            (clip.endTransition, clip.endTransitionEnabled)
        }
        
        /// One undo step: `change` is applied to a copy of every target's transition.
        private func edit(_ name: String, targets: [(clip: EditingView.Clip, next: EditingView.Clip?)],
                          change: @escaping (inout EditingView.TransitionClip) -> Void) {
            var records: [(clip: EditingView.Clip, before: (EditingView.TransitionClip?, Bool), after: EditingView.TransitionClip)] = []
            for (clip, next) in targets {
                let before = snapshot(clip)
                var t = before.0 ?? (next.map { TransitionEditing.make(a: clip, b: $0) }
                                    ?? TransitionEditing.make(a: clip, b: clipB))
                change(&t)
                t.duration = min(max(t.duration, Constants.TRANSITION_MIN_SECONDS),
                                 max(Constants.TRANSITION_MIN_SECONDS,
                                     min(Constants.TRANSITION_MAX_SECONDS,
                                         next.map { TransitionPlan.maxDuration(mode: t.mode, a: clip, b: $0) } ?? t.duration)))
                records.append((clip, before, TransitionEditing.normalized(t, cut: clip.startTime + clip.duration)))
            }
            let changed = onChanged
            func apply(_ transitions: [(EditingView.Clip, EditingView.TransitionClip?, Bool)]) {
                for (clip, transition, enabled) in transitions {
                    clip.endTransition = transition
                    clip.endTransitionEnabled = enabled
                }
                changed()
            }
            let undoState = records.map { ($0.clip, $0.before.0, $0.before.1) }
            let redoState = records.map { ($0.clip, Optional($0.after), true) }
            commandManager.execute(GenericCommand(description: name,
                                                  undo: { apply(undoState) },
                                                  redo: { apply(redoState) }))
        }
        
        private func setStyle(_ key: String) {
            edit("Transition style", targets: [(clipA, clipB)]) { $0.effect.style = key }
        }
        
        private func setMode(_ mode: EditingView.TransitionClip.TransitionMode) {
            edit("Transition timing", targets: [(clipA, clipB)]) { $0.mode = mode }
        }
        
        /// While dragging: change the value directly (no undo step per tick, no rebuild).
        private func liveDuration(_ value: Float) {
            var t = transition
            t.duration = value
            clipA.endTransition = TransitionEditing.normalized(t, cut: cut)
        }
        
        private func commitDuration() {
            guard let before = durationBefore else { return }
            durationBefore = nil
            let after = transition.duration
            guard abs(before - after) > 0.0005 else { return }
            let target = clipA
            let changed = onChanged
            let cut = self.cut
            let oldT = TransitionEditing.normalized({ var t = transition; t.duration = before; return t }(), cut: cut)
            let newT = TransitionEditing.normalized(transition, cut: cut)
            commandManager.execute(GenericCommand(description: "Transition duration",
                undo: { target.endTransition = oldT; changed() },
                redo: { target.endTransition = newT; changed() }))
            changed()
        }
        
        private func applyToAll() {
            let source = transition
            let siblings = track.clips.sorted { $0.startTime < $1.startTime }
            var targets: [(clip: EditingView.Clip, next: EditingView.Clip?)] = []
            for (a, b) in TransitionPlan.adjacentPairs(in: siblings) where TransitionPlan.isPicture(a) && TransitionPlan.isPicture(b) {
                targets.append((a, b))
            }
            guard !targets.isEmpty else { return }
            edit("Apply transition to all", targets: targets) { t in
                t.effect.style = source.effect.style
                t.duration = source.duration
                t.mode = source.mode
            }
        }
    }
}

/// The knot: observes clip A so its colour follows the style chosen in the panel.
struct TransitionKnotHost: View {
    @ObservedObject var clipA: EditingView.Clip
    let onTap: () -> Void
    
    var body: some View {
        TransitionKnotView(style: clipA.endTransitionEnabled ? clipA.endTransition?.effect.style : nil)
            .onTapGesture(perform: onTap)
    }
}
