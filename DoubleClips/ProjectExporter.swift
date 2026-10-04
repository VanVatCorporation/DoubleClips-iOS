import SwiftUI
import UIKit
import Combine

// MARK: - Project export (share as ZIP)
//
// Android: ACTION_CREATE_DOCUMENT -> ProgressCompressionHelper.zipFolder(project folder).
// Desktop: ProjectShare.share -> save dialog -> CompressionHelper.zipFolder(project folder).
//
// Both put the project FOLDER itself as the zip's top-level entry (`project_3/project.timeline`,
// `project_3/Clips/...`), which is exactly what every importer expects, so a ZIP made here opens
// on Android, desktop and iOS, and ZIPs from those open here (ProjectImporter).
//
// iOS has no "create document" picker that fits, so this does what iOS does everywhere else:
// build the ZIP in the temporary directory, then hand it to the share sheet (AirDrop, Save to
// Files, Messages, other apps).
//
// Differences from Android/desktop, on purpose:
//   - `Clips/Temp` (the frame cache) is left out — Android's own export wipes that folder, and it
//     only holds regenerable data (Constants.PROJECT_ZIP_EXCLUDE_TEMP to include it).
//   - Already-compressed media is STORED instead of deflated (faster, no size gain from deflate).
//   - Free space is checked up front; cancel and every failure delete the half-written ZIP.
//   - The finished ZIP's directory is read back with ZipArchiveReader as a sanity check.
//   - The desktop's `ffmpegCmd.txt` is not written (ffmpegCommand is deprecated).

enum ProjectExporter {
    
    struct Progress: Equatable {
        var fraction: Double
        var currentName: String
    }
    
    private struct PlannedFile {
        let url: URL
        let entryPath: String
        let size: Int64
        let modified: Date?
    }
    
    /// Where finished ZIPs wait to be shared (cleared at launch and before the next export).
    static var shareDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Constants.SHARE_TEMP_DIRECTORY, isDirectory: true)
    }
    
    /// Desktop's suggested name: export_<title>.zip, with characters file systems reject replaced.
    static func suggestedFileName(for title: String) -> String {
        let name = ProjectData.sanitizedFolderName(title)
        return "export_" + (name.isEmpty ? "project" : name) + ".zip"
    }
    
    static func cleanOldFiles() {
        try? FileManager.default.removeItem(at: shareDirectory)
    }
    
    // MARK: Export
    
    /// Blocking: call from a background queue. Returns the ZIP's URL.
    static func exportZip(project: ProjectData,
                          progress: @escaping (Progress) -> Void,
                          cancellation: ProjectImporter.Cancellation) throws -> URL {
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: project.projectPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ZipError.io("The project folder no longer exists.")
        }
        let rootName = projectURL.lastPathComponent
        
        // Plan: every file that goes in, and how many bytes that is.
        var planned: [PlannedFile] = []
        try collect(directory: projectURL, relative: [], root: rootName, into: &planned, cancellation: cancellation)
        guard !planned.isEmpty else { throw ZipError.io("The project folder is empty.") }
        let totalBytes = planned.reduce(Int64(0)) { $0 + $1.size }
        
        cleanOldFiles()
        try fm.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        
        let margin: Int64 = 50 * 1024 * 1024
        if let available = try? shareDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < totalBytes + margin {
            throw ZipError.notEnoughSpace(needed: totalBytes, available: available)
        }
        
        let output = shareDirectory.appendingPathComponent(suggestedFileName(for: project.projectTitle))
        let writer = try ZipArchiveWriter(url: output)
        
        var done: Int64 = 0
        var lastReport = Date.distantPast
        func report(_ name: String, force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.05 else { return }
            lastReport = now
            progress(Progress(fraction: totalBytes > 0 ? min(1, Double(done) / Double(totalBytes)) : 1,
                              currentName: name))
        }
        report("Preparing...", force: true)
        
        do {
            for file in planned {
                if cancellation.isCancelled { throw ZipError.cancelled }
                let name = file.url.lastPathComponent
                try writer.addFile(at: file.url, as: file.entryPath, modified: file.modified,
                                   store: shouldStore(file.url),
                                   progress: { read in done += Int64(read); report(name) },
                                   isCancelled: { cancellation.isCancelled })
            }
            report("Finishing...", force: true)
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
        
        // Sanity check: the directory we just wrote must parse and list every entry.
        do {
            let check = try ZipArchiveReader(url: output)
            guard check.entries.count == planned.count else {
                throw ZipError.corrupt("the ZIP lists \(check.entries.count) files instead of \(planned.count).")
            }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
        return output
    }
    
    // MARK: Helpers
    
    private static func collect(directory: URL, relative: [String], root: String,
                                into list: inout [PlannedFile],
                                cancellation: ProjectImporter.Cancellation) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw ZipError.io("Couldn't read the project folder: \(error.localizedDescription)")
        }
        let excluded = Constants.DEFAULT_CLIP_TEMP_DIRECTORY.split(separator: "/").map(String.init)
        
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if cancellation.isCancelled { throw ZipError.cancelled }
            let name = item.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            
            let path = relative + [name]
            if values?.isDirectory == true {
                if Constants.PROJECT_ZIP_EXCLUDE_TEMP && path == excluded { continue }
                try collect(directory: item, relative: path, root: root, into: &list, cancellation: cancellation)
            } else {
                list.append(PlannedFile(url: item,
                                        entryPath: ([root] + path).joined(separator: "/"),
                                        size: Int64(values?.fileSize ?? 0),
                                        modified: values?.contentModificationDate))
            }
        }
    }
    
    private static func shouldStore(_ url: URL) -> Bool {
        Constants.PROJECT_ZIP_STORED_EXTENSIONS.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Controller

struct SharedProjectFile: Identifiable {
    let id = UUID()
    let url: URL
}

final class ProjectShareController: ObservableObject {
    @Published private(set) var progress: ProjectExporter.Progress?
    @Published var shared: SharedProjectFile?
    @Published var errorMessage: String?
    private var cancellation: ProjectImporter.Cancellation?
    
    var isRunning: Bool { progress != nil }
    
    init() {
        // The controller is created at launch: nothing can be mid-share, so old ZIPs can go.
        ProjectExporter.cleanOldFiles()
    }
    
    func start(project: ProjectData) {
        guard progress == nil else { return }
        let cancellation = ProjectImporter.Cancellation()
        self.cancellation = cancellation
        progress = ProjectExporter.Progress(fraction: 0, currentName: "Preparing...")
        // Zipping a big project takes a while: don't let the screen lock under it.
        UIApplication.shared.isIdleTimerDisabled = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ProjectExporter.exportZip(
                    project: project,
                    progress: { p in DispatchQueue.main.async { self?.progress = p } },
                    cancellation: cancellation
                )
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }
    
    func cancel() { cancellation?.cancel() }
    
    private func finish(_ result: Result<URL, Error>) {
        progress = nil
        cancellation = nil
        UIApplication.shared.isIdleTimerDisabled = false
        switch result {
        case .success(let url):
            shared = SharedProjectFile(url: url)
        case .failure(let error):
            if case ZipError.cancelled = error { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - UI

struct ShareProgressOverlay: View {
    @ObservedObject var controller: ProjectShareController
    
    var body: some View {
        if let p = controller.progress {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Compressing Project...")
                        .font(.system(size: 18, weight: .bold))
                    ProgressView(value: p.fraction)
                        .tint(Color.mdPrimary)
                    Text("Compressing: \(p.currentName) (\(Int(p.fraction * 100))%)")
                        .font(.system(size: 12))
                        .foregroundColor(Color.mdOnSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Cancel", role: .cancel) { controller.cancel() }
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(24)
                .frame(maxWidth: 340)
                .background(Color.mdSurface)
                .cornerRadius(20)
                .padding(32)
            }
            .transition(.opacity)
        }
    }
}

/// Everything HomeView needs for sharing a project, as one modifier: progress overlay, share
/// sheet and error alert (each in its own host view, since HomeView already chains several
/// sheets and alerts and SwiftUI only reliably presents one of each per view).
struct ProjectShareModifier: ViewModifier {
    @ObservedObject var controller: ProjectShareController
    
    func body(content: Content) -> some View {
        content
            .overlay(ShareProgressOverlay(controller: controller))
            .background(
                Color.clear.sheet(item: $controller.shared) { file in
                    ActivityView(items: [file.url])
                        .ignoresSafeArea()
                        .presentationDetents([.medium, .large])
                }
            )
            .background(
                Color.clear.alert(
                    "Couldn't share project",
                    isPresented: Binding(get: { controller.errorMessage != nil },
                                         set: { if !$0 { controller.errorMessage = nil } })
                ) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(controller.errorMessage ?? "")
                }
            )
    }
}

extension View {
    func projectShare(controller: ProjectShareController) -> some View {
        modifier(ProjectShareModifier(controller: controller))
    }
}
