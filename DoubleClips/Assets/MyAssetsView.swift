import SwiftUI
import Combine

// MARK: - My assets
//
// Everything I posted, with the state of the link behind it:
//   Public      anyone with the link: listed in the Assets tab
//   Restricted  no active link: not listed (restrict a file in Drive or OpenEditz and it moves here by itself)
//   In review   hidden after reports
//   File deleted  the file is in the Drive trash
// The switch flips the file's own link; "Remove from Assets" takes the entry off the tab and leaves the file in Drive.

@MainActor
final class MyAssetsModel: ObservableObject {
    @Published var items: [MyAsset] = []
    @Published var isLoading = false
    @Published var errorText: String?

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { items = try await AssetsClient.shared.mine() }
        catch { errorText = (error as? DriveError)?.message ?? error.localizedDescription }
    }

    func replace(_ asset: MyAsset) {
        if let i = items.firstIndex(where: { $0.id == asset.id }) { items[i] = asset }
    }

    /// Flips "anyone with the link". A link that comes from a folder cannot be removed from here: the server says which folder.
    func setPublic(_ asset: MyAsset, _ on: Bool) async {
        do {
            replace(on ? try await AssetsClient.shared.share(asset) : try await AssetsClient.shared.restrict(asset))
        } catch {
            errorText = (error as? DriveError)?.message ?? error.localizedDescription
            await reload()
        }
    }

    func remove(_ asset: MyAsset, revokeLink: Bool) async {
        do {
            try await AssetsClient.shared.remove(asset, revokeLink: revokeLink)
            items.removeAll { $0.id == asset.id }
        } catch {
            errorText = (error as? DriveError)?.message ?? error.localizedDescription
        }
    }
}

struct MyAssetsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MyAssetsModel()
    @State private var editing: MyAsset?
    @State private var removing: MyAsset?

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty && !model.isLoading {
                    ContentUnavailableView("Nothing posted yet", systemImage: "tray",
                                           description: Text("Assets you post show up here with the state of their link."))
                } else {
                    List {
                        Section {
                            ForEach(model.items) { asset in row(asset) }
                        } footer: {
                            Text("Restricting a file in Drive or OpenEditz takes it off the Assets tab too. Sharing it with \"anyone with the link\" again brings it back.")
                        }
                    }
                }
            }
            .navigationTitle("My assets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay { if model.isLoading && model.items.isEmpty { ProgressView() } }
            .refreshable { await model.reload() }
            .task { await model.reload() }
            .sheet(item: $editing) { asset in
                EditAssetSheet(asset: asset) { updated in model.replace(updated) }
            }
            .confirmationDialog("Remove “\(removing?.title ?? "")” from Assets?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { asset in
                Button("Remove from Assets") { Task { await model.remove(asset, revokeLink: false) } }
                Button("Remove and restrict the file", role: .destructive) { Task { await model.remove(asset, revokeLink: true) } }
            } message: { _ in Text("The file stays in your Drive.") }
            .alert("Assets", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorText ?? "") }
        }
    }

    private func row(_ asset: MyAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AssetPreviewImage(url: asset.previewUrl, kind: asset.kindValue)
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(asset.kindValue.singular))
                        Label("\(asset.downloads)", systemImage: "arrow.down.circle")
                    }
                    .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                stateBadge(asset)
            }
            if asset.state == "public" || asset.state == "restricted" {
                Toggle(isOn: Binding(get: { asset.state == "public" }, set: { on in Task { await model.setPublic(asset, on) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Anyone with the link").font(.system(size: 13))
                        if asset.state == "public", asset.via == "folder", let folder = asset.folderName {
                            Text("Through the folder “\(folder)”").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
                .tint(Color.mdPrimary)
            } else if asset.state == "review" {
                Text("Hidden after reports until it is reviewed.").font(.system(size: 11)).foregroundColor(.orange)
            } else {
                Text("The file is in the Drive trash. Restore it in Drive to bring it back, or remove it here.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { removing = asset } label: { Label("Remove", systemImage: "trash") }
            Button { editing = asset } label: { Label("Edit", systemImage: "pencil") }.tint(Color.mdPrimary)
        }
        .contextMenu {
            Button { editing = asset } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { removing = asset } label: { Label("Remove from Assets", systemImage: "trash") }
        }
    }

    private func stateBadge(_ asset: MyAsset) -> some View {
        let (text, color): (String, Color) = {
            switch asset.state {
            case "public": return ("Public", .green)
            case "restricted": return ("Restricted", .gray)
            case "review": return ("In review", .orange)
            default: return ("File deleted", .red)
            }
        }()
        return Text(LocalizedStringKey(text))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundColor(color).background(color.opacity(0.15)).clipShape(Capsule())
    }
}

// MARK: - Edit title / description / tags

struct EditAssetSheet: View {
    let asset: MyAsset
    let onSaved: (MyAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var tags: String
    @State private var saving = false
    @State private var errorText: String?

    init(asset: MyAsset, onSaved: @escaping (MyAsset) -> Void) {
        self.asset = asset
        self.onSaved = onSaved
        _title = State(initialValue: asset.title)
        _text = State(initialValue: asset.description ?? "")
        _tags = State(initialValue: asset.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Title", text: $title) }
                Section("Tags (comma separated)") { TextField("beat, smooth, 4k", text: $tags).textInputAutocapitalization(.never) }
                Section("Description") { TextField("What is it, how to use it", text: $text, axis: .vertical).lineLimit(3...8) }
                if let errorText { Text(errorText).foregroundColor(.red).font(.footnote) }
            }
            .navigationTitle("Edit asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving || title.trimmingCharacters(in: .whitespaces).count < 2) }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                let updated = try await AssetsClient.shared.update(asset, title: title, description: text, tags: PostAssetView.splitTags(tags))
                onSaved(updated)
                dismiss()
            } catch {
                errorText = (error as? DriveError)?.message ?? error.localizedDescription
            }
            saving = false
        }
    }
}
