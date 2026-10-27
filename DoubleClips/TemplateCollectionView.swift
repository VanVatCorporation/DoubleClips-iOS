import SwiftUI

/// Profile → Liked Templates / Saved Templates: the signed-in account's own list, newest first, paged from the server.
/// Opening a card plays the list in the same swipeable preview as the Templates tab (it shares this list's pager).
struct TemplateCollectionView: View {
    let source: TemplateFeedSource

    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager = TemplatePager()
    @ObservedObject private var states = TemplateStateStore.shared
    @State private var navigationPath = NavigationPath()

    private var title: String {
        switch source {
        case .bookmarked: return "Saved templates"
        case .mine: return "My templates"
        default: return "Liked templates"
        }
    }

    /// What no longer belongs (unliked / unsaved in the preview) leaves the list at once, without a reload.
    private var visible: [TemplateData] {
        pager.items.filter { t in
            if source == .mine { return true }               // everything this account posted stays listed
            let s = states.state(for: t)
            return source == .bookmarked ? s.isBookmarked : s.isLiked
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.mdBackground.edgesIgnoringSafeArea(.all)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                        }
                        Text(title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    TemplateMasonryGrid(templates: visible,
                                        isLoading: pager.isLoading,
                                        emptyText: pager.didStart ? "Nothing here yet" : nil,
                                        onSelect: { navigationPath.append($0) },
                                        onAppearItem: { pager.loadNextIfNeeded(near: $0) })
                        .refreshable { await pager.restart() }
                }
            }
            .task {
                if !pager.didStart { await pager.start(source) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TemplateData.self) { template in
                if let index = pager.items.firstIndex(where: { $0.id == template.id }) {
                    TemplatePreviewView(pager: pager, initialScrollIndex: index)
                }
            }
        }
    }
}
