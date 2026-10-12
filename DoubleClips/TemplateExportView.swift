import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Combine

// MARK: - Use template (Android: TemplateExportActivity + layout_template_export.xml)
//
// Opened by the "Use template" button in TemplatePreviewView. Same structure as Android:
//   • top bar:   back · settings (display icon) · EXPORT
//   • Clips:     one 100×100 tile per replaceable clip in the template (index over a thumbnail).
//                Tap = pick photo/video (a multi-selection fills the following tiles, extras are
//                discarded). Long-press = Properties / Delete.
//   • Export Clip panel (Android: view_template_export_properties): preview, name, type, length, trim.
//   • Export Settings panel: the same panel as the project export (ExportSettingsSheet).
//   • Log:       status, running tasks, Enable log / Truncate log / Scroll lock, log text.
//
// Left out on purpose: the render-engine radio and the Advanced (FFmpeg command) section.
// `ffmpegCommand` is deprecated: the template is a TIMELINE (TemplateTimeline.swift). One tile per white
// stripe of it, in the same order and numbered the same; EXPORT builds the timeline with the picked media
// in it (TemplateRenderer.swift) and opens the normal export screen.

// MARK: Model

struct TemplateClipSlot: Identifiable {
    enum Kind { case empty, video, image }
    
    let id = UUID()
    var kind: Kind = .empty
    var path = ""
    var fileName = ""
    var typeDescription = ""
    var thumbnail: UIImage?
    /// Length of the picked media in seconds (videos only).
    var mediaDuration: Double = 0
    var startTrim: Double = 0
    var endTrim: Double = 0
    /// How long the template keeps this clip on screen (seconds; 0 = unknown, an old template).
    var targetDuration: Double = 0
    /// Id of the group the template put this clip in (clips that share one source), nil = it stands alone.
    var group: String?
    /// The person gave this clip its own media after the group was filled: the group no longer sets it.
    var detached = false
    /// Where the template's own clip starts inside its source (seconds): where a grouped clip starts by default.
    var sourceTrim: Double = 0
    
    var isFilled: Bool { kind != .empty }
    
    var trimmedLength: Double { max(0, endTrim - startTrim) }
}

/// A movie handed over by the Photos picker, copied out of the picker's scratch location.
private struct PickedMovie: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("template-pick-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The dot colours that mark clips sharing one media (CapCut's coloured dots).
enum TemplateGroupPalette {
    static let colors: [Color] = [
        Color(red: 0.96, green: 0.55, blue: 0.20),   // orange
        Color(red: 0.70, green: 0.45, blue: 1.00),   // purple
        Color(red: 0.25, green: 0.80, blue: 0.40),   // green
        Color(red: 0.20, green: 0.60, blue: 1.00),   // blue
        Color(red: 1.00, green: 0.25, blue: 0.40),   // red
        Color(red: 0.45, green: 0.50, blue: 0.95),   // indigo
        Color(red: 0.95, green: 0.80, blue: 0.20),   // yellow
        Color(red: 0.20, green: 0.80, blue: 0.80)    // teal
    ]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// One tile of the first stage: a group of clips that share a source (they take one media), or a clip on its own.
struct TemplateSlotEntry: Identifiable {
    let id: String
    /// Slot indices, in time order.
    let members: [Int]
    /// Position of the group among the groups (picks the dot colour); nil for a clip on its own.
    let colorIndex: Int?
}

@MainActor
final class TemplateExportModel: ObservableObject {
    
    /// First stage = one tile per group, second = every clip (CapCut's two steps). Templates without groups only have the second.
    enum Stage { case groups, clips }
    @Published var stage: Stage = .clips
    
    @Published var slots: [TemplateClipSlot]
    @Published var settings: EditingView.VideoSettings = .androidDefault
    @Published var isImporting = false
    /// The template's timeline once it is loaded; the slots come from it.
    @Published var info: TemplateTimelineInfo?
    /// Why the timeline couldn't be loaded (EXPORT then explains instead of rendering).
    @Published var timelineProblem: String?
    /// Building the timeline / downloading resources for the render.
    @Published var isPreparing = false
    @Published private(set) var logText = ""
    @Published var logEnabled = true
    @Published var truncateLog = true
    
    init(clipCount: Int) {
        slots = Array(repeating: TemplateClipSlot(), count: max(0, clipCount))
        log("Template ready: \(slots.count) clip slot(s). Tap a tile to choose a photo or video.")
    }
    
    /// The timeline arrived: one slot per white stripe, each knowing how long its clip is, and the export
    /// settings start as the canvas the template was made for.
    func configure(with info: TemplateTimelineInfo) {
        self.info = info
        timelineProblem = nil
        if slots.count != info.slots.count || !slots.contains(where: { $0.isFilled }) {
            slots = info.slots.map { slotInfo in
                var slot = TemplateClipSlot()
                slot.targetDuration = slotInfo.duration
                return slot
            }
        } else {
            for i in slots.indices { slots[i].targetDuration = info.slots[i].duration }
        }
        for i in slots.indices where info.slots.indices.contains(i) {
            slots[i].group = info.slots[i].group
            slots[i].sourceTrim = info.slots[i].sourceTrim
        }
        if !slots.contains(where: { $0.isFilled }) { stage = hasGroups ? .groups : .clips }
        if let canvas = info.canvas { settings = canvas }
        log("Template timeline loaded: \(info.slots.count) clip slot(s), \(String(format: "%.1f", info.duration))s.")
    }
    
    // MARK: Temp storage (Android: <persistentDataPath>/TemplatesClipTemp)
    
    static var tempDirectory: String {
        IOHelper.combinePath(IOHelper.persistentDataPath, Constants.DEFAULT_TEMPLATE_CLIP_TEMP_DIRECTORY)
    }
    
    /// Android clears this folder when an export completes and when the screen closes.
    static func clearTempDirectory() {
        _ = IOHelper.deleteDir(tempDirectory)
    }
    
    // MARK: Log
    
    func log(_ message: String) {
        guard logEnabled else { return }
        var text = logText.isEmpty ? message : logText + "\n" + message
        let limit = Constants.DEFAULT_LOGGING_LIMIT_CHARACTERS
        if truncateLog, text.count > limit {
            text = String(text.suffix(limit))
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
        }
        logText = text
    }
    
    // MARK: Groups
    
    var hasGroups: Bool { slots.contains { $0.group != nil } }
    
    /// The first stage's tiles: clips that share a group are one tile (placed where the group's first clip is), every
    /// clip on its own is a tile.
    var entries: [TemplateSlotEntry] {
        var result: [TemplateSlotEntry] = []
        var positions: [String: Int] = [:]
        var colors: [String: Int] = [:]
        for (index, slot) in slots.enumerated() {
            guard let group = slot.group else {
                result.append(TemplateSlotEntry(id: "slot-\(index)", members: [index], colorIndex: nil))
                continue
            }
            if let at = positions[group] {
                let old = result[at]
                result[at] = TemplateSlotEntry(id: old.id, members: old.members + [index], colorIndex: old.colorIndex)
            } else {
                positions[group] = result.count
                colors[group] = colors.count
                result.append(TemplateSlotEntry(id: "group-\(group)", members: [index], colorIndex: colors[group]))
            }
        }
        return result
    }
    
    /// The dot colour index of a clip's group (the same numbering the first stage uses), nil for a clip on its own.
    func colorIndex(ofSlot index: Int) -> Int? {
        guard slots.indices.contains(index), slots[index].group != nil else { return nil }
        return entries.first { $0.members.contains(index) }?.colorIndex
    }
    
    /// The first stage is complete when every tile has media.
    var groupsFilled: Bool { !slots.isEmpty && slots.allSatisfy { $0.isFilled } }
    
    // MARK: Picking
    
    /// Second stage: fills slot `start`, `start + 1`, … with the picked items; leftovers are discarded (Android).
    /// A clip of a group that is filled this way leaves its group (the group no longer sets it).
    func fill(from start: Int, with items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        
        var index = start
        for item in items {
            guard index < slots.count else {
                log("Discarded \(items.count - (index - start)) extra item(s): no more slots.")
                break
            }
            do {
                try await load(item, into: index, detach: true)
                index += 1
            } catch {
                log("Clip \(index + 1): couldn't load that item (\(error.localizedDescription)).")
            }
        }
        pruneTempFiles()
    }
    
    /// First stage: item k goes to tile `start + k`. A group's media goes to every clip of the group that hasn't been
    /// given its own (when every clip of it has, the group takes them all back).
    func fillEntries(from start: Int, with items: [PhotosPickerItem]) async {
        let list = entries
        guard !items.isEmpty, list.indices.contains(start) else { return }
        isImporting = true
        defer { isImporting = false }
        
        var tile = start
        for item in items {
            guard tile < list.count else {
                log("Discarded \(items.count - (tile - start)) extra item(s): no more tiles.")
                break
            }
            var members = list[tile].members
            if members.allSatisfy({ slots[$0].detached }) {
                for m in members { slots[m].detached = false }
            }
            members = members.filter { !slots[$0].detached }
            do {
                try await load(item, into: members[0], detach: false)
                spread(from: members[0], to: members)
                if members.count > 1 { log("Tile \(tile + 1) ← the same media for \(members.count) clips.") }
                tile += 1
            } catch {
                log("Tile \(tile + 1): couldn't load that item (\(error.localizedDescription)).")
            }
        }
        pruneTempFiles()
    }
    
    /// Gives the other clips of a group the media `source` holds (a file is shared, not copied), each with its own length.
    private func spread(from source: Int, to members: [Int]) {
        let origin = slots[source]
        for m in members where m != source {
            var slot = TemplateClipSlot()
            slot.kind = origin.kind
            slot.path = origin.path
            slot.fileName = origin.fileName
            slot.typeDescription = origin.typeDescription
            slot.thumbnail = origin.thumbnail
            slot.mediaDuration = origin.mediaDuration
            slot.targetDuration = slots[m].targetDuration
            slot.group = slots[m].group
            slot.sourceTrim = slots[m].sourceTrim
            applyDefaultTrim(&slot)
            slots[m] = slot
        }
    }
    
    /// A video starts at the template clip's own start inside its source when it is long enough (so the pieces of one
    /// split video stay different pieces), else as early as it can; it runs as long as the template keeps the clip.
    private func applyDefaultTrim(_ slot: inout TemplateClipSlot) {
        guard slot.kind == .video else { return }
        let media = slot.mediaDuration
        let want = slot.targetDuration > 0 ? min(media, slot.targetDuration) : media
        let start = slot.group != nil ? min(max(0, slot.sourceTrim), max(0, media - want)) : 0
        slot.startTrim = start
        slot.endTrim = min(media, start + want)
    }
    
    private func load(_ item: PhotosPickerItem, into index: Int, detach: Bool) async throws {
        let directory = Self.tempDirectory
        IOHelper.createEmptyDirectories(directory)
        let unique = String(UUID().uuidString.prefix(6))
        
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        var slot = TemplateClipSlot()
        if slots.indices.contains(index) {
            slot.targetDuration = slots[index].targetDuration
            slot.group = slots[index].group
            slot.sourceTrim = slots[index].sourceTrim
        }
        slot.detached = detach && slot.group != nil
        
        if isVideo {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw ExportError("The video could not be read.")
            }
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension.lowercased()
            let destination = URL(fileURLWithPath: IOHelper.combinePath(directory, "\(index)-\(unique).\(ext)"))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: movie.url, to: destination)
            
            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            slot.kind = .video
            slot.path = destination.path
            slot.fileName = destination.lastPathComponent
            slot.typeDescription = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
            slot.mediaDuration = duration.isFinite ? max(0, duration) : 0
            // The template keeps this clip on screen for `targetDuration`: start with that much of the video.
            applyDefaultTrim(&slot)
            slot.thumbnail = await Self.videoThumbnail(asset)
        } else {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ExportError("The image could not be read.")
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
            let destination = URL(fileURLWithPath: IOHelper.combinePath(directory, "\(index)-\(unique).\(ext)"))
            try data.write(to: destination, options: .atomic)
            
            slot.kind = .image
            slot.path = destination.path
            slot.fileName = destination.lastPathComponent
            slot.typeDescription = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
            slot.thumbnail = Self.imageThumbnail(at: destination)
        }
        
        slots[index] = slot
        switch slot.kind {
        case .video:
            log(String(format: "Clip %d ← video, %.1fs (%@)", index + 1, slot.mediaDuration, slot.typeDescription))
        case .image:
            log("Clip \(index + 1) ← image (\(slot.typeDescription))")
        case .empty:
            break
        }
    }
    
    func clear(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        var empty = TemplateClipSlot()
        empty.targetDuration = slots[index].targetDuration
        empty.group = slots[index].group
        empty.sourceTrim = slots[index].sourceTrim
        slots[index] = empty
        pruneTempFiles()
        log("Clip \(index + 1) cleared.")
    }
    
    /// Clears a first-stage tile: every clip of the group that the group sets.
    func clearEntry(_ entry: TemplateSlotEntry) {
        for m in entry.members where !slots[m].detached || entry.members.count == 1 {
            var empty = TemplateClipSlot()
            empty.targetDuration = slots[m].targetDuration
            empty.group = slots[m].group
            empty.sourceTrim = slots[m].sourceTrim
            slots[m] = empty
        }
        pruneTempFiles()
        log("Tile cleared.")
    }
    
    func setTrim(_ index: Int, start: Double, end: Double) {
        guard slots.indices.contains(index), slots[index].kind == .video else { return }
        slots[index].startTrim = start
        slots[index].endTrim = end
        log(String(format: "Clip %d trim: %.1fs – %.1fs", index + 1, start, end))
    }
    
    /// Media files are shared between the clips of a group, so a file goes only when no clip uses it any more.
    private func pruneTempFiles() {
        let used = Set(slots.filter { !$0.path.isEmpty }.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        for url in IOHelper.listFiles(Self.tempDirectory, options: .files) where !used.contains(url.lastPathComponent) {
            _ = IOHelper.deleteFile(url.path)
        }
    }
    
    // MARK: Thumbnails
    
    private static func videoThumbnail(_ asset: AVURLAsset) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }
    
    /// Downsampled decode: a 48 MP photo never gets fully decoded just to draw a 100 pt tile.
    private static func imageThumbnail(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: Screen

struct TemplateExportView: View {
    let template: TemplateData
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TemplateExportModel
    
    @State private var pickingIndex: Int?
    @State private var pickerPresented = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var propertiesRef: SlotRef?
    @State private var deleteIndex: Int?
    @State private var alertMessage: String?
    @State private var rendered: PreparedTemplateRender?
    @State private var renderDirectory: URL?
    @State private var countedUse = false
    @State private var scrollLock = true
    
    private struct SlotRef: Identifiable { let id: Int }
    
    /// How many tiles the picker can fill from the tapped one on: the first stage's tiles, or every clip.
    private var pickerLimit: Int { model.stage == .groups ? model.entries.count : model.slots.count }
    
    init(template: TemplateData) {
        self.template = template
        _model = StateObject(wrappedValue: TemplateExportModel(clipCount: template.templateTotalClip))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.stage == .groups { groupsSection } else { clipsSection }
                    logSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.stage == .groups { groupsBar }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await loadTimeline() }
        .onAppear {
            TemplateExportModel.clearTempDirectory()
        }
        .onDisappear {
            TemplateExportModel.clearTempDirectory()
        }
        .photosPicker(isPresented: $pickerPresented,
                      selection: $pickerSelection,
                      maxSelectionCount: max(1, pickerLimit - (pickingIndex ?? 0)),
                      matching: .any(of: [.images, .videos]))
        .onChange(of: pickerSelection) { items in
            guard !items.isEmpty, let start = pickingIndex else { return }
            pickerSelection = []
            pickingIndex = nil
            Task {
                if model.stage == .groups { await model.fillEntries(from: start, with: items) }
                else { await model.fill(from: start, with: items) }
            }
        }
        .sheet(isPresented: $showSettings) {
            ExportSettingsSheet(initial: model.settings) { edited in
                guard !edited.sameExportFields(as: model.settings) else { return }
                model.settings = edited
                model.log(String(format: "Settings: %d×%d @ %d fps, %d Mbps%@",
                                 edited.videoWidth, edited.videoHeight, edited.frameRate, edited.bitrate,
                                 edited.isStretchToFull ? ", stretch to fit" : ""))
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $propertiesRef) { ref in
            TemplateClipPropertiesSheet(model: model, index: ref.id)
                .presentationDetents([.medium, .large])
        }
        .alert("Delete media?", isPresented: Binding(get: { deleteIndex != nil },
                                                     set: { if !$0 { deleteIndex = nil } })) {
            Button("Cancel", role: .cancel) { deleteIndex = nil }
            Button("Delete", role: .destructive) {
                if let index = deleteIndex { model.clear(index) }
                deleteIndex = nil
            }
        } message: {
            Text("This clip will be removed from the slot.")
        }
        .alert("Can't export yet", isPresented: Binding(get: { alertMessage != nil },
                                                        set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        .fullScreenCover(item: $rendered, onDismiss: {
            if let directory = renderDirectory { TemplateRenderer.cleanup(directory) }
            renderDirectory = nil
        }) { render in
            ExportSheetView(project: render.project, timeline: render.timeline, allowsTemplateExport: false) { _ in
                // The template was used: tell the server once per visit to this screen.
                if !countedUse {
                    countedUse = true
                    TemplateUseCounter.increment(template.templateId)
                }
            }
        }
    }
    
    // MARK: Timeline + render
    
    private func loadTimeline() async {
        guard !template.templateTimelineLink.isEmpty else {
            model.timelineProblem = "This template is old: it has no timeline, and only FFmpeg could render it."
            return
        }
        do {
            let info = try await TemplateTimelineLoader.load(for: template)
            model.configure(with: info)
        } catch {
            model.timelineProblem = "The template's timeline couldn't be loaded: \(error.localizedDescription)"
            model.log(model.timelineProblem ?? "")
        }
    }
    
    private func startRender() async {
        if let problem = model.timelineProblem { alertMessage = problem; return }
        guard model.info != nil else { alertMessage = "The template's timeline is still loading. Try again in a moment."; return }
        let missing = model.slots.indices.filter { !model.slots[$0].isFilled }.map { $0 + 1 }
        guard missing.isEmpty else {
            alertMessage = "Fill every clip first. Empty: " + missing.map(String.init).joined(separator: ", ") + "."
            return
        }
        model.isPreparing = true
        defer { model.isPreparing = false }
        do {
            let prepared = try await TemplateRenderer.prepare(template: template, slots: model.slots,
                                                              settings: model.settings) { model.log($0) }
            renderDirectory = prepared.directory
            countedUse = false
            rendered = prepared
        } catch {
            model.log("Couldn't prepare the template: \(error.localizedDescription)")
            alertMessage = error.localizedDescription
        }
    }
    
    // MARK: Top bar (android:id="top_bar")
    
    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 50, height: 50)
            }
            Button(action: { showSettings = true }) {
                Image(systemName: "display")
                    .font(.system(size: 20))
                    .frame(width: 50, height: 50)
            }
            
            Spacer()
            Text(template.templateTitle.isEmpty ? "Use template" : template.templateTitle)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            Spacer()
            
            Button(action: { Task { await startRender() } }) {
                Group {
                    if model.isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Text("EXPORT")
                    }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(minWidth: 52)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.mdPrimary)
                .cornerRadius(8)
            }
            .disabled(model.isPreparing || model.stage == .groups)
            .opacity(model.stage == .groups ? 0 : 1)
            .padding(.trailing, 12)
        }
        .foregroundColor(.primary)
        .frame(height: 50)
    }
    
    // MARK: Clips sections (android:id="clipsSection")
    
    /// Tiles in a strip (a template without groups, as before) or in a grid (a grouped one: 50 clips in one strip is no way to choose).
    @ViewBuilder
    private func tiles<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if model.hasGroups {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 10) { content() }
                .padding(12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) { content() }.padding(12)
            }
        }
    }
    
    private var importingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Importing…").font(.footnote).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    
    /// Second stage (and the only one of a template without groups): every clip.
    private var clipsSection: some View {
        ExportSection(title: "Clips") {
            if model.slots.isEmpty {
                Text("This template has no replaceable clips.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if model.hasGroups {
                    HStack(spacing: 10) {
                        Button {
                            withAnimation { model.stage = .groups }
                        } label: {
                            Label("Back to groups", systemImage: "square.grid.2x2")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Spacer()
                        Text("Tap a clip to give it other media. Same dot = same media.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                tiles {
                    ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                        clipTile(index: index, slot: slot)
                    }
                }
                if model.isImporting { importingRow }
            }
        }
    }
    
    /// First stage: one tile per group of clips that share a source, one per clip on its own.
    private var groupsSection: some View {
        ExportSection(title: "Choose media") {
            if model.slots.isEmpty {
                Text("This template has no replaceable clips.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let entries = model.entries
                tiles {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        entryTile(index: index, entry: entry)
                    }
                }
                if model.isImporting { importingRow }
            }
        }
    }
    
    /// Under the first stage's tiles: what the dots mean, and Next (once every tile has media).
    private var groupsBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(TemplateGroupPalette.color(4)).frame(width: 8, height: 8)
                Text("Clips marked with the same coloured dot use the same media. You can change single clips on the next step.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button {
                withAnimation { model.stage = .clips }
            } label: {
                Text("Next")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundColor(.white)
                    .background(model.groupsFilled ? Color.mdPrimary : Color.gray.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!model.groupsFilled)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }
    
    /// cpn_clip_replacement_element.xml: 100dp tile, centre-cropped preview, big index number. `badge`: how many clips share it.
    private func tileFace(number: Int, slot: TemplateClipSlot, badge: Int? = nil) -> some View {
        ZStack {
            if let image = slot.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipped()
                Color.black.opacity(0.25)
            } else {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.secondary.opacity(0.6))
                    .offset(y: 22)
            }
            Text("\(number)")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(slot.thumbnail == nil ? .primary : .white)
                .shadow(radius: slot.thumbnail == nil ? 0 : 2)
        }
        .frame(width: 100, height: 100)
        .overlay(alignment: .bottomLeading) {
            if slot.targetDuration > 0 {
                Text(String(format: "%.1fs", slot.targetDuration))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(5)
            }
        }
        .overlay(alignment: .topLeading) {
            if let badge, badge > 1 {
                Text("×\(badge)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            // A video that ends before the template clip does: the clip just ends early.
            if slot.kind == .video, slot.targetDuration > 0, slot.trimmedLength < slot.targetDuration - 0.05 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                    .padding(6)
            }
        }
        .cornerRadius(8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    
    /// The dot under a tile: its group's colour, hollow once the clip was given its own media. Clips on their own get
    /// an empty row, so every tile lines up.
    private func dotRow(colorIndex: Int?, hollow: Bool = false) -> some View {
        HStack {
            if let colorIndex {
                let color = TemplateGroupPalette.color(colorIndex)
                Circle()
                    .fill(hollow ? Color.clear : color)
                    .overlay(Circle().stroke(color, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
            } else {
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .frame(height: 8)
    }
    
    /// Second stage: one clip.
    private func clipTile(index: Int, slot: TemplateClipSlot) -> some View {
        VStack(spacing: 6) {
            tileFace(number: index + 1, slot: slot)
                .onTapGesture {
                    pickingIndex = index
                    pickerSelection = []
                    pickerPresented = true
                }
                .contextMenu {
                    if slot.isFilled {
                        Button { propertiesRef = SlotRef(id: index) } label: {
                            Label("Properties", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) { deleteIndex = index } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            dotRow(colorIndex: model.colorIndex(ofSlot: index), hollow: slot.detached)
        }
    }
    
    /// First stage: a group (or a clip on its own). It shows the media of its first clip that follows the group.
    private func entryTile(index: Int, entry: TemplateSlotEntry) -> some View {
        let shown = entry.members.first { !model.slots[$0].detached } ?? entry.members[0]
        let slot = model.slots[shown]
        return VStack(spacing: 6) {
            tileFace(number: index + 1, slot: slot, badge: entry.members.count)
                .onTapGesture {
                    pickingIndex = index
                    pickerSelection = []
                    pickerPresented = true
                }
                .contextMenu {
                    if slot.isFilled {
                        Button(role: .destructive) { model.clearEntry(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            dotRow(colorIndex: entry.colorIndex)
        }
    }
    
    // MARK: Log section (android:id="logSection")
    
    private var logSection: some View {
        ExportSection(title: "Log") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Task: 0%").font(.system(size: 15))
                    ProgressView(value: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remaining Task: 0/0").font(.system(size: 15))
                    ProgressView(value: 0)
                }
                
                HStack(spacing: 14) {
                    Toggle("Enable log", isOn: $model.logEnabled)
                    Toggle("Truncate log", isOn: $model.truncateLog)
                    Toggle("Scroll lock", isOn: $scrollLock)
                }
                .toggleStyle(CheckboxToggleStyle())
                .font(.system(size: 13))
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.logText.isEmpty ? "Log output will appear here." : model.logText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(model.logText.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logEnd")
                        }
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .cornerRadius(8)
                    .onChange(of: model.logText) { _ in
                        if scrollLock { proxy.scrollTo("logEnd", anchor: .bottom) }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Export Clip panel (view_template_export_properties.xml)

struct TemplateClipPropertiesSheet: View {
    @ObservedObject var model: TemplateExportModel
    let index: Int
    
    @Environment(\.dismiss) private var dismiss
    @State private var lower: Double
    @State private var upper: Double
    
    init(model: TemplateExportModel, index: Int) {
        self.model = model
        self.index = index
        let slot = model.slots.indices.contains(index) ? model.slots[index] : TemplateClipSlot()
        _lower = State(initialValue: slot.startTrim)
        _upper = State(initialValue: slot.endTrim)
    }
    
    private var slot: TemplateClipSlot {
        model.slots.indices.contains(index) ? model.slots[index] : TemplateClipSlot()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar: drag handle, title, close
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 4)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                HStack {
                    Text("Export Clip")
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
            }
            .frame(height: 56)
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Preview + titleText / dataInfoText / lengthText
                    HStack(spacing: 14) {
                        ZStack {
                            Color(uiColor: .tertiarySystemFill)
                            if let image = slot.thumbnail {
                                Image(uiImage: image).resizable().scaledToFill()
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipped()
                        .cornerRadius(10)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clip \(index + 1)")
                                .font(.system(size: 17, weight: .semibold))
                            Text(slot.typeDescription.isEmpty ? "—" : slot.typeDescription.capitalized)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(slot.kind == .video
                                 ? String(format: "%.1fs", max(0, upper - lower))
                                 : "Still image")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    ExportSection(title: "Trim Video") {
                        if slot.kind == .video, slot.mediaDuration > 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Trim").font(.system(size: 15))
                                    Spacer()
                                    Text(String(format: "%.1fs – %.1fs", lower, upper))
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                                TrimRangeSlider(lower: $lower, upper: $upper, bounds: 0...slot.mediaDuration)
                                    .frame(height: 34)
                            }
                            .padding(16)
                        } else {
                            Text(slot.kind == .video ? "This video's length couldn't be read, so it can't be trimmed."
                                                     : "Images have nothing to trim.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .onDisappear {
            // Android: the trim values are read when the panel closes (onClose).
            if slot.kind == .video, slot.mediaDuration > 0,
               lower != slot.startTrim || upper != slot.endTrim {
                model.setTrim(index, start: lower, end: upper)
            }
        }
    }
}

/// Two-thumb range slider (Material RangeSlider equivalent).
struct TrimRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    var minimumGap: Double = 0.1
    
    private let thumb: CGFloat = 26
    
    var body: some View {
        GeometryReader { proxy in
            let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
            let track = max(proxy.size.width - thumb, 1)
            let lowerX = CGFloat((lower - bounds.lowerBound) / span) * track
            let upperX = CGFloat((upper - bounds.lowerBound) / span) * track
            
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .padding(.horizontal, thumb / 2)
                Capsule()
                    .fill(Color.mdPrimary)
                    .frame(width: max(upperX - lowerX, 0), height: 4)
                    .offset(x: lowerX + thumb / 2)
                
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.mdPrimary, lineWidth: 2))
                    .shadow(radius: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: lowerX)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTrack")).onChanged { value in
                        let raw = bounds.lowerBound + Double((value.location.x - thumb / 2) / track) * span
                        lower = min(max(raw, bounds.lowerBound), upper - minimumGap)
                    })
                
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.mdPrimary, lineWidth: 2))
                    .shadow(radius: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: upperX)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTrack")).onChanged { value in
                        let raw = bounds.lowerBound + Double((value.location.x - thumb / 2) / track) * span
                        upper = max(min(raw, bounds.upperBound), lower + minimumGap)
                    })
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: "trimTrack")
        }
    }
}
