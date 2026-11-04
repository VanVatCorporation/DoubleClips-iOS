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
        let (kind, query, sort) = (self.kind, self.query, self.sort)
        // The request runs in a task of its own. SwiftUI cancels the task that called reload() (a pull to refresh that ends, a view
        // update) and a cancelled URLSession request would land here as an error ("cancelled") and empty the grid.
        let result = await Task { try await AssetsClient.shared.list(kind: kind, query: query, sort: sort, cursor: nil) }.result
        guard mine == generation else { return }
        switch result {
        case .success(let page):
            items = page.items
            next = page.next
            hasMore = page.next != nil
        case .failure(let error):
            // A cancelled request is not a failure: what is on screen stays.
            if !Self.isCancellation(error) {
                items = []
                next = nil
                hasMore = true
                failed = (error as? DriveError)?.message ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadMoreIfNeeded(after asset: CommunityAsset) async {
        guard hasMore, !isLoading, let cursor = next, items.last?.id == asset.id else { return }
        generation += 1
        let mine = generation
        isLoading = true
        let (kind, query, sort) = (self.kind, self.query, self.sort)
        let result = await Task { try await AssetsClient.shared.list(kind: kind, query: query, sort: sort, cursor: cursor) }.result
        guard mine == generation else { return }
        switch result {
        case .success(let page):
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            next = page.next
            hasMore = page.next != nil
        case .failure(let error):
            // Scrolling cancels the .task of a card that left the screen: that must not stop the paging for good.
            if !Self.isCancellation(error) { hasMore = false }
        }
        isLoading = false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
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
    /// Hidden authors (here or in Settings > Hidden content): the grid redraws at once.
    @ObservedObject private var hidden = HiddenContent.shared
    @State private var openAsset: CommunityAsset?       // "Open" in a card's long-press menu
    @State private var reportAsset: CommunityAsset?     // "Report" in the long-press menu

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
            .navigationDestination(item: $openAsset) { asset in
                AssetDetailView(asset: asset, target: target, onBlocked: { blockedVersion += 1 })
            }
            .navigationDestination(for: AssetSearchRoute.self) { route in
                AssetSearchView(placeholder: route.placeholder, fallbackTitles: model.items.map(\.title), target: target,
                                onBlocked: { blockedVersion += 1 })
            }
            .sheet(isPresented: $showPost) { PostAssetView(onPosted: { showPost = false; showMine = true }) }
            .sheet(isPresented: $showMine) { MyAssetsView() }
            .sheet(item: $reportAsset) { ReportAssetSheet(asset: $0) }
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
        let _ = hidden.authors
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
                    NavigationLink(value: asset) {
                        AssetCard(asset: asset,
                                  onOpen: { openAsset = asset },
                                  onReport: { reportAsset = asset },
                                  onHideAuthor: { if let owner = asset.ownerName { hidden.hideAuthor(owner) } })
                    }
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
    /// The long-press menu's actions. A card given none of them is a plain card (no menu).
    var onOpen: (() -> Void)? = nil
    var onReport: (() -> Void)? = nil
    var onHideAuthor: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetPreviewImage(url: asset.previewUrl, kind: asset.kindValue)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
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
        // Long press: the picture, the details and the actions float up (like a template or a project on Home); "Hide assets from X"
        // is here too (Settings > Hidden content shows them again).
        .contextMenu {
            if let onOpen {
                Button(action: onOpen) { Label("Open", systemImage: "arrow.down.circle") }
            }
            if let onReport {
                Button(action: onReport) { Label("Report", systemImage: "flag") }
            }
            if let owner = asset.ownerName, let onHideAuthor {
                Button(role: .destructive, action: onHideAuthor) { Label("Hide assets from \(owner)", systemImage: "person.slash") }
            }
        } preview: {
            AssetHoldPreview(asset: asset)
        }
    }

    static func compact(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// The poster's preview picture, or the kind's icon on a tinted card while it loads / when there is none.
///
/// The tinted box is what has the size (it takes whatever the caller gives it: a frame, or an aspect ratio) and the picture is only
/// drawn inside it, sized to the box and clipped. A picture put next to the box in a ZStack would make the cell as big as the
/// picture itself: a phone photo then filled the whole screen.
struct AssetPreviewImage: View {
    let url: URL?
    let kind: AssetKind

    var body: some View {
        Color.mdSurfaceContainerHigh
            .overlay {
                GeometryReader { box in
                    ZStack {
                        Image(systemName: kind.icon).font(.system(size: 28)).foregroundColor(.secondary)
                            .frame(width: box.size.width, height: box.size.height)
                        if let url {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                        .frame(width: box.size.width, height: box.size.height)
                                        .clipped()
                                }
                            }
                        }
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
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

// MARK: - The long-press preview of an asset

/// What floats up when an asset card is held: the poster's picture, the title and poster, kind / size / downloads / date, the tags and
/// the start of the description. Not interactive: the actions are in the menu under it.
struct AssetHoldPreview: View {
    let asset: CommunityAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetPreviewImage(url: asset.previewUrl, kind: asset.kindValue)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    Label(asset.kindValue.singular, systemImage: asset.kindValue.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(asset.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                if let owner = asset.ownerName {
                    Label("@" + owner, systemImage: "person.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 14) {
                    Label(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file), systemImage: "doc")
                    Label("\(asset.downloads)", systemImage: "arrow.down.circle")
                    Label(asset.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                if !asset.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(asset.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)").font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.mdSurfaceContainerHigh)
                                .clipShape(Capsule())
                        }
                    }
                    .lineLimit(1)
                }
                if let text = asset.description, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                }
            }
            .padding(14)
        }
        .frame(width: 320)
        .background(Color.mdSurface)
    }
}
