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
    /// Opened from the editor's toolbar: "Add to this project" puts media and fonts straight into this project.
    var target: ProjectData? = nil
    /// Set when shown as a sheet (the editor): adds a Done button.
    var onClose: (() -> Void)? = nil

    @StateObject private var model = AssetsModel()
    @ObservedObject private var auth = AuthRepository.shared
    @ObservedObject private var hints = AssetSearchHints.shared
    @State private var path = NavigationPath()
    @State private var hotIndex = 0                      // the hot search showing in the bar (rotates every ~3 s)
    @State private var showPost = false
    @State private var showMine = false
    @State private var showSignIn = false
    @State private var blockedVersion = 0               // refreshes the grid after someone is blocked in the detail

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Hot searches take turns inside the bar; tapping opens the search screen (like the Templates tab).
                    TemplateSearchBar(terms: hotTerms, index: $hotIndex, emptyPrompt: "Search assets...") {
                        path.append(AssetSearchRoute(placeholder: currentHotTerm))
                    }
                    AssetKindChips(selection: Binding(get: { model.kind }, set: { setKind($0) }))
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Assets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { await model.reload() }
            .task { if model.items.isEmpty { await model.reload() } }
            .task { await hints.refresh() }
            .navigationDestination(for: CommunityAsset.self) { asset in
                AssetDetailView(asset: asset, target: target, onBlocked: { blockedVersion += 1 })
            }
            .navigationDestination(for: AssetSearchRoute.self) { route in
                AssetSearchView(placeholder: route.placeholder, fallbackTitles: model.items.map(\.title), target: target,
                                onBlocked: { blockedVersion += 1 })
            }
            .sheet(isPresented: $showPost) { PostAssetView(onPosted: { showPost = false; showMine = true }) }
            .sheet(isPresented: $showMine) { MyAssetsView() }
            .alert("Sign in to post assets", isPresented: $showSignIn) { Button("OK", role: .cancel) {} } message: {
                Text("Sign in from the Profile tab to post assets, manage them and download.")
            }
        }
    }

    // MARK: pieces

    /// What the bar rotates through: the server's hot searches, else the titles of the first assets in the tab.
    private var hotTerms: [String] {
        let hot = hints.trending.map(\.text)
        return hot.isEmpty ? Array(model.items.prefix(8).map(\.title).filter { !$0.isEmpty }) : hot
    }

    private var currentHotTerm: String {
        let terms = hotTerms
        return terms.isEmpty ? "" : terms[hotIndex % terms.count]
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
        ToolbarItemGroup(placement: .topBarLeading) {
            if let onClose { Button("Done") { onClose() } }
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


// MARK: - Kind filter chips (the tab and the search results)

struct AssetKindChips: View {
    @Binding var selection: AssetKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", icon: "square.grid.2x2", selected: selection == nil) { selection = nil }
                ForEach(AssetKind.allCases) { kind in
                    chip(kind.title, icon: kind.icon, selected: selection == kind) { selection = kind }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundColor(selected ? .white : .primary)
                .background(selected ? Color.mdPrimary : Color.mdSurfaceContainerHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
