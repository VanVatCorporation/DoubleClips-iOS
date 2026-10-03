import SwiftUI
import UniformTypeIdentifiers

// MARK: - Animation packs sheet (Android: AnimationPackDialog)
//
// Lists the installed packs, lets the user import a new .zip pack or remove an installed one.
// All the real work (validation, install, removal) is in ClipAnimationStore; this only shows it.

struct AnimationPackSheet: View {
    /// Called after a pack was imported or removed, so the animation pickers refresh.
    let onChanged: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var packs: [ClipAnimationPackInfo] = []
    @State private var showImporter = false
    @State private var isWorking = false
    @State private var removing: ClipAnimationPackInfo?
    @State private var message: PackMessage?
    
    private struct PackMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
    
    var body: some View {
        NavigationStack {
            List {
                if packs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No animation packs installed.")
                            .font(.headline)
                        Text("A pack is a .zip with a pack.json and animation .json files. Import one to add more in / out animations to the pickers.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(packs) { pack in
                        Button { removing = pack } label: {
                            packRow(pack)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Tap a pack to remove it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Animation packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showImporter = true
                    } label: {
                        if isWorking { ProgressView() } else { Text("Import pack…") }
                    }
                    .disabled(isWorking)
                }
            }
            .onAppear(perform: reload)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importPack(url) }
                case .failure(let error):
                    message = PackMessage(title: "Couldn't import the pack", text: error.localizedDescription)
                }
            }
            .confirmationDialog(removing.map { "Remove \"\($0.name)\"?" } ?? "",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let pack = removing { remove(pack) }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("Clips that use its animations keep them selected but will render without them until the pack is installed again.")
            }
            .alert(item: $message) { item in
                Alert(title: Text(item.title), message: Text(item.text), dismissButton: .default(Text("OK")))
            }
        }
    }
    
    private func packRow(_ pack: ClipAnimationPackInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(pack.name).font(.headline)
                if !pack.damaged {
                    Text("v\(pack.version)").font(.subheadline).foregroundColor(.secondary)
                }
                if !pack.author.isEmpty {
                    Text("· \(pack.author)").font(.subheadline).foregroundColor(.secondary)
                }
            }
            if pack.damaged {
                Text("Unreadable. Tap to remove.")
                    .font(.subheadline)
                    .foregroundColor(.red)
            } else {
                Text(Self.detail(for: pack))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    
    private static func detail(for pack: ClipAnimationPackInfo) -> String {
        let count = pack.animationCount
        var detail = "\(count) \(count == 1 ? "animation" : "animations")"
        if !pack.inIDs.isEmpty { detail += "  ·  in: " + pack.inIDs.joined(separator: ", ") }
        if !pack.outIDs.isEmpty { detail += "  ·  out: " + pack.outIDs.joined(separator: ", ") }
        return detail
    }
    
    private func reload() {
        packs = ClipAnimationStore.installedPacks()
    }
    
    private func importPack(_ url: URL) {
        isWorking = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ClipAnimationStore.importPack(from: url)
                }.value
                reload()
                onChanged()
                let pack = result.pack
                let verb = result.replacedVersion > 0
                    ? "Updated from v\(result.replacedVersion) to v\(pack.version)"
                    : "Installed"
                message = PackMessage(title: "\(verb): \(pack.name)",
                                      text: "\(pack.animationCount) \(pack.animationCount == 1 ? "animation" : "animations") added to the In / Out pickers.")
            } catch {
                message = PackMessage(title: "Couldn't install the pack", text: error.localizedDescription)
            }
            isWorking = false
        }
    }
    
    private func remove(_ pack: ClipAnimationPackInfo) {
        do {
            try ClipAnimationStore.removePack(id: pack.id)
            reload()
            onChanged()
        } catch {
            message = PackMessage(title: "Couldn't remove the pack", text: error.localizedDescription)
        }
    }
}
