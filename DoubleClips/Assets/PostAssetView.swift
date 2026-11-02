import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Post an asset
//
// 1. Pick the file: one already in my OpenEditz folder, or one from Files (it is uploaded to OpenEditz/Assets first).
// 2. Describe it: kind (guessed from the file), title, tags, description. A preview picture is made from the file when it can be (image,
//    a frame of a video, a font sample), or picked from Photos.
// 3. Confirm: posting shares the file with "anyone with the link" (view only) and lists it here. Restrict it later from My assets,
//    Drive or OpenEditz and it leaves the tab.

struct PostAssetView: View {
    var onPosted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var node: DriveNode?                 // a file already in OpenEditz
    @State private var local: URL?                      // a file picked from Files (uploaded on Post)
    @State private var kind: AssetKind = .image
    @State private var title = ""
    @State private var tags = ""
    @State private var text = ""
    @State private var preview: Data?
    @State private var photo: PhotosPickerItem?
    @State private var rights = false
    @State private var showPicker = false
    @State private var showImporter = false
    @State private var working: String?
    @State private var errorText: String?

    private var fileName: String? { node?.name ?? local?.lastPathComponent }
    private var canPost: Bool { fileName != nil && rights && title.trimmingCharacters(in: .whitespaces).count >= 2 && working == nil }

    static func splitTags(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    if let fileName {
                        Label(fileName, systemImage: "doc").lineLimit(1)
                    }
                    Button { showPicker = true } label: { Label("Choose from OpenEditz", systemImage: "externaldrive") }
                    Button { showImporter = true } label: { Label("Choose from Files", systemImage: "folder") }
                }
                if fileName != nil {
                    Section("Details") {
                        Picker("Kind", selection: $kind) {
                            ForEach(AssetKind.allCases) { Text(LocalizedStringKey($0.singular)).tag($0) }
                        }
                        TextField("Title", text: $title)
                        TextField("Tags (comma separated)", text: $tags).textInputAutocapitalization(.never)
                        TextField("Description (optional)", text: $text, axis: .vertical).lineLimit(2...6)
                    }
                    Section("Preview picture") {
                        if let preview, let image = UIImage(data: preview) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(preview == nil ? "Choose a picture" : "Change the picture", systemImage: "photo")
                        }
                    }
                    Section {
                        Toggle("I own this file or have the right to share it", isOn: $rights).tint(Color.mdPrimary)
                    } footer: {
                        Text("Posting shares the file with \"anyone with the link\" (view only) and lists it in the Assets tab for everyone. You can restrict it any time from My assets, Drive or OpenEditz.")
                    }
                }
                if let errorText { Section { Text(errorText).foregroundColor(.red).font(.footnote) } }
            }
            .navigationTitle("Post an asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working != nil) }
                ToolbarItem(placement: .confirmationAction) { Button("Post") { post() }.disabled(!canPost) }
            }
            .overlay {
                if let working {
                    VStack(spacing: 10) { ProgressView(); Text(LocalizedStringKey(working)).font(.footnote) }
                        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .sheet(isPresented: $showPicker) {
                OpenEditzFilePicker { picked in
                    node = picked; local = nil
                    adopt(name: picked.name, file: nil)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // copy out of the security scope: the upload happens later
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("post-\(UUID().uuidString)-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    local = copy; node = nil
                    adopt(name: url.lastPathComponent, file: copy)
                } catch { errorText = error.localizedDescription }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let jpeg = AssetPreviewMaker.jpeg(from: image) { preview = jpeg }
                }
            }
        }
    }

    /// A newly chosen file: guess the kind, suggest a title, make the preview picture when the file is here.
    private func adopt(name: String, file: URL?) {
        errorText = nil
        if let detected = AssetKind.detect(fileName: name) { kind = detected }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = (name as NSString).deletingPathExtension }
        preview = nil
        if let file { Task { preview = await AssetPreviewMaker.jpeg(for: file, kind: kind) } }
    }

    private func post() {
        guard fileName != nil else { return }
        errorText = nil
        working = "Posting…"
        Task {
            defer { working = nil }
            do {
                var target = node
                if target == nil, let local {
                    working = "Uploading to OpenEditz…"
                    let folder = try await DoubleClipsDrive.openEditz.ensureFolder(path: ["Assets"])
                    target = try await DoubleClipsDrive.openEditz.upload(fileURL: local, into: folder)
                    try? FileManager.default.removeItem(at: local)
                }
                guard let target else { return }
                working = "Posting…"
                let asset = try await AssetsClient.shared.publish(node: target, kind: kind, title: title.trimmingCharacters(in: .whitespaces),
                                                                  description: text, tags: Self.splitTags(tags))
                if let preview { try? await AssetsClient.shared.uploadPreview(assetId: asset.id, jpeg: preview) }
                onPosted()
            } catch {
                errorText = (error as? DriveError)?.message ?? error.localizedDescription
            }
        }
    }
}

// MARK: - A file in my OpenEditz folder

struct OpenEditzFilePicker: View {
    let onPick: (DriveNode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trail: [DriveNode] = []
    @State private var items: [DriveNode] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorText { Text(errorText).foregroundColor(.red).font(.footnote) }
                ForEach(items) { node in
                    Button {
                        if node.isFolder { trail.append(node); Task { await load() } } else { onPick(node); dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: node.isFolder ? "folder" : "doc")
                            Text(node.name).lineLimit(1)
                            Spacer()
                            if !node.isFolder { Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)).font(.footnote).foregroundColor(.secondary) }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            .overlay { if loading { ProgressView() } else if items.isEmpty && errorText == nil { Text("Nothing here").foregroundColor(.secondary) } }
            .navigationTitle(trail.last?.name ?? "OpenEditz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if !trail.isEmpty { Button { trail.removeLast(); Task { await load() } } label: { Image(systemName: "chevron.left") } }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await DoubleClipsDrive.openEditz.list(trail.last)
            items = list.sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
            errorText = nil
        } catch {
            items = []
            errorText = (error as? DriveError)?.message ?? error.localizedDescription
        }
    }
}
