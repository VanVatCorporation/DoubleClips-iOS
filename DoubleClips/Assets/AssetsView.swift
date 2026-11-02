import SwiftUI
import Combine

// MARK: - The Assets tab
//
// Community assets (videos, images, audio, fonts, effects, packs) that people posted from their Drive. Browsing is open to everyone;
// getting an asset, posting and "My assets" need the account login (Profile tab). What the tab shows is whatever is currently shared
// with "anyone with the link": restrict a file in Drive or OpenEditz and it leaves this tab.

@MainActor
final class AssetsModel: ObservableObject {
    @Published var kind: AssetKind?
    @Published var query = ""
    @Published var sort = "new"                       // new | popular
    @Published private(set) var items: [CommunityAsset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failed: String?
    private var next: String?
    private var hasMore = true
    private var generation = 0

    /// What the grid shows: the loaded items minus those of people this phone blocked.
    var visibleItems: [CommunityAsset] { items.filter { !BlockedAuthors.contains($0.ownerName) } }

    /// Starts again from the first page (a filter, a search or a pull to refresh).
    func reload() async {
        generation += 1
        let mine = generation
        isLoading = true
        failed = nil
        next = nil
        hasMore = true
        do {
            let page = try await AssetsClient.shared.list(kind: kind, query: query, sort: sort, cursor: nil)
            guard mine == generation else { return }
            items = page.items
            next = page.next
            hasMore = page.next != nil
        } catch {
            guard mine == generation else { return }
            items = []
            failed = (error as? DriveError)?.message ?? error.localizedDescription
        }
        if mine == generation { isLoading = false }
    }

    func loadMoreIfNeeded(after asset: CommunityAsset) async {
        guard hasMore, !isLoading, let cursor = next, items.last?.id == asset.id else { return }
        generation += 1
        let mine = generation
        isLoading = true
        do {
            let page = try await AssetsClient.shared.list(kind: kind, query: query, sort: sort, cursor: cursor)
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            next = page.next
            hasMore = page.next != nil
        } catch {
            guard mine == generation else { return }
            hasMore = false
        }
        if mine == generation { isLoading = false }
    }
}

struct AssetsView: View {
    @StateObject private var model = AssetsModel()
    @ObservedObject private var auth = AuthRepository.shared
    @State private var showPost = false
    @State private var showMine = false
    @State private var showSignIn = false
    @State private var blockedVersion = 0               // refreshes the grid after someone is blocked in the detail

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    kindChips
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Assets")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search assets")
            .onSubmit(of: .search) { Task { await model.reload() } }
            .onChange(of: model.query) { _, new in if new.isEmpty { Task { await model.reload() } } }
            .toolbar { toolbarContent }
            .refreshable { await model.reload() }
            .task { if model.items.isEmpty { await model.reload() } }
            .navigationDestination(for: CommunityAsset.self) { asset in
                AssetDetailView(asset: asset, onBlocked: { blockedVersion += 1 })
            }
            .sheet(isPresented: $showPost) { PostAssetView(onPosted: { showPost = false; showMine = true }) }
            .sheet(isPresented: $showMine) { MyAssetsView() }
            .alert("Sign in to post assets", isPresented: $showSignIn) { Button("OK", role: .cancel) {} } message: {
                Text("Sign in from the Profile tab to post assets, manage them and download.")
            }
        }
    }

    // MARK: pieces

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", icon: "square.grid.2x2", selected: model.kind == nil) { setKind(nil) }
                ForEach(AssetKind.allCases) { kind in
                    chip(kind.title, icon: kind.icon, selected: model.kind == kind) { setKind(kind) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundColor(selected ? .white : .primary)
                .background(selected ? Color.mdPrimary : Color.mdSurfaceContainerHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setKind(_ kind: AssetKind?) {
        guard model.kind != kind else { return }
        model.kind = kind
        Task { await model.reload() }
    }

    @ViewBuilder private var content: some View {
        let _ = blockedVersion
        if let failed = model.failed, model.items.isEmpty {
            ContentUnavailableView("Can't load assets", systemImage: "wifi.exclamationmark", description: Text(failed))
                .padding(.top, 40)
        } else if model.visibleItems.isEmpty && !model.isLoading {
            ContentUnavailableView("No assets yet", systemImage: "shippingbox",
                                   description: Text("Assets that people share with \"anyone with the link\" show up here. Post yours from the + button."))
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(model.visibleItems) { asset in
                    NavigationLink(value: asset) { AssetCard(asset: asset) }
                        .buttonStyle(.plain)
                        .task { await model.loadMoreIfNeeded(after: asset) }
                }
            }
            if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16) }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort", selection: $model.sort) {
                    Text("Newest").tag("new")
                    Text("Most downloaded").tag("popular")
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .onChange(of: model.sort) { _, _ in Task { await model.reload() } }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { requireSignIn { showPost = true } } label: { Label("Post an asset", systemImage: "plus.circle") }
                Button { requireSignIn { showMine = true } } label: { Label("My assets", systemImage: "tray.full") }
            } label: { Image(systemName: "plus") }
        }
    }

    private func requireSignIn(_ action: () -> Void) {
        if DoubleClipsDrive.sessionToken() != nil { action() } else { showSignIn = true }
    }
}

// MARK: - A card in the grid

struct AssetCard: View {
    let asset: CommunityAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetPreviewImage(url: asset.previewUrl, kind: asset.kindValue)
                .aspectRatio(16.0 / 10.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    Label(asset.kindValue.singular, systemImage: asset.kindValue.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            Text(asset.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(asset.ownerName ?? "—").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.down.circle")
                Text(Self.compact(asset.downloads))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    static func compact(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// The poster's preview picture, or the kind's icon on a tinted card while it loads / when there is none.
struct AssetPreviewImage: View {
    let url: URL?
    let kind: AssetKind

    var body: some View {
        ZStack {
            Color.mdSurfaceContainerHigh
            Image(systemName: kind.icon).font(.system(size: 28)).foregroundColor(.secondary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .clipped()
    }
}
