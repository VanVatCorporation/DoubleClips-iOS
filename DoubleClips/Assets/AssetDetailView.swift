import SwiftUI
import Combine

// MARK: - One asset: preview, details, and what to do with it
//
// "Get" downloads the file (login needed; it counts against YOUR daily download allowance, never the poster's) and then, by kind:
// an effect or an animation pack is installed in the app; a font, video, image or audio is added to a project you pick;
// "Save or share" hands the file to the share sheet instead. Report and "Hide this person's assets" are in the ... menu.

@MainActor
final class AssetDownload: ObservableObject {
    @Published var progress: Double?          // nil = not downloading; -1 = size unknown
    @Published var file: URL?
    var task: Task<Void, Never>?
}

struct AssetDetailView: View {
    let asset: CommunityAsset
    var onBlocked: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var download = AssetDownload()
    @State private var showSignIn = false
    @State private var showProjects = false
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var share: ActivityItem?
    @State private var notice: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AssetPreviewImage(url: asset.previewUrl, kind: asset.kindValue)
                    .aspectRatio(16.0 / 10.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(asset.title).font(.system(size: 22, weight: .bold))

                HStack(spacing: 14) {
                    Label(asset.kindValue.singular, systemImage: asset.kindValue.icon)
                    Label(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file), systemImage: "doc")
                    Label("\(asset.downloads)", systemImage: "arrow.down.circle")
                }
                .font(.system(size: 12)).foregroundColor(.secondary)

                if let owner = asset.ownerName {
                    Label(owner, systemImage: "person.circle").font(.system(size: 14, weight: .medium))
                }
                if !asset.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(asset.tags, id: \.self) { tag in
                            Text("#\(tag)").font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.mdSurfaceContainerHigh).clipShape(Capsule())
                        } }
                    }
                }
                if let text = asset.description, !text.isEmpty {
                    Text(text).font(.system(size: 14)).foregroundColor(.secondary)
                }

                actions
                Text("Posted by a member of the community. Only use what you have the right to use; report anything that shouldn't be here.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(16)
        }
        .navigationTitle(asset.kindValue.singular)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showReport = true } label: { Label("Report", systemImage: "flag") }
                    if let owner = asset.ownerName {
                        Button(role: .destructive) { confirmBlock = true } label: { Label("Hide assets from \(owner)", systemImage: "person.slash") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onDisappear { download.task?.cancel() }
        .sheet(isPresented: $showReport) { ReportAssetSheet(asset: asset) }
        .sheet(isPresented: $showProjects) {
            ProjectPickerSheet { project in
                showProjects = false
                if let file = download.file { addToProject(file, project) }
            }
        }
        .sheet(item: $share) { ActivitySheet(url: $0.url) }
        .alert("Sign in to get assets", isPresented: $showSignIn) { Button("OK", role: .cancel) {} } message: {
            Text("Sign in from the Profile tab to download assets.")
        }
        .alert("Done", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(notice ?? "") }
        .alert("Couldn't do that", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Hide assets from \(asset.ownerName ?? "")?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Hide", role: .destructive) {
                if let owner = asset.ownerName { BlockedAuthors.block(owner) }
                onBlocked()
                dismiss()
            }
        } message: { Text("Their assets won't show in the Assets tab on this phone.") }
    }

    // MARK: actions

    private var primaryTitle: String {
        switch asset.kindValue {
        case .effect: return "Install effect"
        case .pack: return "Install animation pack"
        case .font, .video, .image, .audio: return "Add to a project…"
        }
    }

    @ViewBuilder private var actions: some View {
        if let progress = download.progress {
            VStack(spacing: 8) {
                if progress >= 0 { ProgressView(value: progress) } else { ProgressView() }
                Button("Cancel", role: .cancel) { download.task?.cancel() }
            }
        } else {
            VStack(spacing: 10) {
                Button { fetch { file in primaryAction(file) } } label: {
                    Label(LocalizedStringKey(primaryTitle), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundColor(.white).background(Color.mdPrimary).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button { fetch { file in share = ActivityItem(url: file) } } label: {
                    Label("Save or share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.mdSurfaceContainerHigh).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Downloads once (a second tap reuses the file), then runs `then` with it.
    private func fetch(_ then: @escaping (URL) -> Void) {
        guard DoubleClipsDrive.sessionToken() != nil else { showSignIn = true; return }
        if let file = download.file, FileManager.default.fileExists(atPath: file.path) { then(file); return }
        guard download.progress == nil else { return }
        download.progress = -1
        let state = download
        download.task = Task {
            do {
                let url = try await AssetsClient.shared.download(asset) { loaded, total in
                    Task { @MainActor in state.progress = total > 0 ? Double(loaded) / Double(total) : -1 }
                }
                state.file = url
                state.progress = nil
                then(url)
            } catch is CancellationError {
                state.progress = nil
            } catch {
                state.progress = nil
                if (error as? URLError)?.code == .cancelled { return }
                errorText = (error as? DriveError)?.message ?? error.localizedDescription
            }
        }
    }

    private func primaryAction(_ file: URL) {
        do {
            switch asset.kindValue {
            case .effect:
                let name = try AssetLibrary.installEffect(from: file)
                notice = "“\(name)” is installed. Find it when you add an effect."
            case .pack:
                let name = try AssetLibrary.installPack(from: file)
                notice = "“\(name)” is installed. Its animations are in the animation pickers."
            case .font, .video, .image, .audio:
                showProjects = true
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addToProject(_ file: URL, _ project: ProjectData) {
        do {
            let name = try AssetLibrary.add(file, kind: asset.kindValue, to: project)
            notice = asset.kindValue == .font
                ? "“\(name)” was added to “\(project.projectTitle)”. Pick it in the text editor."
                : "“\(name)” was added to the files of “\(project.projectTitle)”."
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Pick one of my projects

struct ProjectPickerSheet: View {
    let onPick: (ProjectData) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [ProjectData] = []

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "film.stack",
                                           description: Text("Create a project in the Home tab first."))
                } else {
                    List(projects) { project in
                        Button { onPick(project) } label: {
                            HStack {
                                Text(project.projectTitle).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to a project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { projects = AssetLibrary.projects() }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Report

struct ReportAssetSheet: View {
    let asset: CommunityAsset
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "inappropriate"
    @State private var note = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var sent = false

    private let reasons: [(String, String)] = [
        ("inappropriate", "Inappropriate or offensive"), ("copyright", "Copyright: not theirs to share"),
        ("spam", "Spam or misleading"), ("malware", "Harmful or broken file"), ("other", "Something else")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Why are you reporting this?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(reasons, id: \.0) { Text(LocalizedStringKey($0.1)).tag($0.0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section("Details (optional)") {
                    TextField("What is wrong?", text: $note, axis: .vertical).lineLimit(3...6)
                }
                if let errorText { Text(errorText).foregroundColor(.red).font(.footnote) }
                Section { Text("Enough reports hide an asset until it is reviewed.").font(.footnote).foregroundColor(.secondary) }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(sending || sent)
                }
            }
            .alert("Thank you", isPresented: $sent) { Button("OK") { dismiss() } } message: { Text("Your report was sent.") }
        }
    }

    private func send() {
        guard DoubleClipsDrive.sessionToken() != nil else { errorText = L("Sign in from the Profile tab to report."); return }
        sending = true
        Task {
            do {
                try await AssetsClient.shared.report(asset, reason: reason, note: note)
                sent = true
            } catch {
                errorText = (error as? DriveError)?.message ?? error.localizedDescription
            }
            sending = false
        }
    }
}
