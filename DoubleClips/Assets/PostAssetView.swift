import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

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
    @StateObject private var transfer = PostTransfer()
    @State private var postTask: Task<Void, Never>?
    @State private var errorText: String?
    /// The upload failed for a quota / plan reason: the form offers "Get more resources" (like the backup sheet).
    @State private var quotaFailure = false

    private var fileName: String? { node?.name ?? local?.lastPathComponent }
    private var canPost: Bool { fileName != nil && rights && title.trimmingCharacters(in: .whitespaces).count >= 2 && !transfer.running }

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
                if let errorText {
                    Section {
                        Text(errorText).foregroundColor(.red).font(.footnote)
                        if quotaFailure { GetMoreResourcesButton() }
                    }
                }
            }
            .navigationTitle("Post an asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(transfer.running) }
                ToolbarItem(placement: .confirmationAction) { Button("Post") { post() }.disabled(!canPost) }
            }
            // The same kind of card as the backup / download popups: file name, bar, "12 MB / 70 MB", percent, Stop. It covers the sheet
            // (nothing behind it can be touched) and the only way out is Stop or the post finishing.
            .overlay { PostTransferCard(transfer: transfer, onStop: stop) }
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
        .interactiveDismissDisabled(transfer.running)
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
        guard let name = fileName else { return }
        errorText = nil
        quotaFailure = false
        let pickedNode = node
        let pickedLocal = local
        let assetKind = kind
        let assetTitle = title.trimmingCharacters(in: .whitespaces)
        let assetText = text
        let assetTags = Self.splitTags(tags)
        let picture = preview
        transfer.begin(name: name, uploading: pickedNode == nil && pickedLocal != nil)

        postTask = Task {
            defer {
                transfer.finish()
                postTask = nil
            }
            do {
                var target = pickedNode
                if target == nil, let file = pickedLocal {
                    let size = Self.size(of: file)
                    transfer.total = size
                    try await checkQuota(size: size, name: file.lastPathComponent)
                    let folder = try await DoubleClipsDrive.openEditz.ensureFolder(path: ["Assets"])
                    let uploadName = await Self.freeName(file.lastPathComponent, in: folder)
                    let transfer = self.transfer
                    let uploaded = try await DoubleClipsDrive.openEditz.upload(fileURL: file, into: folder, name: uploadName) { sent in
                        Task { @MainActor in transfer.loaded = min(sent, max(size, 1)) }
                    }
                    // uploaded: if posting fails next, a second try reuses this file instead of uploading another copy
                    node = uploaded
                    local = nil
                    try? FileManager.default.removeItem(at: file)
                    target = uploaded
                }
                guard let target else { return }
                transfer.phase = .posting
                let asset = try await AssetsClient.shared.publish(node: target, kind: assetKind, title: assetTitle,
                                                                  description: assetText, tags: assetTags)
                if let picture { try? await AssetsClient.shared.uploadPreview(assetId: asset.id, jpeg: picture) }
                onPosted()
            } catch is CancellationError {
                // Stop (or "Cancel" on the daily-limit warning): nothing to say
            } catch {
                if Task.isCancelled { return }
                errorText = (error as? DriveError)?.message ?? error.localizedDescription
                quotaFailure = (error as? DriveError)?.isQuotaLimit ?? false
            }
        }
    }

    /// Stop: ends the upload (the server throws away the half-sent file) or the post.
    private func stop() {
        postTask?.cancel()
        transfer.answerWarning(false)
    }

    /// Not enough storage left cannot work; the daily upload cap only warns ("Continue anyway", like the backup sheet and the Storage tab).
    private func checkQuota(size: Int64, name: String) async throws {
        guard let me = try? await DoubleClipsDrive.client.me() else { return }     // can't tell: the server has the final say
        let free = max(0, me.quotaBytes - me.usedBytes)
        if size > free {
            throw DriveError(status: 413, code: "quota_exceeded",
                             message: Lf("Not enough space for “%@”: %@ left.", name, StorageModel.bytes(free)))
        }
        let freeToday = me.usage?.uploadFree ?? .max
        if size > freeToday {
            let proceed = await transfer.askWarning(QuotaText.upload(size: size, free: freeToday))
            if !proceed { throw CancellationError() }
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A name not yet used in the folder ("beat.mp3" -> "beat (1).mp3"): an upload under a taken name is refused by the server.
    private static func freeName(_ name: String, in folder: DriveNode) async -> String {
        guard let existing = try? await DoubleClipsDrive.openEditz.list(folder) else { return name }
        let taken = Set(existing.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 1..<1000 {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }
}

// MARK: - The progress of a post

/// What the post is doing right now; drives {@link PostTransferCard}.
@MainActor
final class PostTransfer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading                 // the file goes to OpenEditz/Assets
        case posting                   // the catalog entry and its picture
        case warning(String)           // the file probably won't fit today's upload allowance: Continue anyway / Cancel
    }

    @Published var phase: Phase = .idle
    @Published var name = ""
    @Published var loaded: Int64 = 0
    /// 0 = nothing to upload (the file is already in OpenEditz) or not known yet.
    @Published var total: Int64 = 0
    private var warningAnswer: CheckedContinuation<Bool, Never>?

    var running: Bool { phase != .idle }
    var fraction: Double? { total > 0 ? min(max(Double(loaded) / Double(total), 0), 1) : nil }

    func begin(name: String, uploading: Bool) {
        self.name = name
        loaded = 0
        total = 0
        phase = uploading ? .uploading : .posting
    }

    func finish() {
        warningAnswer?.resume(returning: false)
        warningAnswer = nil
        phase = .idle
        loaded = 0
        total = 0
    }

    /// Shows the daily-limit warning and waits for the answer.
    func askWarning(_ message: String) async -> Bool {
        phase = .warning(message)
        return await withCheckedContinuation { warningAnswer = $0 }
    }

    func answerWarning(_ proceed: Bool) {
        guard let answer = warningAnswer else { return }
        warningAnswer = nil
        if proceed { phase = .uploading }
        answer.resume(returning: proceed)
    }
}

/// The card shown while a post runs: the same pieces as the Storage download popup (name, bar, "12 MB / 70 MB", percent, Stop) and
/// the backup sheet's daily-limit warning. An overlay on the whole sheet, not a nested sheet: it can't be swiped away.
struct PostTransferCard: View {
    @ObservedObject var transfer: PostTransfer
    let onStop: () -> Void

    var body: some View {
        if transfer.running {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }                      // swallow taps: the form behind is locked

                VStack(spacing: 14) {
                    switch transfer.phase {
                    case .warning(let message):
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                        Text(QuotaText.uploadTitle).font(.headline)
                        Text(L(message)).font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
                        HStack {
                            Button("Cancel") { transfer.answerWarning(false) }.buttonStyle(.bordered)
                            Button("Continue anyway") { transfer.answerWarning(true) }.buttonStyle(.borderedProminent)
                        }
                    case .posting:
                        Text("Posting…").font(.headline)
                        Text(transfer.name).font(.subheadline).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        ProgressView().progressViewStyle(.linear)          // no size to count: indeterminate
                        stopButton
                    default:
                        Text("Uploading to OpenEditz…").font(.headline)
                        Text(transfer.name).font(.subheadline).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        if let fraction = transfer.fraction {
                            ProgressView(value: fraction).progressViewStyle(.linear)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        HStack {
                            Text(sizeText).font(.footnote.monospacedDigit()).foregroundColor(.secondary)
                            Spacer()
                            if let fraction = transfer.fraction {
                                Text("\(Int((fraction * 100).rounded()))%").font(.footnote.monospacedDigit()).foregroundColor(.secondary)
                            }
                        }
                        stopButton
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var stopButton: some View {
        Button(role: .cancel) { onStop() } label: { Text("Stop").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }

    /// "12 MB / 70 MB", or just what has gone when the total isn't known.
    private var sizeText: String {
        let loaded = StorageModel.bytes(transfer.loaded)
        guard transfer.total > 0 else { return loaded }
        return "\(loaded) / \(StorageModel.bytes(transfer.total))"
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
