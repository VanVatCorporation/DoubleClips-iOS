import SwiftUI
import UniformTypeIdentifiers

// MARK: - Text clip editor
//
// Android's text panel has two fields: content and size. This one adds font, bold / italic, colour,
// alignment, letter / line spacing, wrap width, outline, shadow and a background box (all stored in
// the clip's optional `textStyle`, see EditingView+Text.swift).
//
// Editing model: controls change the clip live (cheap) and the change is COMMITTED, as one undo
// step plus one preview rebuild, when a slider is released, a colour stops changing (colour pickers
// fire continuously, so commits are debounced) or the panel closes.

extension EditingView {
    
    struct TextClipEditor: View {
        @ObservedObject var clip: EditingView.Clip
        let commandManager: CommandManager
        let projectPath: String
        let onChanged: () -> Void
        
        @State private var draft: String = ""
        @State private var committedText: String = ""
        @State private var committedSize: Float = 30
        @State private var committedStyle: TextStyle = TextStyle()
        @State private var committedIn = EditingView.AnimationClip()
        @State private var committedOut = EditingView.AnimationClip()
        @State private var commitTask: Task<Void, Never>?
        @State private var showAllFonts = false
        // Style presets / imported fonts (EditingView+TextStyles.swift)
        @State private var showStyles = false
        @State private var savedStyles: [SavedTextStyle] = []
        @State private var projectFonts: [ProjectFonts.Entry] = []
        @State private var showFontImporter = false
        @State private var fontError: String?
        
        private var style: TextStyle { clip.textStyle ?? TextStyle() }
        
        // MARK: Body
        
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                section("TEXT")
                TextField("Text", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .onChange(of: draft) { _ in
                        clip.textContent = draft
                        scheduleCommit()
                    }
                
                section("STYLE")
                HStack {
                    Text(currentStyleName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Button { savedStyles = TextStyleLibrary.load(); showStyles = true } label: {
                        Label("Browse styles…", systemImage: "square.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.mdPrimary))
                    }
                }
                
                section("FONT")
                fontChips
                HStack(spacing: 10) {
                    toggleButton("bold", isOn: style.bold) { mutate { $0.bold.toggle() }; commitNow() }
                    toggleButton("italic", isOn: style.italic) { mutate { $0.italic.toggle() }; commitNow() }
                    Spacer()
                    Picker("Alignment", selection: Binding(get: { style.alignment },
                                                           set: { value in mutate { $0.alignment = value }; commitNow() })) {
                        Image(systemName: "text.alignleft").tag("left")
                        Image(systemName: "text.aligncenter").tag("center")
                        Image(systemName: "text.alignright").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                slider("Size", get: { clip.fontSize ?? 30 }, set: { clip.fontSize = $0; scheduleCommit() },
                       range: 8...200, resetTo: 30)
                
                section("COLOUR")
                colorRow("Text", get: { style.colorHex }, set: { value in mutate { $0.colorHex = value } })
                
                section("SPACING")
                slider("Letters", get: { style.letterSpacing }, set: { v in mutate { $0.letterSpacing = v } },
                       range: -5...30, resetTo: 0)
                slider("Lines", get: { style.lineSpacing }, set: { v in mutate { $0.lineSpacing = v } },
                       range: -10...60, resetTo: 0)
                slider("Wrap at", get: { style.wrapWidth }, set: { v in mutate { $0.wrapWidth = v } },
                       range: 0...1, resetTo: 0)
                Text("Wrap at is a fraction of the video width; 0 keeps each line as typed.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                
                section("OUTLINE")
                slider("Width", get: { style.outlineWidth }, set: { v in mutate { $0.outlineWidth = v } },
                       range: 0...24, resetTo: 0)
                colorRow("Colour", get: { style.outlineColorHex }, set: { value in mutate { $0.outlineColorHex = value } })
                
                section("SHADOW")
                slider("Blur", get: { style.shadowBlur }, set: { v in mutate { $0.shadowBlur = v } },
                       range: 0...40, resetTo: 0)
                slider("Offset X", get: { style.shadowOffsetX }, set: { v in mutate { $0.shadowOffsetX = v } },
                       range: -40...40, resetTo: 0)
                slider("Offset Y", get: { style.shadowOffsetY }, set: { v in mutate { $0.shadowOffsetY = v } },
                       range: -40...40, resetTo: 0)
                colorRow("Colour", get: { style.shadowColorHex }, set: { value in mutate { $0.shadowColorHex = value } })
                
                section("BACKGROUND BOX")
                colorRow("Colour", get: { style.backgroundColorHex }, set: { value in mutate { $0.backgroundColorHex = value } })
                slider("Padding", get: { style.backgroundPadding }, set: { v in mutate { $0.backgroundPadding = v } },
                       range: 0...80, resetTo: 0)
                slider("Corners", get: { style.backgroundRadius }, set: { v in mutate { $0.backgroundRadius = v } },
                       range: 0...80, resetTo: 0)
                Text("The box shows once its colour has some opacity.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                
                section("ANIMATION")
                animationMenu("In", \.inAnimation, .in)
                animationMenu("Out", \.outAnimation, .out)
                Picker("Animate by", selection: Binding(get: { style.unitMode }, set: { setUnitMode($0) })) {
                    Text("Whole").tag("none")
                    Text("Letters").tag("character")
                    Text("Words").tag("word")
                    Text("Lines").tag("line")
                }
                .pickerStyle(.segmented)
                if style.animatesPerUnit {
                    slider("Stagger", get: { style.stagger }, set: { v in mutate { $0.stagger = min(max(v, 0), 0.95) } },
                           range: 0...0.95, resetTo: 0.6)
                    HStack {
                        Text("Order").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                            .frame(width: 80, alignment: .leading)
                        Picker("Order", selection: Binding(get: { style.order },
                                                           set: { value in mutate { $0.order = value }; commitNow() })) {
                            Text("Forward").tag("forward")
                            Text("Reverse").tag("reverse")
                            Text("Centre out").tag("centerOut")
                            Text("Random").tag("random")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Text("Letters, words or lines enter and leave one after another using the In / Out animation. A background box stays still. Very long text (over \(Constants.TEXT_UNIT_MAX_COUNT) pieces) animates as a whole.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                
                Button {
                    mutate { $0 = TextStyle() }
                    commitNow()
                } label: {
                    Label("Reset style", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                }
            }
            .onAppear {
                draft = clip.textContent ?? ""
                committedText = draft
                committedSize = clip.fontSize ?? 30
                committedStyle = style
                committedIn = clip.inAnimation
                committedOut = clip.outAnimation
                savedStyles = TextStyleLibrary.load()
                projectFonts = ProjectFonts.list(projectPath: projectPath)
            }
            .onDisappear { commitNow() }
            .background(Color.clear.sheet(isPresented: $showAllFonts) {
                AllFontsSheet(selected: style.fontName) { name in
                    mutate { $0.fontName = name; $0.fontFile = "" }
                    commitNow()
                }
            })
            .background(Color.clear.sheet(isPresented: $showStyles) {
                TextStyleBrowser(
                    saved: savedStyles,
                    selectedID: currentStyleID,
                    onPickBuiltIn: { applyBuiltIn($0) },
                    onPickSaved: { applySaved($0) },
                    onSave: { name in
                        TextStyleLibrary.save(name: name, style: style,
                                              inId: animationID(clip.inAnimation), outId: animationID(clip.outAnimation))
                        savedStyles = TextStyleLibrary.load()
                    },
                    onDelete: { item in
                        TextStyleLibrary.delete(id: item.id)
                        savedStyles = TextStyleLibrary.load()
                    })
                .presentationDetents([.medium, .large])
            })
            .background(Color.clear.fileImporter(isPresented: $showFontImporter,
                                                 allowedContentTypes: ProjectFonts.contentTypes) { result in
                importFont(result)
            })
            .alert("Couldn't import the font", isPresented: Binding(get: { fontError != nil },
                                                                     set: { if !$0 { fontError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(fontError ?? "")
            }
        }
        
        // MARK: Pieces
        
        private func section(_ title: String) -> some View {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(Color.mdPrimary)
        }
        
        private var fontChips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { showFontImporter = true } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
                    }
                    ForEach(projectFonts) { entry in
                        let selected = style.fontName == entry.name
                        Button {
                            mutate { $0.fontName = entry.name; $0.fontFile = entry.file }
                            commitNow()
                        } label: {
                            Text(entry.title)
                                .font(Font(TextFonts.font(TextStyle(fontName: entry.name), size: 14) as CTFont))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(selected ? Color.mdPrimary : Color.white.opacity(0.1)))
                        }
                    }
                    ForEach(TextFonts.curated) { entry in
                        let selected = style.fontName == entry.name
                        Button {
                            mutate { $0.fontName = entry.name; $0.fontFile = "" }
                            commitNow()
                        } label: {
                            Text(entry.title)
                                .font(Font(TextFonts.font(TextStyle(fontName: entry.name), size: 14) as CTFont))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(selected ? Color.mdPrimary : Color.white.opacity(0.1)))
                        }
                    }
                    Button { showAllFonts = true } label: {
                        Label("More…", systemImage: "textformat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
                    }
                }
            }
        }
        
        private func toggleButton(_ kind: String, isOn: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: kind)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.mdPrimary : Color.white.opacity(0.1)))
            }
        }
        
        private func slider(_ label: String, get: @escaping () -> Float, set: @escaping (Float) -> Void,
                            range: ClosedRange<Float>, resetTo: Float) -> some View {
            PropertySlider(label: label,
                           value: Binding(get: get, set: set),
                           range: range, resetTo: resetTo,
                           onEditingBegan: { beginEditing() },
                           onEditingEnded: { commitNow() })
        }
        
        private func colorRow(_ label: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
            ColorPicker(label, selection: Binding(
                get: { Color(uiColor: HexColor.ui(get())) },
                set: { newColor in
                    set(HexColor.string(UIColor(newColor)))
                    scheduleCommit()
                }), supportsOpacity: true)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.8))
        }
        
        // MARK: Styles and fonts
        
        private func animationID(_ a: EditingView.AnimationClip) -> String? {
            a.type.isEmpty || a.type == "none" ? nil : a.type
        }
        
        private var currentBuiltIn: TextStylePreset? {
            TextStyleCatalog.match(style, inAnimation: clip.inAnimation, outAnimation: clip.outAnimation)
        }
        private var currentSaved: SavedTextStyle? {
            TextStyleCatalog.match(style, inAnimation: clip.inAnimation, outAnimation: clip.outAnimation, in: savedStyles)
        }
        /// The preset the clip's values still match, "Custom" once they differ.
        private var currentStyleName: String { currentSaved?.name ?? currentBuiltIn?.name ?? "Custom" }
        private var currentStyleID: String? { currentSaved?.id ?? currentBuiltIn?.id }
        
        /// A built-in keeps the clip's own font, bold / italic, alignment, spacing, shadow and box.
        private func applyBuiltIn(_ preset: TextStylePreset) {
            ClipAnimationStore.loadAll()
            var s = style
            preset.merge(into: &s)
            clip.textStyle = s == TextStyle() ? nil : s
            // Only animations that are installed are put on the clip; none = leave the clip's own.
            if let id = preset.inAnimationId, ClipAnimationLoader.get(id, direction: .in) != nil {
                clip.inAnimation = EditingView.AnimationClip(type: id, duration: Constants.TEXT_UNIT_DEFAULT_WINDOW_SECONDS)
            }
            if let id = preset.outAnimationId, ClipAnimationLoader.get(id, direction: .out) != nil {
                clip.outAnimation = EditingView.AnimationClip(type: id, duration: Constants.TEXT_UNIT_DEFAULT_WINDOW_SECONDS)
            }
            commitNow()
        }
        
        /// A saved style is the whole look: every style setting comes from it (text and size stay).
        private func applySaved(_ saved: SavedTextStyle) {
            ClipAnimationStore.loadAll()
            clip.textStyle = saved.style == TextStyle() ? nil : saved.style
            if let id = saved.inAnimationId, ClipAnimationLoader.get(id, direction: .in) != nil {
                clip.inAnimation = EditingView.AnimationClip(type: id, duration: clip.inAnimation.duration)
            }
            if let id = saved.outAnimationId, ClipAnimationLoader.get(id, direction: .out) != nil {
                clip.outAnimation = EditingView.AnimationClip(type: id, duration: clip.outAnimation.duration)
            }
            commitNow()
        }
        
        private func importFont(_ result: Result<URL, Error>) {
            switch result {
            case .failure(let error):
                fontError = error.localizedDescription
            case .success(let url):
                do {
                    let faces = try ProjectFonts.importFont(from: url, projectPath: projectPath)
                    projectFonts = ProjectFonts.list(projectPath: projectPath)
                    if let first = faces.first {
                        mutate { $0.fontName = first.name; $0.fontFile = first.file }
                        commitNow()
                    }
                } catch {
                    fontError = error.localizedDescription
                }
            }
        }
        
        // MARK: Animation
        
        /// In / Out animation of the clip: a menu and a length. (The same slots as the clip properties
        /// panel; the unit mode above decides whether they run on the whole text or on each unit.)
        @ViewBuilder
        private func animationMenu(_ label: String,
                                   _ kp: ReferenceWritableKeyPath<EditingView.Clip, EditingView.AnimationClip>,
                                   _ direction: ClipAnimation.Direction) -> some View {
            let _ = ClipAnimationStore.loadAll()
            let current = clip[keyPath: kp].type
            let installed = ClipAnimationLoader.list(direction)
            let isNone = current.isEmpty || current == "none"
            let currentName = isNone ? "None"
                : (installed.first(where: { $0.id == current })?.name ?? "\(current) (not installed)")
            
            HStack {
                Text("\(label) animation").font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)
                Menu {
                    Button("None") { setAnimation(kp, id: "none") }
                    ForEach(installed, id: \.id) { animation in
                        Button(animation.name) { setAnimation(kp, id: animation.id) }
                    }
                } label: {
                    HStack {
                        Text(currentName).font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }
            }
            if !isNone {
                slider("\(label) length", get: { clip[keyPath: kp].duration },
                       set: { v in clip[keyPath: kp].duration = max(0, v); scheduleCommit() },
                       range: 0.05...4, resetTo: 0.5)
            }
        }
        
        private func setAnimation(_ kp: ReferenceWritableKeyPath<EditingView.Clip, EditingView.AnimationClip>, id: String) {
            guard clip[keyPath: kp].type != id else { return }
            clip[keyPath: kp].type = id
            if let animation = ClipAnimationLoader.get(id) {
                clip[keyPath: kp].duration = animation.defaultDuration
            }
            commitNow()
        }
        
        /// Picking letters / words / lines on a clip with no animation yet gives it the default In
        /// animation, otherwise the choice would show nothing.
        private func setUnitMode(_ mode: String) {
            mutate { $0.unitMode = mode }
            let hasNone = { (a: EditingView.AnimationClip) in a.type.isEmpty || a.type == "none" }
            if mode != "none", hasNone(clip.inAnimation), hasNone(clip.outAnimation),
               ClipAnimationLoader.get(Constants.TEXT_UNIT_DEFAULT_ANIMATION_ID, direction: .in) != nil {
                clip.inAnimation = EditingView.AnimationClip(type: Constants.TEXT_UNIT_DEFAULT_ANIMATION_ID,
                                                             duration: Constants.TEXT_UNIT_DEFAULT_WINDOW_SECONDS)
            }
            commitNow()
        }
        
        // MARK: Editing / undo
        
        /// Remembers the state to undo to, once per burst of edits.
        private func beginEditing() {
            // `committed*` always hold the last committed values; nothing to do until something changes.
        }
        
        /// Changes the style live, without a rebuild.
        private func mutate(_ change: (inout TextStyle) -> Void) {
            var s = style
            change(&s)
            clip.textStyle = s == TextStyle() ? nil : s
        }
        
        private func scheduleCommit() {
            commitTask?.cancel()
            commitTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Constants.TEXT_STYLE_COMMIT_DELAY_SECONDS * 1_000_000_000))
                if !Task.isCancelled { commitNow() }
            }
        }
        
        /// One undo step for everything changed since the last commit, then refresh the preview.
        private func commitNow() {
            commitTask?.cancel()
            let target = clip
            
            let oldText = committedText, newText = clip.textContent ?? ""
            let oldSize = committedSize, newSize = clip.fontSize ?? 30
            let oldStyle = committedStyle, newStyle = clip.textStyle ?? TextStyle()
            let oldIn = committedIn, newIn = clip.inAnimation
            let oldOut = committedOut, newOut = clip.outAnimation
            guard oldText != newText || oldSize != newSize || oldStyle != newStyle
                    || oldIn != newIn || oldOut != newOut else { return }
            
            committedText = newText
            committedSize = newSize
            committedStyle = newStyle
            committedIn = newIn
            committedOut = newOut
            let changed = onChanged
            
            commandManager.execute(GenericCommand(description: "Edit text",
                undo: {
                    target.textContent = oldText
                    target.fontSize = oldSize
                    target.textStyle = oldStyle == TextStyle() ? nil : oldStyle
                    target.inAnimation = oldIn
                    target.outAnimation = oldOut
                    changed()
                },
                redo: {
                    target.textContent = newText
                    target.fontSize = newSize
                    target.textStyle = newStyle == TextStyle() ? nil : newStyle
                    target.inAnimation = newIn
                    target.outAnimation = newOut
                    changed()
                }))
            changed()
        }
    }
    
    // MARK: All installed fonts
    
    struct AllFontsSheet: View {
        let selected: String
        let onPick: (String) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var query = ""
        private let families = TextFonts.allFamilies()
        
        var body: some View {
            NavigationStack {
                List(families.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { entry in
                    Button {
                        onPick(entry.name)
                        dismiss()
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(Font(TextFonts.font(EditingView.TextStyle(fontName: entry.name), size: 18) as CTFont))
                                .foregroundColor(.primary)
                            Spacer()
                            if entry.name == selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                }
                .searchable(text: $query)
                .navigationTitle("Fonts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
    }
}
