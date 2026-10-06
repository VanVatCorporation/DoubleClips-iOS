import SwiftUI
import UIKit
import CoreText
import UniformTypeIdentifiers

// MARK: - Text style presets, saved styles, imported fonts
//
// Presets (Android: TextStyle.builtIns(), TextStyleLibrary, the style browser):
//   - A style is a PRESET: picking one COPIES its values into the clip, so a project never depends on a
//     style still being installed. Nothing in the clip records where the values came from; the panel
//     shows the preset's name while the clip's values still match it and "Custom" once they don't.
//   - Built-in presets set colour, outline and the per-unit animation (and put their In / Out
//     animations on the clip); bold / italic / alignment / spacing / shadow / box stay as they are.
//   - "My styles" are saved from the clip's whole look (everything in TextStyle plus its In / Out
//     animations) in the app's own storage, so they are available in every project. Deleting one never
//     changes a project.
//
// Fonts (Android: Fonts/ folder in the project):
//   - An imported .ttf / .otf / .ttc / .otc is validated, copied into `<project>/Fonts/` and registered
//     with the system for this launch. The style keeps the font's PostScript name in `fontName` (what the
//     renderer uses) and the project-relative path in `fontFile`. Every font in a project's Fonts folder
//     is registered when the project opens, so a project that moved to another device keeps its fonts.

// MARK: Presets

struct TextStylePreset: Identifiable {
    let id: String
    let name: String
    let author: String
    var colorHex: String
    var outlineWidth: Float
    var outlineColorHex: String
    var unitMode: String = "none"
    var stagger: Float = 0.6
    var order: String = "forward"
    var inAnimationId: String? = nil
    var outAnimationId: String? = nil
    
    var animatesPerUnit: Bool { unitMode != "none" }
    
    /// Copies the preset's values over a style (everything else in the style is left alone).
    func merge(into style: inout EditingView.TextStyle) {
        style.colorHex = colorHex
        style.outlineWidth = outlineWidth
        style.outlineColorHex = outlineColorHex
        style.unitMode = unitMode
        style.stagger = stagger
        style.order = order
    }
    
    /// What the style would look like as a tile / on a clip with otherwise default settings.
    var tileStyle: EditingView.TextStyle {
        var s = EditingView.TextStyle()
        merge(into: &s)
        return s
    }
}

enum TextStyleCatalog {
    
    /// Android's TextStyle.builtIns(): five plain looks, then six that animate per character / word / line.
    static let builtIns: [TextStylePreset] = {
        func plain(_ id: String, _ name: String, _ color: String, _ outline: Float, _ outlineColor: String) -> TextStylePreset {
            TextStylePreset(id: id, name: name, author: Constants.TEXT_STYLE_BUILTIN_AUTHOR,
                            colorHex: color, outlineWidth: outline, outlineColorHex: outlineColor)
        }
        func animated(_ id: String, _ name: String, _ color: String, _ outline: Float, _ outlineColor: String,
                      mode: String, stagger: Float, order: String, in inId: String?, out outId: String?) -> TextStylePreset {
            var p = plain(id, name, color, outline, outlineColor)
            p.unitMode = mode; p.stagger = stagger; p.order = order
            p.inAnimationId = inId; p.outAnimationId = outId
            return p
        }
        return [
            plain("classic", "Classic", "#FFFFFF", 0, "#000000"),
            plain("bold-outline", "Bold Outline", "#FFFFFF", 4, "#000000"),
            plain("caption-yellow", "Caption Yellow", "#FFD60A", 3, "#000000"),
            plain("neon-pink", "Neon Pink", "#FF4FD8", 3, "#6A0057"),
            plain("sticker", "Sticker", "#111111", 6, "#FFFFFF"),
            animated("pop-letters", "Pop Letters", "#FFFFFF", 3, "#000000", mode: "character", stagger: 0.7,
                     order: "forward", in: "pop-in", out: "fade-out"),
            animated("typewriter", "Typewriter", "#E8F5E9", 2, "#1B5E20", mode: "character", stagger: 0.9,
                     order: "forward", in: "fade-in", out: nil),
            animated("drop-words", "Drop Words", "#FFD60A", 3, "#000000", mode: "word", stagger: 0.6,
                     order: "forward", in: "drop-in", out: "rise-out"),
            animated("rise-lines", "Rise Lines", "#FFFFFF", 0, "#000000", mode: "line", stagger: 0.6,
                     order: "forward", in: "rise-in", out: "fade-out"),
            animated("spin-letters", "Spin Letters", "#FF4FD8", 3, "#6A0057", mode: "character", stagger: 0.6,
                     order: "centerOut", in: "spin-in", out: "fade-out"),
            animated("shuffle", "Shuffle", "#7CE0FF", 3, "#00334D", mode: "character", stagger: 0.8,
                     order: "random", in: "tilt-in", out: "fade-out")
        ]
    }()
    
    private static func same(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }
    
    /// The built-in the clip still matches, or nil ("Custom").
    static func match(_ style: EditingView.TextStyle, inAnimation: EditingView.AnimationClip,
                      outAnimation: EditingView.AnimationClip) -> TextStylePreset? {
        builtIns.first { p in
            style.colorHex.uppercased() == p.colorHex
                && same(style.outlineWidth, p.outlineWidth)
                && style.outlineColorHex.uppercased() == p.outlineColorHex
                && style.unitMode == p.unitMode
                && (!p.animatesPerUnit || (same(style.stagger, p.stagger) && style.order == p.order))
                && (p.inAnimationId == nil || inAnimation.type == p.inAnimationId)
                && (p.outAnimationId == nil || outAnimation.type == p.outAnimationId)
        }
    }
    
    /// The saved style the clip still matches, or nil.
    static func match(_ style: EditingView.TextStyle, inAnimation: EditingView.AnimationClip,
                      outAnimation: EditingView.AnimationClip, in saved: [SavedTextStyle]) -> SavedTextStyle? {
        saved.first { s in
            s.style == style
                && (s.inAnimationId == nil || inAnimation.type == s.inAnimationId)
                && (s.outAnimationId == nil || outAnimation.type == s.outAnimationId)
        }
    }
    
    // MARK: Tiles (drawn live with the same renderer as the clip)
    
    private static var tileCache: [String: UIImage] = [:]
    private static let tileLock = NSLock()
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    
    static func tileImage(key: String, style: EditingView.TextStyle) -> UIImage? {
        let cacheKey = key + "|" + String(describing: style)
        tileLock.lock()
        if let hit = tileCache[cacheKey] { tileLock.unlock(); return hit }
        tileLock.unlock()
        let spec = EditingView.TextSpec(text: Constants.TEXT_STYLE_TILE_SAMPLE, fontSize: Constants.TEXT_STYLE_TILE_FONT_SIZE,
                                        style: style, canvasWidth: 1000)
        guard let rendered = TextRenderer.render(spec),
              let cg = ciContext.createCGImage(rendered.image, from: rendered.image.extent) else { return nil }
        let image = UIImage(cgImage: cg)
        tileLock.lock(); tileCache[cacheKey] = image; tileLock.unlock()
        return image
    }
}

// MARK: Saved styles ("My styles")

struct SavedTextStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var style: EditingView.TextStyle
    /// The In / Out animations the style puts on the clip (nil = leave the clip's own).
    var inAnimationId: String?
    var outAnimationId: String?
}

enum TextStyleLibrary {
    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(Constants.TEXT_STYLES_FILENAME)
    }
    
    static func load() -> [SavedTextStyle] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SavedTextStyle].self, from: data) else { return [] }
        return list     // a damaged file just means no saved styles
    }
    
    private static func write(_ styles: [SavedTextStyle]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(styles) else { return }
        try? data.write(to: url, options: .atomic)
    }
    
    @discardableResult
    static func save(name: String, style: EditingView.TextStyle, inId: String?, outId: String?) -> SavedTextStyle {
        var all = load()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedTextStyle(id: "user-" + UUID().uuidString, name: trimmed.isEmpty ? "My style" : trimmed,
                                   style: style, inAnimationId: inId, outAnimationId: outId)
        all.append(saved)
        write(all)
        return saved
    }
    
    static func delete(id: String) {
        write(load().filter { $0.id != id })
    }
}

// MARK: Browser sheet

struct TextStyleBrowser: View {
    let saved: [SavedTextStyle]
    let selectedID: String?
    let onPickBuiltIn: (TextStylePreset) -> Void
    let onPickSaved: (SavedTextStyle) -> Void
    let onSave: (String) -> Void
    let onDelete: (SavedTextStyle) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 12, alignment: .top)]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("BUILT-IN").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(TextStyleCatalog.builtIns) { preset in
                            Button { onPickBuiltIn(preset); dismiss() } label: {
                                StyleTile(image: TextStyleCatalog.tileImage(key: preset.id, style: preset.tileStyle),
                                          title: preset.name, subtitle: preset.author,
                                          animated: preset.animatesPerUnit, selected: selectedID == preset.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Text("MY STYLES").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    if saved.isEmpty {
                        Text("Styles you save show up here, in every project.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(saved) { item in
                                Button { onPickSaved(item); dismiss() } label: {
                                    StyleTile(image: TextStyleCatalog.tileImage(key: item.id, style: item.style),
                                              title: item.name, subtitle: "Mine",
                                              animated: item.style.animatesPerUnit, selected: selectedID == item.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { onDelete(item) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        Text("Press and hold a style to delete it.").font(.footnote).foregroundColor(.secondary)
                    }
                    
                    Button { newName = ""; naming = true } label: {
                        Label("Save current look as a style", systemImage: "plus.square.on.square")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemBackground)))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Text styles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Save as a style", isPresented: $naming) {
                TextField("Style name", text: $newName)
                Button("Save") { onSave(newName) }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

private struct StyleTile: View {
    let image: UIImage?
    let title: String
    let subtitle: String
    let animated: Bool
    let selected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color(hex: "#2A2A2A")
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(14)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1)
            )
            .overlay(alignment: .topLeading) {
                if animated {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                        .foregroundColor(Color.mdPrimary)
                        .background(Circle().fill(Color.white).padding(3)).padding(5)
                }
            }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
            Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Project fonts

enum ProjectFonts {
    
    struct Entry: Identifiable, Hashable {
        /// PostScript name (what TextStyle.fontName holds).
        let name: String
        let title: String
        /// Project-relative path, "Fonts/<file>".
        let file: String
        var id: String { file + "|" + name }
    }
    
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    
    static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    
    static func directory(_ projectPath: String) -> String {
        IOHelper.combinePath(projectPath, Constants.PROJECT_FONTS_DIRECTORY)
    }
    
    /// The file types the importer accepts.
    static var contentTypes: [UTType] {
        [UTType.font] + ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }
    }
    
    /// Android's font validation: a TrueType / OpenType / collection header.
    static func looksLikeFont(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        if bytes == [0x00, 0x01, 0x00, 0x00] { return true }
        return ["true", "OTTO", "ttcf"].contains(String(bytes: bytes, encoding: .ascii) ?? "")
    }
    
    /// The faces inside one font file.
    private static func faces(of url: URL, file: String) -> [Entry] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descriptors.compactMap { d in
            guard let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
            let title = (CTFontDescriptorCopyAttribute(d, kCTFontDisplayNameAttribute) as? String) ?? name
            return Entry(name: name, title: title, file: file)
        }
    }
    
    /// Every face of every font file in the project's Fonts folder.
    static func list(projectPath: String) -> [Entry] {
        let dir = directory(projectPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted()
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .flatMap { faces(of: URL(fileURLWithPath: IOHelper.combinePath(dir, $0)),
                             file: Constants.PROJECT_FONTS_DIRECTORY + "/" + $0) }
    }
    
    /// Makes the project's fonts usable by name for this launch. Registering twice is harmless.
    static func registerAll(projectPath: String) {
        let dir = directory(projectPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names where extensions.contains((name as NSString).pathExtension.lowercased()) {
            register(URL(fileURLWithPath: IOHelper.combinePath(dir, name)))
        }
    }
    
    @discardableResult
    private static func register(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // "Already registered" (this launch, or a same-named font) is fine.
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }
    
    /// Validates, copies into `<project>/Fonts/` (a name clash becomes "name (1).ext") and registers.
    /// Returns the file's faces; the first is what a style should use.
    static func importFont(from source: URL, projectPath: String) throws -> [Entry] {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        
        guard extensions.contains(source.pathExtension.lowercased()), looksLikeFont(source) else {
            throw ImportError(message: "That file isn't a TrueType or OpenType font (.ttf, .otf, .ttc, .otc).")
        }
        let dir = directory(projectPath)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var fileName = base + "." + ext
        var counter = 1
        while FileManager.default.fileExists(atPath: IOHelper.combinePath(dir, fileName)) {
            fileName = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        let destination = URL(fileURLWithPath: IOHelper.combinePath(dir, fileName))
        try FileManager.default.copyItem(at: source, to: destination)
        
        let entries = faces(of: destination, file: Constants.PROJECT_FONTS_DIRECTORY + "/" + fileName)
        guard !entries.isEmpty, register(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError(message: "This font file couldn't be loaded.")
        }
        return entries
    }
}
