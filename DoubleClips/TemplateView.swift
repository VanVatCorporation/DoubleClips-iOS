import SwiftUI

struct TemplateView: View {
    /// The feed (or the search results): loaded a page at a time as the user scrolls, by the server's ranking.
    @StateObject private var pager = TemplatePager()
    /// Index of the hot search showing in the bar (rotates every ~3 s).
    @State private var hotIndex = 0
    @ObservedObject private var hints = TemplateSearchHints.shared
    
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
                    // Hot searches take turns inside the bar; tapping opens the search screen.
                    TemplateSearchBar(terms: hotTerms, index: $hotIndex) {
                        navigationPath.append(TemplateSearchRoute(placeholder: currentHotTerm))
                    }
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
            .task {
                if !pager.didStart { await pager.start(.feed) }
            }
            .task { await hints.refresh() }
            .onAppear {
                // Signed in / out in the Profile tab: the likes in this list belong to the previous account.
                if pager.viewerChanged { Task { await pager.restart() } }
            }
            .navigationDestination(for: TemplateSearchRoute.self) { route in
                TemplateSearchView(placeholder: route.placeholder,
                                   fallbackTitles: pager.items.map(\.templateTitle),
                                   path: $navigationPath)
            }
            .navigationDestination(for: TemplateData.self) { template in
                if let index = pager.items.firstIndex(where: { $0.id == template.id }) {
                    TemplatePreviewView(pager: pager, initialScrollIndex: index)
                }
            }
        }
    }
}

extension TemplateView {
    /// What the bar rotates through: the server's hot searches, else the titles of the first templates in the feed.
    fileprivate var hotTerms: [String] {
        let hot = hints.trending.map(\.text)
        return hot.isEmpty ? Array(pager.items.prefix(8).map(\.templateTitle).filter { !$0.isEmpty }) : hot
    }

    fileprivate var currentHotTerm: String {
        let terms = hotTerms
        return terms.isEmpty ? "" : terms[hotIndex % terms.count]
    }
}

#Preview {
    TemplateView()
}
