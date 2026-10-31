import SwiftUI

/// The search screen (pushed from the Templates tab's search bar).
///
///  - Empty field: recent searches (this phone), "You may like" and the ranked "Trending" list (server).
///  - Typing: suggestions from the server (instant local matches first); the ↖ arrow copies one into the field.
///  - Search / Return / a tapped row: the results, paged from the server by the same pager the Templates tab uses.
///    Tapping the field again goes back to the suggestions.
struct TemplateSearchView: View {
    let placeholder: String
    /// Titles of templates the app already has: suggestions when the server has none.
    let fallbackTitles: [String]
    @Binding var path: NavigationPath

    private enum Phase { case input, results }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager = TemplatePager()
    @ObservedObject private var hints = TemplateSearchHints.shared
    @ObservedObject private var history = TemplateSearchHistory.shared
    @ObservedObject private var states = TemplateStateStore.shared

    @State private var text = ""
    @State private var phase: Phase = .input
    @State private var showAllHistory = false
    @State private var serverSuggestions: [String] = []
    @State private var serverSuggestionsFor = ""
    @FocusState private var focused: Bool

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.mdBackground.edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                topBar
                switch phase {
                case .input: inputBody
                case .results: resultsBody
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(for: SearchPreviewRoute.self) { route in
            if let index = pager.items.firstIndex(where: { $0.id == route.templateId }) {
                TemplatePreviewView(pager: pager, initialScrollIndex: index)
            }
        }
        .task {
            await hints.refresh()
            try? await Task.sleep(nanoseconds: 350_000_000)   // let the push finish, then raise the keyboard
            if phase == .input { focused = true }
        }
        .task(id: text) { await loadSuggestions() }
        .onChange(of: focused) { _, isFocused in
            if isFocused { phase = .input }   // tapping the field in the results = back to the suggestions
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 16))
                TextField("", text: $text,
                          prompt: Text(placeholder.isEmpty ? L("Search templates...") : placeholder).foregroundColor(.secondary))
                    .focused($focused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { submit(nil) }
                if !text.isEmpty {
                    Button(action: clearField) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.mdSurfaceContainerHigh)
            .clipShape(Capsule())

            if phase == .input {
                Button(action: { submit(nil) }) {
                    Text("Search")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    // MARK: suggestions / start page

    private var inputBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if typed.isEmpty { startPage } else { suggestionRows }
            }
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var suggestionRows: some View {
        ForEach(shownSuggestions, id: \.self) { suggestion in
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 16))
                highlighted(suggestion).font(.system(size: 17)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: { text = suggestion }) {   // copy into the field, keep typing
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .onTapGesture { submit(suggestion) }
        }
    }

    @ViewBuilder private var startPage: some View {
        // Recent searches
        let rows = showAllHistory ? history.items : Array(history.items.prefix(2))
        ForEach(rows, id: \.self) { item in
            HStack(spacing: 12) {
                Image(systemName: "clock").foregroundColor(.primary).font(.system(size: 16))
                Text(item).font(.system(size: 17)).foregroundColor(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: { history.remove(item) }) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .onTapGesture { submit(item) }
        }
        if history.items.count > 2 {
            Button(action: { withAnimation { showAllHistory.toggle() } }) {
                Text(showAllHistory ? "Show less" : "Show all searches")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }

        // You may like
        if !hints.forYou.isEmpty {
            sectionTitle("You may like")
            ForEach(hints.forYou, id: \.self) { item in
                HStack(spacing: 12) {
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5).padding(.leading, 8)
                    Text(item).font(.system(size: 17)).foregroundColor(.primary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { submit(item) }
            }
        }

        // Trending
        if !hints.trending.isEmpty {
            sectionTitle("Trending")
            ForEach(Array(hints.trending.enumerated()), id: \.element.id) { rank, item in
                HStack(spacing: 14) {
                    Text("\(rank + 1)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(rank < 3 ? .mdPrimary : .secondary)
                        .frame(width: 28)
                    Text(item.text).font(.system(size: 17)).foregroundColor(.primary).lineLimit(1)
                    if item.isHot { Image(systemName: "flame.fill").foregroundColor(.orange).font(.system(size: 14)) }
                    Spacer(minLength: 8)
                    if let count = item.count {
                        Text(Self.compact(count)).font(.system(size: 13)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16).frame(minHeight: 46)
                .contentShape(Rectangle())
                .onTapGesture { submit(item.text) }
            }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }

    // MARK: results

    private var resultsBody: some View {
        TemplateMasonryGrid(templates: pager.items,
                            isLoading: pager.isLoading,
                            emptyText: pager.didStart ? L("No templates found") : nil,
                            onSelect: { path.append(SearchPreviewRoute(templateId: $0.id)) },
                            onAppearItem: { pager.loadNextIfNeeded(near: $0) })
            .refreshable { await pager.restart() }
    }

    // MARK: actions

    private func submit(_ chosen: String?) {
        var query = (chosen ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { query = placeholder }          // an empty Search press searches the hot term in the bar
        guard !query.isEmpty else { return }
        text = query
        focused = false
        phase = .results
        history.add(query)
        Task { await TemplateSearchAPI.logSearch(query) }
        Task { await pager.start(.search(query)) }
    }

    private func clearField() {
        text = ""
        phase = .input
        focused = true
    }

    // MARK: suggestion data

    private var shownSuggestions: [String] {
        serverSuggestionsFor == typed.lowercased() && !serverSuggestions.isEmpty ? serverSuggestions : localSuggestions
    }

    /// Instant matches from the phone while the server answers (and when it cannot): history first, then known titles.
    private var localSuggestions: [String] {
        let needle = typed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        let pool = history.items + hints.trending.map(\.text) + fallbackTitles
        let hits = pool.filter { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) }
        let ranked = hits.sorted { a, b in
            let ap = a.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
            let bp = b.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
            return ap && !bp
        }
        return ranked.filter { seen.insert($0.lowercased()).inserted }.prefix(10).map { $0 }
    }

    private func loadSuggestions() async {
        let query = typed
        guard phase == .input, !query.isEmpty else { serverSuggestions = []; serverSuggestionsFor = ""; return }
        try? await Task.sleep(nanoseconds: 250_000_000)       // typing again cancels this run: the debounce
        if Task.isCancelled { return }
        if let found = try? await TemplateSearchAPI.fetchSuggestions(query), !Task.isCancelled {
            serverSuggestions = found
            serverSuggestionsFor = query.lowercased()
        }
    }

    /// The typed part grey, the rest of the suggestion black (like CapCut).
    private func highlighted(_ suggestion: String) -> Text {
        let n = typed.count
        if n > 0, suggestion.lowercased().hasPrefix(typed.lowercased()) {
            return Text(String(suggestion.prefix(n))).foregroundColor(.secondary)
                + Text(String(suggestion.dropFirst(n))).foregroundColor(.primary)
        }
        return Text(suggestion).foregroundColor(.primary)
    }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
