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

@MainActor
final class TemplateExportModel: ObservableObject {
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
    
    // MARK: Picking
    
    /// Fills slot `start`, `start + 1`, … with the picked items; leftovers are discarded (Android).
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
                try await load(item, into: index)
                index += 1
            } catch {
                log("Clip \(index + 1): couldn't load that item (\(error.localizedDescription)).")
            }
        }
    }
    
    private func load(_ item: PhotosPickerItem, into index: Int) async throws {
        let directory = Self.tempDirectory
        IOHelper.createEmptyDirectories(directory)
        removeFiles(forSlot: index)
        
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        var slot = TemplateClipSlot()
        slot.targetDuration = slots.indices.contains(index) ? slots[index].targetDuration : 0
        
        if isVideo {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw ExportError("The video could not be read.")
            }
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension.lowercased()
            let destination = URL(fileURLWithPath: IOHelper.combinePath(directory, "\(index).\(ext)"))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: movie.url, to: destination)
            
            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            slot.kind = .video
            slot.path = destination.path
            slot.fileName = destination.lastPathComponent
            slot.typeDescription = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
            slot.mediaDuration = duration.isFinite ? max(0, duration) : 0
            slot.startTrim = 0
            // The template keeps this clip on screen for `targetDuration`: start with that much of the video.
            slot.endTrim = slot.targetDuration > 0 ? min(slot.mediaDuration, slot.targetDuration) : slot.mediaDuration
            slot.thumbnail = await Self.videoThumbnail(asset)
        } else {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ExportError("The image could not be read.")
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
            let destination = URL(fileURLWithPath: IOHelper.combinePath(directory, "\(index).\(ext)"))
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
        removeFiles(forSlot: index)
        var empty = TemplateClipSlot()
        empty.targetDuration = slots[index].targetDuration
        slots[index] = empty
        log("Clip \(index + 1) cleared.")
    }
    
    func setTrim(_ index: Int, start: Double, end: Double) {
        guard slots.indices.contains(index), slots[index].kind == .video else { return }
        slots[index].startTrim = start
        slots[index].endTrim = end
        log(String(format: "Clip %d trim: %.1fs – %.1fs", index + 1, start, end))
    }
    
    private func removeFiles(forSlot index: Int) {
        let directory = Self.tempDirectory
        for url in IOHelper.listFiles(directory, options: .files)
        where url.deletingPathExtension().lastPathComponent == String(index) {
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
                    clipsSection
                    logSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
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
                      maxSelectionCount: max(1, model.slots.count - (pickingIndex ?? 0)),
                      matching: .any(of: [.images, .videos]))
        .onChange(of: pickerSelection) { items in
            guard !items.isEmpty, let start = pickingIndex else { return }
            pickerSelection = []
            pickingIndex = nil
            Task { await model.fill(from: start, with: items) }
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
            .disabled(model.isPreparing)
            .padding(.trailing, 12)
        }
        .foregroundColor(.primary)
        .frame(height: 50)
    }
    
    // MARK: Clips section (android:id="clipsSection")
    
    private var clipsSection: some View {
        ExportSection(title: "Clips") {
            if model.slots.isEmpty {
                Text("This template has no replaceable clips.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                            clipTile(index: index, slot: slot)
                        }
                    }
                    .padding(12)
                }
                if model.isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Importing…").font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }
    
    /// cpn_clip_replacement_element.xml: 100dp tile, centre-cropped preview, big index number.
    private func clipTile(index: Int, slot: TemplateClipSlot) -> some View {
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
            Text("\(index + 1)")
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
