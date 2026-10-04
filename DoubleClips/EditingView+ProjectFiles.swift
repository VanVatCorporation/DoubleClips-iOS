import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

// MARK: - Project files panel
//
// Android: toolbar "Files" opens a 3-column grid of <project>/Clips. Tap = add to the selected
// track (error if none is selected). Long-press = Rename / Delete / Swap (swap is a TODO there).
// A hex field creates a solid-colour image.
//
// iOS keeps all of that and goes further:
//   - Tap adds at the playhead on the selected track; with no track selected it uses the first
//     track that is free there, or makes a new one, instead of an error. Audio files become
//     AUDIO clips. The add is undoable.
//   - Each card shows its kind, duration, size and how many clips use it ("x2"); "Unused" is a
//     filter, and "Delete unused files" frees the space they take.
//   - Filter by kind, sort by newest / name / size.
//   - "Replace file" does what Android's Swap TODO describes: every clip that uses the file
//     switches to the new one (same kind only), keeping its place, trims clamped to the new length.
//   - "Import to project" copies files into the project without putting them on the timeline.
//   - Solid colour uses the system colour picker (and supports transparency).
//   - Rename keeps the extension and rejects names that are taken.
//
// Rename, replace and delete change files on disk, which earlier undo steps can't bring back, so
// those clear the undo history.

// MARK: - Model

final class ProjectFilesModel: ObservableObject {
    @Published private(set) var items: [ProjectFileItem] = []
    @Published private(set) var isLoading = false
    
    let projectPath: String
    private var durations: [String: Double] = [:]      // "name|bytes" -> seconds, survives reloads
    private var loadTask: Task<Void, Never>?
    
    init(projectPath: String) {
        self.projectPath = projectPath
    }
    
    private static func key(_ item: ProjectFileItem) -> String { "\(item.name)|\(item.bytes)" }
    
    /// Call from the main thread.
    func reload() {
        loadTask?.cancel()
        isLoading = true
        let path = projectPath
        loadTask = Task { @MainActor [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                ProjectLibrary.scan(projectPath: path)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.items = scanned.map { scannedItem -> ProjectFileItem in
                var item = scannedItem
                item.duration = self.durations[ProjectFilesModel.key(scannedItem)]
                return item
            }
            self.isLoading = false
            await self.loadDurations()
        }
    }
    
    /// Opens each video / audio file once, in the background, for the duration badge.
    @MainActor private func loadDurations() async {
        for item in items where (item.kind == .video || item.kind == .audio) && item.duration == nil {
            if Task.isCancelled { return }
            let asset = AVURLAsset(url: item.url)
            guard let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 else { continue }
            durations[ProjectFilesModel.key(item)] = time.seconds
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].duration = time.seconds
            }
        }
    }
}

// MARK: - Panel

extension EditingView {
    
    enum FileFilter: String, CaseIterable, Identifiable {
        case all = "All", video = "Video", image = "Image", audio = "Audio", unused = "Unused"
        var id: String { rawValue }
    }
    
    enum FileSort: String, CaseIterable, Identifiable {
        case newest = "Newest", name = "Name", size = "Size"
        var id: String { rawValue }
    }
    
    struct ProjectFilesPanel: View {
        let projectPath: String
        @ObservedObject var timeline: EditingView.Timeline
        let commandManager: CommandManager
        let playhead: Float
        let selectedTrackID: UUID?
        /// A clip was added: the editor selects its track and moves the playhead to its end.
        let onAdded: (EditingView.Track, EditingView.Clip) -> Void
        /// The timeline changed: the editor rebuilds the preview (which also schedules a save).
        let onChanged: () -> Void
        /// Clips were removed or replaced: the editor clears a selection that may point at them.
        let onDeselect: () -> Void
        let onClose: () -> Void
        
        @StateObject private var model: ProjectFilesModel
        @State private var filter: FileFilter = .all
        @State private var sort: FileSort = .newest
        
        @State private var isAdding = false
        @State private var busyText: String?
        @State private var toast: String?
        @State private var message: String?
        
        private enum PickerMode { case library, replace(ProjectFileItem) }
        @State private var showPicker = false
        @State private var pickerMode: PickerMode = .library
        
        @State private var showSolidSheet = false
        
        @State private var showRename = false
        @State private var renameTarget: ProjectFileItem?
        @State private var renameText = ""
        
        private enum PendingDelete { case one(ProjectFileItem), unused([ProjectFileItem]) }
        @State private var pendingDelete: PendingDelete?
        
        init(projectPath: String, timeline: EditingView.Timeline, commandManager: CommandManager,
             playhead: Float, selectedTrackID: UUID?,
             onAdded: @escaping (EditingView.Track, EditingView.Clip) -> Void,
             onChanged: @escaping () -> Void, onDeselect: @escaping () -> Void,
             onClose: @escaping () -> Void) {
            self.projectPath = projectPath
            self.timeline = timeline
            self.commandManager = commandManager
            self.playhead = playhead
            self.selectedTrackID = selectedTrackID
            self.onAdded = onAdded
            self.onChanged = onChanged
            self.onDeselect = onDeselect
            self.onClose = onClose
            _model = StateObject(wrappedValue: ProjectFilesModel(projectPath: projectPath))
        }
        
        // MARK: Derived
        
        private func usesFile(_ clip: EditingView.Clip, _ name: String) -> Bool {
            clip.clipName == name && (clip.type == .video || clip.type == .image || clip.type == .audio)
        }
        
        private var usage: [String: Int] {
            var counts: [String: Int] = [:]
            for track in timeline.tracks {
                for clip in track.clips where clip.type == .video || clip.type == .image || clip.type == .audio {
                    counts[clip.clipName, default: 0] += 1
                }
            }
            return counts
        }
        
        private func visibleItems(_ counts: [String: Int]) -> [ProjectFileItem] {
            var list = model.items.filter { item in
                switch filter {
                case .all: return true
                case .video: return item.kind == .video
                case .image: return item.kind == .image
                case .audio: return item.kind == .audio
                case .unused: return (counts[item.name] ?? 0) == 0
                }
            }
            switch sort {
            case .newest: list.sort { $0.modified > $1.modified }
            case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .size: list.sort { $0.bytes > $1.bytes }
            }
            return list
        }
        
        // MARK: Body
        
        var body: some View {
            let counts = usage
            let visible = visibleItems(counts)
            let unused = model.items.filter { (counts[$0.name] ?? 0) == 0 }
            
            VStack(spacing: 0) {
                header(counts: counts, unused: unused)
                filterBar
                content(visible: visible, counts: counts)
            }
            .frame(height: 300)
            .background(Color(hex: "#111111"))
            .overlay(alignment: .bottom) { toastView }
            .overlay { busyView }
            .transition(.move(edge: .bottom))
            .onAppear { model.reload() }
            // Each presentation sits on its own host view: SwiftUI only reliably presents one
            // sheet / alert / dialog per view.
            .background(Color.clear.fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.audiovisualContent, .image],
                allowsMultipleSelection: isLibraryPicker
            ) { result in handlePicked(result) })
            .background(Color.clear.sheet(isPresented: $showSolidSheet) {
                SolidColorSheet { color in createSolid(color) }
            })
            .background(Color.clear.alert("Rename file", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { }
                Button("Rename") { if let target = renameTarget { performRename(target, typed: renameText) } }
            } message: {
                Text("The extension stays the same.")
            })
            .background(Color.clear.alert("Project Files", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(message ?? "")
            })
            .background(Color.clear.confirmationDialog(
                deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { confirmDelete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(deleteMessage(counts))
            })
        }
        
        private var isLibraryPicker: Bool {
            if case .library = pickerMode { return true }
            return false
        }
        
        // MARK: Header / filters
        
        private func header(counts: [String: Int], unused: [ProjectFileItem]) -> some View {
            let total = model.items.reduce(Int64(0)) { $0 + $1.bytes }
            var summary = "\(model.items.count) files · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            if !unused.isEmpty { summary += " · \(unused.count) unused" }
            
            return HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Project Files")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                
                Menu {
                    Button { pick(.library) } label: {
                        Label("Import to project…", systemImage: "square.and.arrow.down")
                    }
                    Button { showSolidSheet = true } label: {
                        Label("Solid colour image…", systemImage: "square.fill")
                    }
                } label: { headerIcon("plus") }
                
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(FileSort.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                } label: { headerIcon("arrow.up.arrow.down") }
                
                Menu {
                    Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { pendingDelete = .unused(unused) } label: {
                        Label("Delete unused files…", systemImage: "trash")
                    }
                    .disabled(unused.isEmpty)
                } label: { headerIcon("ellipsis.circle") }
                
                Button(action: onClose) {
                    Image(systemName: "checkmark")
                        .foregroundColor(Color.mdPrimary)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color(hex: "#1A1A1A"))
        }
        
        private func headerIcon(_ symbol: String) -> some View {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
        }
        
        private var filterBar: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FileFilter.allCases) { option in
                        Button { filter = option } label: {
                            Text(option.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(filter == option ? .white : .white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(filter == option ? Color.mdPrimary : Color.white.opacity(0.1)))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        
        // MARK: Grid
        
        @ViewBuilder
        private func content(visible: [ProjectFileItem], counts: [String: Int]) -> some View {
            if model.items.isEmpty {
                emptyState(model.isLoading ? "Loading…" : "No media in this project yet.\nTap + to import files.")
            } else if visible.isEmpty {
                emptyState("Nothing matches this filter.")
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                             count: Constants.PROJECT_FILES_GRID_COLUMNS),
                              spacing: 10) {
                        ForEach(visible) { item in
                            card(item, used: counts[item.name] ?? 0)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        
        private func emptyState(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        
        private func card(_ item: ProjectFileItem, used: Int) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                ProjectFileThumbnail(item: item)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                            .padding(3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if used > 0 {
                            Text("×\(used)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.mdPrimary))
                                .padding(3)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let seconds = item.duration {
                            Text(durationText(seconds))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.65)))
                                .padding(3)
                        }
                    }
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
            }
            .contentShape(Rectangle())
            .onTapGesture { addToTimeline(item) }
            .contextMenu {
                Button { addToTimeline(item) } label: {
                    Label("Add to timeline", systemImage: "plus.rectangle.on.rectangle")
                }
                Button { beginRename(item) } label: { Label("Rename", systemImage: "pencil") }
                Button { pick(.replace(item)) } label: {
                    Label("Replace file…", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { pendingDelete = .one(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        
        private func durationText(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        
        // MARK: Overlays
        
        @ViewBuilder private var toastView: some View {
            if let text = toast {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        
        @ViewBuilder private var busyView: some View {
            if let text = busyText {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(text).font(.system(size: 12)).foregroundColor(.white)
                    }
                }
            }
        }
        
        private func showToast(_ text: String) {
            withAnimation { toast = text }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if toast == text { withAnimation { toast = nil } }
            }
        }
        
        // MARK: Add to timeline
        
        private func isFree(_ track: EditingView.Track, from start: Float, length: Float) -> Bool {
            !track.clips.contains { $0.startTime < start + length && $0.startTime + $0.duration > start }
        }
        
        private func addToTimeline(_ item: ProjectFileItem) {
            guard !isAdding, busyText == nil else { return }
            isAdding = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { @MainActor in
                let info = await MediaProbe.probe(item.url)
                place(item, info: info)
                isAdding = false
            }
        }
        
        private func place(_ item: ProjectFileItem, info: MediaInfo) {
            guard info.kind != .other else {
                message = "\"\(item.name)\" can't be read as media."
                return
            }
            let type: EditingView.ClipType = info.kind == .audio ? .audio : (info.kind == .image ? .image : .video)
            let length = max(0.5, info.duration)
            let start = max(0, playhead)
            
            var createdTrack = false
            let track: EditingView.Track
            if let id = selectedTrackID, let selected = timeline.tracks.first(where: { $0.id == id }) {
                track = selected
            } else if let free = timeline.tracks.first(where: { isFree($0, from: start, length: length) }) {
                track = free
            } else {
                track = EditingView.Track(timelineIndex: timeline.tracks.count)
                createdTrack = true
            }
            
            let clip = EditingView.Clip(
                clipName: item.name, startTime: start, duration: length,
                trackIndex: track.timelineIndex, type: type,
                isClipHasAudio: info.hasAudio || type == .audio,
                width: info.width, height: info.height)
            
            let timeline = self.timeline
            let changed = self.onChanged
            let isNewTrack = createdTrack
            
            onAdded(track, clip)
            commandManager.execute(GenericCommand(
                description: "Add \(item.name)",
                undo: {
                    track.removeClip(clip)
                    if isNewTrack { timeline.tracks.removeAll { $0.id == track.id } }
                    timeline.recalculateDuration()
                    changed()
                },
                redo: {
                    if isNewTrack, !timeline.tracks.contains(where: { $0.id == track.id }) {
                        timeline.tracks.append(track)
                    }
                    track.addClip(clip)
                    timeline.recalculateDuration()
                    changed()
                }))
            showToast("Added to Track \(track.timelineIndex + 1)")
        }
        
        // MARK: Rename
        
        private func beginRename(_ item: ProjectFileItem) {
            renameTarget = item
            renameText = (item.name as NSString).deletingPathExtension
            showRename = true
        }
        
        private func performRename(_ item: ProjectFileItem, typed: String) {
            switch ProjectLibrary.validatedName(typed, extension: item.url.pathExtension) {
            case .failure(let error):
                message = error.localizedDescription
            case .success(let newName):
                guard newName != item.name else { return }
                do {
                    try ProjectLibrary.rename(from: item.name, to: newName, projectPath: projectPath)
                } catch {
                    message = error.localizedDescription
                    return
                }
                for track in timeline.tracks {
                    for clip in track.clips where usesFile(clip, item.name) { clip.clipName = newName }
                }
                commandManager.clearHistory()
                model.reload()
                onChanged()
                showToast("Renamed to \(newName)")
            }
        }
        
        // MARK: Delete
        
        private var deleteTitle: String {
            switch pendingDelete {
            case .one(let item): return "Delete \(item.name)?"
            case .unused(let items): return "Delete \(items.count) unused file\(items.count == 1 ? "" : "s")?"
            case nil: return "Delete?"
            }
        }
        
        private func deleteMessage(_ counts: [String: Int]) -> String {
            switch pendingDelete {
            case .one(let item):
                let used = counts[item.name] ?? 0
                return used > 0
                    ? "It is used by \(used) clip\(used == 1 ? "" : "s") on the timeline, which will be removed too. This can't be undone."
                    : "This can't be undone."
            case .unused(let items):
                let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
                return "Frees \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). No clip uses them. This can't be undone."
            case nil:
                return ""
            }
        }
        
        private func confirmDelete() {
            guard let pending = pendingDelete else { return }
            pendingDelete = nil
            let path = projectPath
            
            var names: [String] = []
            switch pending {
            case .one(let item): names = [item.name]
            case .unused(let items): names = items.map { $0.name }
            }
            
            var removedClips = 0
            for track in timeline.tracks {
                let doomed = track.clips.filter { clip in names.contains { usesFile(clip, $0) } }
                for clip in doomed { track.removeClip(clip) }
                removedClips += doomed.count
            }
            for name in names { ProjectLibrary.delete(name: name, projectPath: path) }
            
            timeline.recalculateDuration()
            commandManager.clearHistory()
            if removedClips > 0 { onDeselect() }
            model.reload()
            onChanged()
            showToast(names.count == 1 ? "Deleted \(names[0])" : "Deleted \(names.count) files")
        }
        
        // MARK: Import / replace
        
        private func pick(_ mode: PickerMode) {
            pickerMode = mode
            showPicker = true
        }
        
        private func handlePicked(_ result: Result<[URL], Error>) {
            switch result {
            case .failure(let error):
                message = error.localizedDescription
            case .success(let urls):
                guard !urls.isEmpty else { return }
                switch pickerMode {
                case .library: importToLibrary(urls)
                case .replace(let old): if let url = urls.first { replaceFile(old, with: url) }
                }
            }
        }
        
        private func importToLibrary(_ urls: [URL]) {
            busyText = "Importing…"
            let path = projectPath
            Task { @MainActor in
                var imported = 0
                var failure: String?
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        _ = try await Task.detached(priority: .userInitiated) {
                            try ProjectLibrary.copyIn(url, projectPath: path)
                        }.value
                        imported += 1
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                busyText = nil
                model.reload()
                if let failure { message = failure }
                if imported > 0 { showToast("Imported \(imported) file\(imported == 1 ? "" : "s")") }
            }
        }
        
        /// Points a clip at a new file. Returns true when the clip had to be shortened.
        private func repoint(_ clip: EditingView.Clip, to name: String, info: MediaInfo) -> Bool {
            clip.clipName = name
            var shortened = false
            if info.kind == .video || info.kind == .audio {
                let source = info.duration
                clip.originalDuration = source
                if clip.startClipTrim >= source - 0.1 { clip.startClipTrim = 0 }
                let room = max(0.1, source - clip.startClipTrim)
                if clip.duration > room {
                    clip.duration = room
                    shortened = true
                }
                clip.endClipTrim = max(0, source - clip.startClipTrim - clip.duration)
            }
            if info.kind != .audio {
                clip.width = info.width
                clip.height = info.height
            }
            if info.kind == .video { clip.isClipHasAudio = info.hasAudio }
            return shortened
        }
        
        private func replaceFile(_ old: ProjectFileItem, with url: URL) {
            busyText = "Replacing…"
            let path = projectPath
            Task { @MainActor in
                defer { busyText = nil }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                
                let info = await MediaProbe.probe(url)
                guard info.kind == old.kind else {
                    let kind = old.kind.title.lowercased()
                    message = "A \(kind) clip can only be replaced by another \(kind) file."
                    return
                }
                
                let newName: String
                do {
                    newName = try await Task.detached(priority: .userInitiated) {
                        try ProjectLibrary.replace(oldName: old.name, with: url, projectPath: path)
                    }.value
                } catch {
                    message = error.localizedDescription
                    return
                }
                
                var updated = 0, shortened = 0
                for track in timeline.tracks {
                    for clip in track.clips where usesFile(clip, old.name) {
                        if repoint(clip, to: newName, info: info) { shortened += 1 }
                        updated += 1
                    }
                }
                if newName != old.name { ProjectLibrary.delete(name: old.name, projectPath: path) }
                
                timeline.recalculateDuration()
                commandManager.clearHistory()
                if updated > 0 { onDeselect() }
                model.reload()
                onChanged()
                
                var text = updated == 0 ? "Replaced \(old.name)"
                    : "Replaced in \(updated) clip\(updated == 1 ? "" : "s")"
                if shortened > 0 { text += " · \(shortened) shortened to fit" }
                showToast(text)
            }
        }
        
        // MARK: Solid colour
        
        private func createSolid(_ color: UIColor) {
            do {
                let name = try ProjectLibrary.createSolidColorImage(color, projectPath: projectPath)
                model.reload()
                showToast("Created \(name)")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Thumbnail

struct ProjectFileThumbnail: View {
    let item: ProjectFileItem
    @State private var image: UIImage?
    
    var body: some View {
        Color(hex: "#222222")
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                ZStack {
                    if item.kind == .audio {
                        LinearGradient(colors: [Color(hex: "#0D1B2A"), Color(hex: "#1B3A5C")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "waveform")
                            .font(.system(size: 24))
                            .foregroundColor(Color(red: 0x1E / 255, green: 0x90 / 255, blue: 0xFF / 255))
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()           // crop, never stretch (portrait clips)
                    } else {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            )
            .clipped()
            .task(id: "\(item.name)|\(item.bytes)|\(item.modified.timeIntervalSince1970)") {
                guard item.kind != .audio else { return }
                image = await ClipMediaCache.shared.thumbnail(url: item.url, isVideo: item.kind == .video, time: 0)
            }
    }
}

// MARK: - Solid colour sheet

private struct SolidColorSheet: View {
    let onCreate: (UIColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var color: Color = .black
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Solid colour image")
                .font(.headline)
            RoundedRectangle(cornerRadius: 10)
                .fill(color)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.5), lineWidth: 1))
            ColorPicker("Colour", selection: $color, supportsOpacity: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Create") {
                    onCreate(UIColor(color))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .presentationDetents([.height(320)])
    }
}
