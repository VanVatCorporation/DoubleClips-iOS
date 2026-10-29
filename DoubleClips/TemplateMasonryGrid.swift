import SwiftUI

/// The two-column masonry of template cards, shared by the Templates tab and the Profile Liked / Saved lists.
/// Every card reads the newest numbers from `TemplateStateStore`, so a like made in the preview shows here too.
/// Add `.refreshable { ... }` on it for pull to refresh.
struct TemplateMasonryGrid: View {
    let templates: [TemplateData]
    var isLoading: Bool = false
    /// Shown in the middle when there is nothing to list (nil = say nothing).
    var emptyText: String? = nil
    let onSelect: (TemplateData) -> Void
    /// A card appeared (the pager decides whether that means "load the next page").
    let onAppearItem: (TemplateData) -> Void

    @ObservedObject private var states = TemplateStateStore.shared

    private func column(_ parity: Int) -> [TemplateData] {
        templates.enumerated().filter { $0.offset % 2 == parity }.map { $0.element }
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4 // ~3dp like Android
            let itemWidth = (geometry.size.width - (spacing * 3)) / 2

            ZStack {
                ScrollView {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<2, id: \.self) { parity in
                            LazyVStack(spacing: spacing) {
                                ForEach(column(parity)) { template in
                                    TemplateElementView(template: states.applied(template), itemWidth: itemWidth,
                                                        onOpen: { onSelect(template) })
                                        .onTapGesture { onSelect(template) }
                                        .onAppear { onAppearItem(template) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, spacing)

                    if isLoading && !templates.isEmpty {
                        ProgressView().padding(.vertical, 16)
                    }
                    Color.clear.frame(height: 80) // Match Android paddingBottom="80dp" for nav bar
                }

                if templates.isEmpty {
                    if isLoading {
                        ProgressView().scaleEffect(1.5)
                    } else if let emptyText = emptyText {
                        Text(emptyText).font(.system(size: 16)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}
