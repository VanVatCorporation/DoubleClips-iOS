import SwiftUI
import UIKit
import Photos

// MARK: - Export sheet (Android: ExportActivity)
//
// Opened by the EXPORT button in the editor's top bar. Shows what will be rendered (taken from
// project.settings, like Android), lets you pick a quality, renders with `TimelineExporter`, then
// offers both destinations: Photos library and the share sheet (Files, AirDrop, other apps).

struct ExportSheetView: View {
    let project: ProjectData
    let timeline: EditingView.Timeline
    let settings: EditingView.VideoSettings
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = TimelineExporter()
    @State private var quality: ExportQuality = .standard
    @State private var photosState: PhotosState = .idle
    @State private var showShare = false
    
    private enum PhotosState: Equatable {
        case idle, saving, saved, failed(String)
    }
    
    private var isExporting: Bool { exporter.state == .exporting }
    private var isFinished: Bool {
        if case .finished = exporter.state { return true }
        return false
    }
    
    private var plan: ExportPlan {
        ExportPlan.make(settings: settings, quality: quality, duration: Double(timeline.duration))
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCard
                    
                    // Quality is locked in once a file exists; "Export again" starts over.
                    if !isFinished {
                        qualityPicker
                    }
                    
                    stateContent
                }
                .padding(20)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isExporting)
                }
            }
        }
        .interactiveDismissDisabled(isExporting)
        .sheet(isPresented: $showShare) {
            if case .finished(let url) = exporter.state {
                ActivityView(items: [url])
                    .ignoresSafeArea()
            }
        }
    }
    
    // MARK: Pieces
    
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.projectTitle)
                .font(.headline)
                .lineLimit(2)
            Divider()
            summaryRow("Resolution", "\(plan.width) × \(plan.height)")
            summaryRow("Frame rate", "\(plan.frameRate) fps")
            summaryRow("Duration", Self.formatDuration(Double(timeline.duration)))
            summaryRow("Format", "MP4 · H.264 + AAC")
            summaryRow("Estimated size", "≈ " + TimelineExporter.formatBytes(plan.estimatedBytes))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
    
    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Quality", selection: $quality) {
                ForEach(ExportQuality.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isExporting)
        }
    }
    
    @ViewBuilder
    private var stateContent: some View {
        switch exporter.state {
        case .idle:
            primaryButton("Start export", systemImage: "square.and.arrow.up") { startExport() }
                .disabled(timeline.duration <= 0)
            if timeline.duration <= 0 {
                note("Add a clip to the timeline to export.")
            }
            
        case .exporting:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: exporter.progress)
                HStack {
                    Text("Rendering… \(Int(exporter.progress * 100))%")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                note("Keep DoubleClips open and the screen on until it finishes.")
            }
            Button(role: .destructive) { exporter.cancel() } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
        case .finished(let url):
            VStack(alignment: .leading, spacing: 6) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundColor(.green)
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
            
            Button("Export again") {
                photosState = .idle
                exporter.reset()
            }
            .font(.subheadline)
            
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundColor(.red)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            primaryButton("Try again", systemImage: "arrow.clockwise") { startExport() }
            
        case .cancelled:
            note("Export cancelled.")
            primaryButton("Start again", systemImage: "arrow.clockwise") { startExport() }
        }
    }
    
    @ViewBuilder
    private func photosButton(_ url: URL) -> some View {
        switch photosState {
        case .idle:
            primaryButton("Save to Photos", systemImage: "photo.on.rectangle") { saveToPhotos(url) }
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
                primaryButton("Try Photos again", systemImage: "arrow.clockwise") { saveToPhotos(url) }
            }
        }
    }
    
    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(Color.mdPrimary)
                .cornerRadius(10)
        }
    }
    
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
    }
    
    // MARK: Actions
    
    private func startExport() {
        photosState = .idle
        // Same builder as the preview player: what you saw is what gets rendered.
        let built = EditingView.CompositionBuilder.build(timeline: timeline,
                                                         projectDir: URL(fileURLWithPath: project.projectPath))
        let exportPlan = ExportPlan.make(settings: built.settings, quality: quality,
                                         duration: built.composition.duration.seconds)
        exporter.start(built: built, plan: exportPlan, fileName: Self.fileName(for: project.projectTitle))
    }
    
    private func saveToPhotos(_ url: URL) {
        photosState = .saving
        Task { @MainActor in
            do {
                try await ExportDestination.saveToPhotos(url)
                photosState = .saved
            } catch {
                photosState = .failed(error.localizedDescription)
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
