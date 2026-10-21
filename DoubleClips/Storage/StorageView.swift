import SwiftUI
import UniformTypeIdentifiers

/// The Storage tab: your OpenEditz folder in Van Vat Drive.
/// Back up projects as ZIPs, restore them, upload and download files. Everything here stays inside OpenEditz
/// (the full Drive — sharing, trash, other folders — lives in the Van Vat Drive app).
struct StorageView: View {
    @StateObject private var model = StorageModel()
    @ObservedObject private var auth = AuthRepository.shared

    @State private var showFolderAlert = false
    @State private var folderName = ""
    @State private var renameTarget: DriveNode?
    @State private var renameText = ""
    @State private var deleteTarget: DriveNode?
    @State private var fileTarget: DriveNode?
    @State private var showImporter = false
    @State private var showBackup = false
    @State private var activityURL: ActivityItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasSession { signInPrompt } else { content }
            }
            .navigationTitle(model.currentFolder?.name ?? "OpenEditz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: auth.currentUser?.username) { await model.reload() }
            .refreshable { await model.reload() }
            .overlay { if let text = model.busyText { busyOverlay(text) } }
            // dialogs
            .alert("New folder", isPresented: $showFolderAlert) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = folderName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { Task { await model.createFolder(named: name) } }
                }
            }
            .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let node = renameTarget {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name != node.name { Task { await model.rename(node, to: name) } }
                    }
                    renameTarget = nil
                }
            }
            .quotaWarning($model.warning)
            .alert("Storage", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; model.errorIsQuota = false } })) {
                if model.errorIsQuota { Button("Get more resources") { openURL(Plans.url) } }
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
            .confirmationDialog("Delete “\(deleteTarget?.name ?? "")” for good?",
                                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let n = deleteTarget { Task { await model.delete(n) } } }
            } message: { Text("This frees the space right away and cannot be undone.") }
            .confirmationDialog(fileTarget?.name ?? "",
                                isPresented: Binding(get: { fileTarget != nil }, set: { if !$0 { fileTarget = nil } }),
                                titleVisibility: .visible, presenting: fileTarget) { node in
                if isProjectZip(node) {
                    Button("Restore into DoubleClips") { model.guardDownload(node) { Task { await model.restore(node) } } }
                }
                Button("Share or save to Files") {
                    model.guardDownload(node) { Task { if let url = await model.download(node) { activityURL = ActivityItem(url: url) } } }
                }
                Button("Rename") { renameText = node.name; renameTarget = node }
                Button("Delete", role: .destructive) { deleteTarget = node }
            } message: { node in
                Text("\(StorageModel.bytes(node.size)) · \(node.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            // sheets
            .sheet(isPresented: $showBackup) { BackupProjectView(model: model) }
            .sheet(item: $activityURL) { ActivitySheet(url: $0.url) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.upload(urls) }
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            if let me = model.me {
                Section { QuotaSummary(me: me) }
            }

            if !model.trail.isEmpty {
                Section { breadcrumb }
            }

            if !model.uploads.isEmpty {
                Section("Uploads") {
                    ForEach(model.uploads) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).lineLimit(1)
                            if row.state == .running { ProgressView(value: Double(row.loaded), total: Double(max(row.size, 1))) }
                            switch row.state {
                            case .running: Text("\(StorageModel.bytes(row.loaded)) of \(StorageModel.bytes(row.size))").font(.caption).foregroundStyle(.secondary)
                            case .done: Text("Uploaded").font(.caption).foregroundStyle(.green)
                            case .failed(let message):
                                Text(message).font(.caption).foregroundStyle(.red)
                                if row.quotaFailure { GetMoreResourcesButton().font(.caption) }
                            }
                        }
                    }
                    if model.uploads.contains(where: { $0.state != .running }) {
                        Button("Clear") { model.clearFinishedUploads() }.font(.footnote)
                    }
                }
            }

            Section {
                if model.items.isEmpty && !model.isLoading {
                    ContentUnavailableView("Nothing here yet", systemImage: "icloud",
                                           description: Text("Back up a project or upload files with the + button."))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.items) { node in row(node) }
            }
        }
        .overlay { if model.isLoading && model.items.isEmpty { ProgressView() } }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("OpenEditz") { Task { await model.go(toDepth: 0) } }
                ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    if index == model.trail.count - 1 { Text(folder.name).bold() }
                    else { Button(folder.name) { Task { await model.go(toDepth: index + 1) } } }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder private func row(_ node: DriveNode) -> some View {
        Button {
            if node.isFolder { Task { await model.enter(node) } } else { fileTarget = node }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: node))
                    .font(.title3)
                    .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).lineLimit(1)
                    Text(node.isFolder ? node.updatedAt.formatted(date: .abbreviated, time: .omitted)
                                       : "\(StorageModel.bytes(node.size)) · \(node.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if node.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !node.isFolder && isProjectZip(node) {
                Button { model.guardDownload(node) { Task { await model.restore(node) } } } label: { Label("Restore into DoubleClips", systemImage: "arrow.down.circle") }
            }
            Button { renameText = node.name; renameTarget = node } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { deleteTarget = node } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var signInPrompt: some View {
        ContentUnavailableView("Sign in to use Storage", systemImage: "person.crop.circle.badge.exclamationmark",
                               description: Text("Sign in from the Profile tab to back up your projects to OpenEditz."))
    }

    private func busyOverlay(_ text: String) -> some View {
        VStack(spacing: 10) { ProgressView(); Text(text).font(.footnote) }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !model.trail.isEmpty {
                Button { Task { await model.go(toDepth: model.trail.count - 1) } } label: { Image(systemName: "chevron.left") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.hasSession {
                Menu {
                    Button { showBackup = true } label: { Label("Back up a project…", systemImage: "externaldrive.badge.plus") }
                    Button { showImporter = true } label: { Label("Upload files", systemImage: "doc.badge.plus") }
                    Button { folderName = ""; showFolderAlert = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    // MARK: - Helpers

    private func isProjectZip(_ node: DriveNode) -> Bool { node.name.lowercased().hasSuffix(".zip") }

    private func symbol(for node: DriveNode) -> String {
        if node.isFolder { return "folder.fill" }
        if isProjectZip(node) { return "shippingbox" }
        let kind = MediaKind(pathExtension: (node.name as NSString).pathExtension)
        return kind == .other ? "doc" : kind.symbol
    }
}

// MARK: - Share sheet

struct ActivityItem: Identifiable { let url: URL; var id: URL { url } }

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
