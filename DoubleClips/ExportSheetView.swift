import SwiftUI
import UIKit
import Photos

// MARK: - Export screen (Android: ExportActivity + layout_export.xml)
//
// Same structure as Android / desktop:
//   • top bar:  back · settings (display icon) · title · EXPORT (CANCEL while rendering)
//   • "Export Settings" panel (display icon): Video Encoding (resolution, framerate, bitrate) + media option
//   • Log section: current-task status "(frame/total frames - fps frames per second) (percent%)" with its
//     progress bar, "Running tasks" bar, Enable log / Truncate log / Scroll lock, and the log text.
// Left out on purpose: FFmpeg-only controls (render-engine radio, Advanced command box, CRF, preset,
// tune, hardware-accel switch, clip cap). iOS always renders with the Core Image compositor and
// encodes with the hardware H.264 encoder.
// After a successful export, both destinations are offered: Photos library and the share sheet.

struct ExportSheetView: View {
    let project: ProjectData
    let timeline: EditingView.Timeline
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = TimelineExporter()
    @State private var settings: EditingView.VideoSettings
    @State private var showSettings = false
    @State private var scrollLock = true
    @State private var photosState: PhotosState = .idle
    @State private var showShare = false
    
    private enum PhotosState: Equatable {
        case idle, saving, saved, failed(String)
    }
    
    init(project: ProjectData, timeline: EditingView.Timeline) {
        self.project = project
        self.timeline = timeline
        _settings = State(initialValue: EditingView.VideoSettings.load(projectPath: project.projectPath))
    }
    
    private var isExporting: Bool { exporter.state == .exporting }
    
    private var plan: ExportPlan {
        ExportPlan.make(settings: settings, duration: Double(timeline.duration))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    outputSection
                    resultSection
                    logSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showSettings) {
            ExportSettingsSheet(initial: settings) { edited in
                guard !edited.sameExportFields(as: settings) else { return }
                settings = edited
                edited.persistExportEdits(projectPath: project.projectPath)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShare) {
            if case .finished(let url) = exporter.state {
                ActivityView(items: [url])
                    .ignoresSafeArea()
            }
        }
    }
    
    // MARK: Top bar (android:id="top_bar", 50dp)
    
    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 50, height: 50)
            }
            .disabled(isExporting)
            
            Button(action: { showSettings = true }) {
                Image(systemName: "display")
                    .font(.system(size: 20))
                    .frame(width: 50, height: 50)
            }
            .disabled(isExporting)
            
            Spacer()
            
            Text("Export")
                .font(.system(size: 15, weight: .bold))
            
            Spacer()
            
            Button(action: { isExporting ? exporter.cancel() : startExport() }) {
                Text(isExporting ? "CANCEL" : "EXPORT")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isExporting ? Color.red : Color.mdPrimary)
                    .cornerRadius(8)
            }
            .disabled(!isExporting && timeline.duration <= 0)
            .opacity(!isExporting && timeline.duration <= 0 ? 0.4 : 1)
            .padding(.trailing, 12)
        }
        .foregroundColor(.primary)
        .frame(height: 50)
    }
    
    // MARK: Output summary (tap to edit)
    
    private var outputSection: some View {
        ExportSection(title: "Output") {
            VStack(spacing: 0) {
                InfoRow(icon: "aspectratio", label: "Resolution", value: "\(plan.width) × \(plan.height)")
                RowDivider()
                InfoRow(icon: "speedometer", label: "Framerate", value: "\(plan.frameRate) fps")
                RowDivider()
                InfoRow(icon: "gauge.with.dots.needle.67percent", label: "Bitrate (HW)",
                        value: String(format: "%.0f Mbps", plan.bitrateMbps))
                RowDivider()
                InfoRow(icon: "arrow.up.left.and.arrow.down.right", label: "Stretch media to fit",
                        value: settings.isStretchToFull ? "On" : "Off")
                RowDivider()
                InfoRow(icon: "clock", label: "Duration", value: Self.formatDuration(Double(timeline.duration)),
                        tappable: false)
                RowDivider()
                InfoRow(icon: "film", label: "Format", value: "MP4 · H.264 + AAC", tappable: false)
                RowDivider()
                InfoRow(icon: "internaldrive", label: "Estimated size",
                        value: "≈ " + TimelineExporter.formatBytes(plan.estimatedBytes), tappable: false)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isExporting { showSettings = true } }
        }
    }
    
    // MARK: Result (destinations / errors)
    
    @ViewBuilder
    private var resultSection: some View {
        switch exporter.state {
        case .finished(let url):
            ExportSection(title: "Result") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Export complete", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        Spacer()
                        if let size = Self.fileSize(url) {
                            Text(TimelineExporter.formatBytes(size))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    photosButton(url)
                    Button { showShare = true } label: {
                        Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(14)
            }
            
        case .failed(let message):
            ExportSection(title: "Result") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            
        default:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func photosButton(_ url: URL) -> some View {
        switch photosState {
        case .idle:
            Button { saveToPhotos(url) } label: {
                Label("Save to Photos", systemImage: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(.white)
                    .background(Color.mdPrimary)
                    .cornerRadius(10)
            }
        case .saving:
            HStack(spacing: 10) {
                ProgressView()
                Text("Saving to Photos…").font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.red)
                Button("Try Photos again") { saveToPhotos(url) }
                    .buttonStyle(.bordered)
            }
        }
    }
    
    // MARK: Log section (android:id="logSection")
    
    private var logSection: some View {
        ExportSection(title: "Log") {
            VStack(alignment: .leading, spacing: 14) {
                // Current task: frame/total, fps, percent
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusLine)
                        .font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: exporter.progress)
                }
                
                // Global: running tasks (the whole render + encode is one task on iOS)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running tasks: (\(tasksDone)/1)")
                        .font(.system(size: 15))
                    ProgressView(value: Double(tasksDone))
                }
                
                HStack(spacing: 14) {
                    Toggle("Enable log", isOn: $exporter.logEnabled)
                    Toggle("Truncate log", isOn: $exporter.truncateLog)
                    Toggle("Scroll lock", isOn: $scrollLock)
                }
                .toggleStyle(CheckboxToggleStyle())
                .font(.system(size: 13))
                
                logBox
            }
            .padding(14)
        }
    }
    
    private var logBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(exporter.logText.isEmpty ? "Log output will appear here." : exporter.logText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(exporter.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .padding(8)
            }
            .frame(height: 220)
            .background(Color(uiColor: .tertiarySystemFill))
            .cornerRadius(8)
            .onChange(of: exporter.logText) { _ in
                if scrollLock { proxy.scrollTo("logEnd", anchor: .bottom) }
            }
        }
    }
    
    private var tasksDone: Int {
        if case .finished = exporter.state { return 1 }
        return 0
    }
    
    /// Android: "<task>... (frame/total frames - fps frames per second) (percent%)"
    private var statusLine: String {
        let s = exporter.stats
        switch exporter.state {
        case .idle:
            return "Current Task: 0%"
        case .exporting:
            return String(format: "%@... (%d/%d frames - %.2f frames per second) (%.1f%%)",
                          TimelineExporter.taskName, s.frame, s.totalFrames, s.fps, s.percent)
        case .finished:
            return String(format: "%@ done (%d/%d frames) (100.0%%)",
                          TimelineExporter.taskName, s.frame, max(s.totalFrames, s.frame))
        case .failed:
            return String(format: "Export failed at %d/%d frames (%.1f%%)", s.frame, s.totalFrames, s.percent)
        case .cancelled:
            return String(format: "Export cancelled at %d/%d frames (%.1f%%)", s.frame, s.totalFrames, s.percent)
        }
    }
    
    // MARK: Actions
    
    private func startExport() {
        photosState = .idle
        // Same builder as the preview player: what you saw is what gets rendered. It reads the
        // settings from project.settings, which the settings panel has already saved.
        let built = EditingView.CompositionBuilder.build(timeline: timeline,
                                                         projectDir: URL(fileURLWithPath: project.projectPath))
        let exportPlan = ExportPlan.make(settings: built.settings, duration: built.composition.duration.seconds)
        exporter.start(built: built, plan: exportPlan, fileName: Self.fileName(for: project.projectTitle))
    }
    
    private func saveToPhotos(_ url: URL) {
        photosState = .saving
        Task { @MainActor in
            do {
                try await ExportDestination.saveToPhotos(url)
                photosState = .saved
                exporter.log("Saved to Photos library.")
            } catch {
                photosState = .failed(error.localizedDescription)
                exporter.log("Saving to Photos failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: Helpers
    
    static func fileName(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "DoubleClips Export" : cleaned) + ".mp4"
    }
    
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    
    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

// MARK: - Export Settings panel (view_export_specific_video_properties.xml)

struct ExportSettingsSheet: View {
    let initial: EditingView.VideoSettings
    /// Called once when the panel closes (Android: onClose) with the parsed, clamped values.
    let onCommit: (EditingView.VideoSettings) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var width: String
    @State private var height: String
    @State private var frameRate: String
    @State private var bitrate: String
    @State private var stretch: Bool
    private enum Field: Hashable { case width, height, frameRate, bitrate }
    @FocusState private var focused: Field?
    
    init(initial: EditingView.VideoSettings, onCommit: @escaping (EditingView.VideoSettings) -> Void) {
        self.initial = initial
        self.onCommit = onCommit
        _width = State(initialValue: String(initial.videoWidth))
        _height = State(initialValue: String(initial.videoHeight))
        _frameRate = State(initialValue: String(initial.frameRate))
        _bitrate = State(initialValue: String(initial.bitrate))
        _stretch = State(initialValue: initial.isStretchToFull)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header bar: drag handle, title, close
                ZStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 36, height: 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                    HStack {
                        Text("Export Settings")
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
                        ExportSection(title: "Video Encoding") {
                            VStack(spacing: 0) {
                                SettingRow(icon: "aspectratio", label: "Resolution") {
                                    HStack(spacing: 4) {
                                        numberField("1920", text: $width, field: .width)
                                        Text("×").foregroundColor(.secondary)
                                        numberField("1080", text: $height, field: .height)
                                    }
                                }
                                RowDivider()
                                SettingRow(icon: "speedometer", label: "Framerate") {
                                    HStack(spacing: 6) {
                                        numberField("30", text: $frameRate, field: .frameRate)
                                        Text("fps").foregroundColor(.secondary)
                                    }
                                }
                                RowDivider()
                                SettingRow(icon: "gauge.with.dots.needle.67percent", label: "Bitrate (HW)") {
                                    HStack(spacing: 6) {
                                        numberField("15", text: $bitrate, field: .bitrate)
                                        Text("Mbps").foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        
                        ExportSection(title: "Media") {
                            SettingRow(icon: "arrow.up.left.and.arrow.down.right", label: "Stretch media to fit") {
                                Toggle("", isOn: $stretch).labelsHidden()
                            }
                        }
                        
                        Text("Size \(Constants.EXPORT_MIN_DIMENSION)–\(Constants.EXPORT_MAX_DIMENSION) px (odd sizes are rounded down to even) · "
                             + "\(Constants.EXPORT_MIN_FRAME_RATE)–\(Constants.EXPORT_MAX_FRAME_RATE) fps · "
                             + "\(Constants.EXPORT_MIN_BITRATE_MBPS)–\(Constants.EXPORT_MAX_BITRATE_MBPS) Mbps. "
                             + "Values outside the range are clamped. Changes also apply to the editor preview.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
        .onDisappear { commit() }
    }
    
    private func numberField(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .focused($focused, equals: field)
            .frame(width: 60)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill))
            .cornerRadius(6)
    }
    
    /// Android: ParserHelper.TryParse(field, current) — unparsable text keeps the old value.
    private func commit() {
        func parse(_ text: String, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
            let value = Int(text.trimmingCharacters(in: .whitespaces)) ?? fallback
            return min(max(value, lo), hi)
        }
        var edited = initial
        edited.videoWidth = parse(width, initial.videoWidth, Constants.EXPORT_MIN_DIMENSION, Constants.EXPORT_MAX_DIMENSION)
        edited.videoHeight = parse(height, initial.videoHeight, Constants.EXPORT_MIN_DIMENSION, Constants.EXPORT_MAX_DIMENSION)
        edited.frameRate = parse(frameRate, initial.frameRate, Constants.EXPORT_MIN_FRAME_RATE, Constants.EXPORT_MAX_FRAME_RATE)
        edited.bitrate = parse(bitrate, initial.bitrate, Constants.EXPORT_MIN_BITRATE_MBPS, Constants.EXPORT_MAX_BITRATE_MBPS)
        edited.isStretchToFull = stretch
        onCommit(edited)
    }
}

// MARK: - Reusable pieces (Android: SectionView + 52dp rows)

private struct ExportSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 16)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 50)
    }
}

private struct SettingRow<Trailing: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let trailing: Trailing
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(.mdPrimary)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15))
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

private struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var tappable: Bool = true
    
    var body: some View {
        SettingRow(icon: icon, label: label) {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.6))
                }
            }
        }
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? .mdPrimary : .secondary)
                configuration.label
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - project.settings edits

extension EditingView.VideoSettings {
    
    /// True when none of the fields the Export Settings panel edits differ.
    func sameExportFields(as other: EditingView.VideoSettings) -> Bool {
        videoWidth == other.videoWidth && videoHeight == other.videoHeight
            && frameRate == other.frameRate && bitrate == other.bitrate
            && isStretchToFull == other.isStretchToFull
    }
    
    /// Writes only the fields the panel owns into project.settings, keeping every other key in the
    /// file as is — settings written by a newer Android/desktop build are never stripped.
    func persistExportEdits(projectPath: String) {
        let path = IOHelper.combinePath(projectPath, Constants.DEFAULT_VIDEO_SETTINGS_FILENAME)
        var dict: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = existing
        } else if let data = try? JSONEncoder().encode(self),
                  let encoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = encoded      // no (readable) file yet: start from the full settings
        }
        dict["videoWidth"] = videoWidth
        dict["videoHeight"] = videoHeight
        dict["frameRate"] = frameRate
        dict["bitrate"] = bitrate
        dict["isStretchToFull"] = isStretchToFull
        guard let out = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        do {
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("[Export] Could not save project.settings: \(error)")
        }
    }
}

// MARK: - Destinations

enum ExportDestination {
    /// Adds the finished video to the Photos library. Only "add" permission is requested, so the
    /// app never gets to read the user's library.
    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError("DoubleClips isn't allowed to add to Photos. Turn it on in Settings → DoubleClips → Photos, or use Share / Save to Files.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }
}

/// UIActivityViewController for SwiftUI: AirDrop, Save to Files, Messages, other apps…
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
