import SwiftUI

struct TemplateView: View {
    /// The feed (or the search results): loaded a page at a time as the user scrolls, by the server's ranking.
    @StateObject private var pager = TemplatePager()
    @State private var searchText: String = ""
    
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.mdBackground.edgesIgnoringSafeArea(.all)
                
                VStack(alignment: .leading, spacing: 0) {
                    
                    // ── Header Title ─────────────────────────────────────────
                    // Matches: android:textSize="32sp" android:textStyle="bold"
                    // android:layout_marginStart="24dp" android:layout_marginTop="24dp"
                    Text("Template")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                    
                    // ── Search Bar ────────────────────────────────────────────
                    // Matches: MaterialCardView with cardCornerRadius="24dp",
                    // cardBackgroundColor="colorSurfaceContainerHigh", SearchView inside
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                        
                        TextField("Search templates...", text: $searchText)
                            .foregroundColor(.primary)
                            .textFieldStyle(PlainTextFieldStyle())
                        
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.mdSurfaceContainerHigh)
                    .clipShape(Capsule()) // cardCornerRadius="24dp" → Capsule
                    .overlay(
                        Capsule()
                            .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // ── Template List ─────────────────────────────────────────
                    // Matches: SwipeRefreshLayout + StaggeredGridLayoutManager(2 cols), now an endless feed
                    TemplateMasonryGrid(templates: pager.items,
                                        isLoading: pager.isLoading,
                                        emptyText: pager.didStart ? L("No templates found") : nil,
                                        onSelect: { navigationPath.append($0) },
                                        onAppearItem: { pager.loadNextIfNeeded(near: $0) })
                        .refreshable { await pager.restart() }   // a new feed session
                }
            }
            .task(id: searchText) {
                // Runs on first appearance (the feed) and again whenever the text changes. Typing cancels the previous run,
                // so waiting a moment here is the debounce. Coming back from a preview changes nothing: no reload.
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let wanted: TemplateFeedSource = query.isEmpty ? .feed : .search(query)
                if pager.didStart && pager.source == wanted && !pager.viewerChanged { return }
                if pager.didStart && !query.isEmpty {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return }
                }
                await pager.start(wanted)
            }
            .onAppear {
                // Signed in / out in the Profile tab: the likes in this list belong to the previous account.
                if pager.viewerChanged { Task { await pager.restart() } }
            }
            .navigationDestination(for: TemplateData.self) { template in
                if let index = pager.items.firstIndex(where: { $0.id == template.id }) {
                    TemplatePreviewView(pager: pager, initialScrollIndex: index)
                }
            }
        }
    }
}

#Preview {
    TemplateView()
}
