import SwiftUI
import Combine

/// Pages through one `TemplateFeedSource` (feed / search / liked / saved) with the server's cursor.
/// Shared by the Templates tab, the Profile lists AND the preview pager (it reads the same `items`, so swiping
/// past the end of the grid keeps loading the same list).
///
///  - A new `start` bumps a generation: an answer for an older source (the user kept typing in the search box,
///    pulled to refresh...) is dropped instead of landing in the new list.
///  - Templates already delivered are never delivered again.
///  - A refresh keeps the old cards on screen until the first page of the new session arrives (no empty flash).
@MainActor
final class TemplatePager: ObservableObject {
    @Published private(set) var items: [TemplateData] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// true once a first page has arrived for the current source
    @Published private(set) var didStart = false
    @Published private(set) var errorMessage: String?
    private(set) var source: TemplateFeedSource = .feed

    private var cursor: String?
    private var generation = 0
    private var delivered = Set<String>()
    private var viewerAtStart = TemplateAPI.currentOwner

    /// Start the next page when this few cards are left after the one that appeared.
    private let prefetchDistance = 6
    private let maxEmptyRetries = 3

    /// The account signed in / out since the list was loaded: the flags in it belong to someone else.
    var viewerChanged: Bool { didStart && viewerAtStart != TemplateAPI.currentOwner }

    /// Begins a fresh list (first page) of the given source.
    func start(_ newSource: TemplateFeedSource) async {
        generation += 1
        let gen = generation
        source = newSource
        cursor = nil
        hasMore = true
        errorMessage = nil
        didStart = false
        viewerAtStart = TemplateAPI.currentOwner
        await loadPage(replacing: true, gen: gen, emptyRetries: 0)
    }

    func restart() async {
        await start(source)
    }

    /// Call when a card appears: loads the next page when it is one of the last few.
    func loadNextIfNeeded(near template: TemplateData) {
        guard hasMore, !isLoading, let index = items.firstIndex(where: { $0.id == template.id }),
              index >= items.count - prefetchDistance else { return }
        let gen = generation
        Task { await loadPage(replacing: false, gen: gen, emptyRetries: 0) }
    }

    /// The preview pager asks by position.
    func loadNextIfNeeded(afterIndex index: Int) {
        guard hasMore, !isLoading, index >= items.count - 3 else { return }
        let gen = generation
        Task { await loadPage(replacing: false, gen: gen, emptyRetries: 0) }
    }

    private func loadPage(replacing: Bool, gen: Int, emptyRetries: Int) async {
        if !replacing && (isLoading || !hasMore) { return }
        isLoading = true
        do {
            let page = try await TemplateAPI.fetchPage(source, cursor: replacing ? nil : cursor)
            guard gen == generation else { return }          // an older source: drop (the newer one manages isLoading)
            cursor = page.nextCursor
            hasMore = page.hasMore

            if replacing { delivered = [] }
            var fresh: [TemplateData] = []
            for t in page.items where delivered.insert(t.templateId.lowercased()).inserted { fresh.append(t) }
            if replacing { items = fresh } else { items.append(contentsOf: fresh) }
            didStart = true
            isLoading = false

            if fresh.isEmpty && hasMore && emptyRetries < maxEmptyRetries {
                // A whole page of repeats: ask for the next one.
                await loadPage(replacing: false, gen: gen, emptyRetries: emptyRetries + 1)
            }
        } catch {
            guard gen == generation else { return }
            isLoading = false
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }   // refresh / view went away
            errorMessage = error.localizedDescription
        }
    }
}
