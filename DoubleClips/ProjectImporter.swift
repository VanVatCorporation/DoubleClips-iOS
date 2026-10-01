import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Project import
//
// Android: ACTION_GET_CONTENT (application/zip) -> unzip straight into projects/ -> reload.
// Desktop: file chooser -> progress step -> find the new folder -> if it has project.properties
//          done, otherwise an "Invalid Project File" step (re-initialize as new / discard).
//
// This is the desktop flow, hardened where Android/desktop are loose:
//   - Extraction goes to a private staging folder first; nothing touches `projects/` until the
//     whole ZIP unpacked and verified (CRC), so a cancelled/corrupt import leaves no half-project.
//   - Never overwrites: an existing project with the same folder name makes the import
//     "Name (1)" (Android silently overwrites — importing the same ZIP twice destroyed edits).
//   - Entries with `..`, absolute paths or symlinks are rejected/skipped (zip-slip).
//   - `__MACOSX/`, `._*` and `.DS_Store` (added by Finder's Compress) are skipped.
//   - project.properties is re-anchored to the new location (the stored absolute path is from
//     another device) — same rule as ProjectData.loadProperties.
//   - Free space is checked up front, and the import can be cancelled.

struct ProjectImportProgress: Equatable {
    var fraction: Double
    var currentName: String
}

enum ProjectImporter {
    
    final class Cancellation {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
    
    /// A folder that was in the ZIP but has no usable project.properties (desktop's step 4).
    struct RecoverableFolder: Identifiable {
        let id = UUID()
        let url: URL
        var name: String {
            url.lastPathComponent.hasPrefix(ProjectImporter.stagingPrefix) ? "Recovered Project" : url.lastPathComponent
        }
    }
    
    struct Outcome {
        var imported: [ProjectData] = []
        var recoverable: [RecoverableFolder] = []
    }
    
    fileprivate static let stagingPrefix = "DoubleClipsImport-"
    
    private static var projectsDirectory: URL {
        URL(fileURLWithPath: Constants.DEFAULT_PROJECT_DIRECTORY, isDirectory: true)
    }
    
    // MARK: Import
    
    /// Blocking: call from a background queue.
    static func importZip(at zipURL: URL,
                          progress: @escaping (ProjectImportProgress) -> Void,
                          cancellation: Cancellation) throws -> Outcome {
        let fm = FileManager.default
        cleanStaleStaging()
        
        let staging = fm.temporaryDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var keepStaging = false
        defer { if !keepStaging { try? fm.removeItem(at: staging) } }
        
        let zip = try ZipArchiveReader(url: zipURL)
        
        // Plan: which entries to extract, and how many bytes that is.
        var planned: [(entry: ZipArchiveReader.Entry, components: [String])] = []
        var totalBytes: Int64 = 0
        for entry in zip.entries {
            guard let components = try safeComponents(entry.path), !entry.isSymlink else { continue }
            planned.append((entry, components))
            if !entry.isDirectory { totalBytes += Int64(entry.uncompressedSize) }
        }
        guard !planned.isEmpty else { throw ZipError.corrupt("the ZIP is empty.") }
        
        let margin: Int64 = 50 * 1024 * 1024
        if let available = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < totalBytes + margin {
            throw ZipError.notEnoughSpace(needed: totalBytes, available: available)
        }
        
        // Extract everything into staging, verifying size + CRC as it goes.
        var done: Int64 = 0
        var lastReport = Date.distantPast
        func report(_ name: String, force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.05 else { return }
            lastReport = now
            progress(ProjectImportProgress(fraction: totalBytes > 0 ? min(1, Double(done) / Double(totalBytes)) : 1,
                                           currentName: name))
        }
        report("Preparing...", force: true)
        
        let stagingComponents = staging.pathComponents
        for (entry, components) in planned {
            if cancellation.isCancelled { throw ZipError.cancelled }
            let destination = components.reduce(staging) { $0.appendingPathComponent($1) }
            // Belt and braces on top of safeComponents: the result must stay inside staging.
            // Lexical on purpose. `standardizedFileURL` consults the file system, so it strips
            // "/private" from paths that exist (staging) but not from ones that don't exist yet
            // (the file about to be written) — the two never matched and every import failed.
            let destinationComponents = destination.pathComponents
            guard destinationComponents.count > stagingComponents.count,
                  Array(destinationComponents.prefix(stagingComponents.count)) == stagingComponents,
                  !destinationComponents.dropFirst(stagingComponents.count).contains(where: { $0 == ".." || $0 == "." })
            else {
                throw ZipError.unsafePath(entry.path)
            }
            if entry.isDirectory {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            let name = components.last ?? entry.path
            try zip.extract(entry, to: destination,
                            progress: { written in done += Int64(written); report(name) },
                            isCancelled: { cancellation.isCancelled })
        }
        report("Finishing...", force: true)
        if cancellation.isCancelled { throw ZipError.cancelled }
        
        // Which folders are projects?
        var roots: [URL] = []
        var recoverable: [URL] = []
        if hasProperties(staging) {
            roots = [staging]                       // files at the ZIP root
        } else {
            let children = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if hasProperties(child) { roots.append(child) }
                else if looksLikeProject(child) { recoverable.append(child) }
            }
            if roots.isEmpty && recoverable.isEmpty && looksLikeProject(staging) { recoverable = [staging] }
        }
        
        var outcome = Outcome()
        try fm.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        
        for root in roots {
            guard ProjectData.loadProperties(from: root.path) != nil else {
                recoverable.append(root)            // properties exist but are unreadable
                continue
            }
            let isZipRoot = root == staging
            let title = ProjectData.loadProperties(from: root.path)?.projectTitle ?? ""
            let baseName = isZipRoot
                ? (ProjectData.sanitizedFolderName(title).isEmpty ? "Imported Project" : ProjectData.sanitizedFolderName(title))
                : root.lastPathComponent
            
            let (destination, suffix) = uniqueDestination(for: baseName)
            try fm.moveItem(at: root, to: destination)
            ensureSubdirectories(destination)
            
            // Re-anchors projectPath to the new location (and rewrites the file).
            guard var project = ProjectData.loadProperties(from: destination.path) else { continue }
            if suffix > 0 { project.projectTitle = "\(project.projectTitle) (\(suffix))" }
            // "Last modified" = now, so the imported project shows up at the top of the list.
            project.projectTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
            project.projectSize = Int64(IOHelper.getFileSize(destination.path))
            project.savePropertiesAtProject()
            outcome.imported.append(project)
        }
        
        outcome.recoverable = recoverable.map { RecoverableFolder(url: $0) }
        keepStaging = !outcome.recoverable.isEmpty  // the user still has to decide about those
        return outcome
    }
    
    // MARK: Recovery (desktop: ProjectRepository.recoverLegacyProject)
    
    static func recover(_ folder: RecoverableFolder) throws -> ProjectData {
        let fm = FileManager.default
        try fm.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let (destination, suffix) = uniqueDestination(for: folder.name)
        try fm.moveItem(at: folder.url, to: destination)
        ensureSubdirectories(destination)
        
        var duration: Int64 = 0
        let timelineURL = destination.appendingPathComponent(Constants.DEFAULT_TIMELINE_FILENAME)
        if let data = try? Data(contentsOf: timelineURL),
           let timeline = try? JSONDecoder().decode(EditingView.Timeline.self, from: data) {
            timeline.prepareAfterLoad()
            duration = Int64(timeline.duration * 1000)
        }
        
        let name = suffix > 0 ? "\(folder.name) (\(suffix))" : folder.name
        let project = ProjectData(projectPath: destination.path,
                                  projectTitle: "\(name) [Recovered]",
                                  projectTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                  projectSize: Int64(IOHelper.getFileSize(destination.path)),
                                  projectDuration: duration)
        project.savePropertiesAtProject()
        return project
    }
    
    static func discard(_ folder: RecoverableFolder) {
        try? FileManager.default.removeItem(at: folder.url)
    }
    
    /// Leftovers from cancelled/crashed imports or undecided recoveries.
    static func cleanStaleStaging() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(stagingPrefix) {
            try? fm.removeItem(at: item)
        }
    }
    
    // MARK: Helpers
    
    /// Normalised path components, `nil` for entries that should be skipped, throws for unsafe ones.
    static func safeComponents(_ rawPath: String) throws -> [String]? {
        if rawPath.contains("\0") { throw ZipError.unsafePath(rawPath) }
        var parts: [String] = []
        for part in rawPath.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { throw ZipError.unsafePath(rawPath) }
            parts.append(String(part))
        }
        guard let first = parts.first, let last = parts.last else { return nil }
        if first == "__MACOSX" || last == ".DS_Store" || last.hasPrefix("._") { return nil }
        return parts
    }
    
    private static func hasProperties(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(Constants.DEFAULT_PROJECT_PROPERTIES_FILENAME).path)
    }
    
    /// Not a project by itself, but clearly DoubleClips data (so "re-initialize" makes sense).
    private static func looksLikeProject(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(Constants.DEFAULT_TIMELINE_FILENAME).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(Constants.DEFAULT_VIDEO_SETTINGS_FILENAME).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY).path)
    }
    
    private static func uniqueDestination(for baseName: String) -> (url: URL, suffix: Int) {
        let fm = FileManager.default
        var candidate = projectsDirectory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 0
        while fm.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = projectsDirectory.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
        }
        return (candidate, suffix)
    }
    
    /// ZIPs don't carry empty folders; recreate what the editor expects (same as createProject).
    private static func ensureSubdirectories(_ project: URL) {
        let path = project.path
        IOHelper.createEmptyDirectories(IOHelper.combinePath(path, Constants.DEFAULT_CLIP_DIRECTORY))
        IOHelper.createEmptyDirectories(IOHelper.combinePath(path, Constants.DEFAULT_CLIP_TEMP_DIRECTORY, "frames"))
        IOHelper.createEmptyDirectories(IOHelper.combinePath(path, Constants.DEFAULT_PREVIEW_CLIP_DIRECTORY))
    }
}

// MARK: - Controller

enum ProjectImportAlert: Identifiable {
    case failed(String)
    case noProject
    case recoverable([ProjectImporter.RecoverableFolder])
    
    var id: String {
        switch self {
        case .failed(let message): return "failed-\(message)"
        case .noProject: return "none"
        case .recoverable(let folders): return "recover-" + folders.map { $0.id.uuidString }.joined()
        }
    }
    
    var title: String {
        switch self {
        case .failed: return "Import failed"
        case .noProject, .recoverable: return "Invalid Project File"
        }
    }
    
    var message: String {
        switch self {
        case .failed(let message):
            return message
        case .noProject:
            return "This ZIP doesn't seem to be a DoubleClips project."
        case .recoverable(let folders):
            let names = folders.prefix(3).map { "\"\($0.name)\"" }.joined(separator: ", ")
            return "This ZIP doesn't seem to be a complete DoubleClips project: \(names) has project data but no project.properties. You can re-initialize it as a new project, or discard it."
        }
    }
}

final class ProjectImportController: ObservableObject {
    @Published private(set) var progress: ProjectImportProgress?
    @Published var alert: ProjectImportAlert?
    private var cancellation: ProjectImporter.Cancellation?
    
    var isRunning: Bool { progress != nil }
    
    func start(zipURL: URL, onFinished: @escaping () -> Void) {
        guard progress == nil else { return }
        let cancellation = ProjectImporter.Cancellation()
        self.cancellation = cancellation
        progress = ProjectImportProgress(fraction: 0, currentName: "Preparing...")
        
        // fileImporter hands out a security-scoped URL.
        let scoped = zipURL.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if scoped { zipURL.stopAccessingSecurityScopedResource() } }
            
            var result: Result<ProjectImporter.Outcome, Error> = .failure(ZipError.io("The file couldn't be read."))
            var coordinationError: NSError?
            // Coordinated read makes iCloud Drive download a not-yet-local file first.
            NSFileCoordinator().coordinate(readingItemAt: zipURL, options: [], error: &coordinationError) { readURL in
                result = Result {
                    try ProjectImporter.importZip(
                        at: readURL,
                        progress: { p in DispatchQueue.main.async { self?.progress = p } },
                        cancellation: cancellation
                    )
                }
            }
            if let coordinationError { result = .failure(coordinationError) }
            
            DispatchQueue.main.async {
                self?.finish(result)
                onFinished()
            }
        }
    }
    
    func cancel() { cancellation?.cancel() }
    
    private func finish(_ result: Result<ProjectImporter.Outcome, Error>) {
        progress = nil
        cancellation = nil
        switch result {
        case .success(let outcome):
            if !outcome.recoverable.isEmpty {
                alert = .recoverable(outcome.recoverable)
            } else if outcome.imported.isEmpty {
                alert = .noProject
            }
        case .failure(let error):
            if case ZipError.cancelled = error { return }
            alert = .failed(error.localizedDescription)
        }
    }
    
    func recover(_ folders: [ProjectImporter.RecoverableFolder], onFinished: @escaping () -> Void) {
        do {
            for folder in folders { _ = try ProjectImporter.recover(folder) }
        } catch {
            alert = .failed(error.localizedDescription)
        }
        onFinished()
    }
    
    func discard(_ folders: [ProjectImporter.RecoverableFolder]) {
        folders.forEach(ProjectImporter.discard)
    }
}

// MARK: - UI

struct ImportProgressOverlay: View {
    @ObservedObject var controller: ProjectImportController
    
    var body: some View {
        if let p = controller.progress {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Extracting Project...")
                        .font(.system(size: 18, weight: .bold))
                    ProgressView(value: p.fraction)
                        .tint(Color.mdPrimary)
                    Text("Extracting: \(p.currentName) (\(Int(p.fraction * 100))%)")
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

/// Everything HomeView needs for importing, as one modifier: file picker, progress overlay,
/// and the error / "invalid project" alert.
struct ProjectImportModifier: ViewModifier {
    @ObservedObject var controller: ProjectImportController
    @Binding var showImporter: Bool
    let onProjectsChanged: () -> Void
    
    func body(content: Content) -> some View {
        content
            .overlay(ImportProgressOverlay(controller: controller))
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { controller.start(zipURL: url, onFinished: onProjectsChanged) }
                case .failure(let error):
                    controller.alert = .failed(error.localizedDescription)
                }
            }
            // Own host view: HomeView already chains several alerts, and SwiftUI only reliably
            // presents one alert per view.
            .background(
                Color.clear.alert(
                    controller.alert?.title ?? "",
                    isPresented: Binding(get: { controller.alert != nil },
                                         set: { if !$0 { controller.alert = nil } }),
                    presenting: controller.alert
                ) { alert in
                    switch alert {
                    case .failed, .noProject:
                        Button("OK", role: .cancel) { }
                    case .recoverable(let folders):
                        Button("Re-initialize as New Project") {
                            controller.recover(folders, onFinished: onProjectsChanged)
                        }
                        Button("Discard & Delete", role: .destructive) {
                            controller.discard(folders)
                        }
                    }
                } message: { alert in
                    Text(alert.message)
                }
            )
    }
}

extension View {
    func projectImport(controller: ProjectImportController,
                       showImporter: Binding<Bool>,
                       onProjectsChanged: @escaping () -> Void) -> some View {
        modifier(ProjectImportModifier(controller: controller, showImporter: showImporter,
                                       onProjectsChanged: onProjectsChanged))
    }
}
