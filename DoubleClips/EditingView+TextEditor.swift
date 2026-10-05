import SwiftUI

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
        let onChanged: () -> Void
        
        @State private var draft: String = ""
        @State private var committedText: String = ""
        @State private var committedSize: Float = 30
        @State private var committedStyle: TextStyle = TextStyle()
        @State private var commitTask: Task<Void, Never>?
        @State private var showAllFonts = false
        
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
            }
            .onDisappear { commitNow() }
            .background(Color.clear.sheet(isPresented: $showAllFonts) {
                AllFontsSheet(selected: style.fontName) { name in
                    mutate { $0.fontName = name }
                    commitNow()
                }
            })
        }
        
        // MARK: Pieces
        
        private func section(_ title: String) -> some View {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(Color.mdPrimary)
        }
        
        private var fontChips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TextFonts.curated) { entry in
                        let selected = style.fontName == entry.name
                        Button {
                            mutate { $0.fontName = entry.name }
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
            guard oldText != newText || oldSize != newSize || oldStyle != newStyle else { return }
            
            committedText = newText
            committedSize = newSize
            committedStyle = newStyle
            let changed = onChanged
            
            commandManager.execute(GenericCommand(description: "Edit text",
                undo: {
                    target.textContent = oldText
                    target.fontSize = oldSize
                    target.textStyle = oldStyle == TextStyle() ? nil : oldStyle
                    changed()
                },
                redo: {
                    target.textContent = newText
                    target.fontSize = newSize
                    target.textStyle = newStyle == TextStyle() ? nil : newStyle
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
