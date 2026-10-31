import Foundation
import Combine

// Template search: hot searches ("Trending"), suggestions while typing, and the local search history.
// Contract: DoubleClips-Template-Search-Contract.md (new endpoints under /templates/search/...).
// The results themselves come from the existing `GET /templates?q=` through `TemplatePager` (`.search(text)`).

/// One hot search, as the server ranks it.
struct TrendingSearch: Identifiable, Hashable {
    let text: String
    /// How many searches it had lately (shown on the right of the trending list); nil = not sent.
    let count: Int?
    /// Gets the little flame.
    let isHot: Bool
    var id: String { text.lowercased() }
}

/// Pushed on the Templates tab's NavigationStack to open the search screen.
struct TemplateSearchRoute: Hashable {
    /// The hot search that was showing in the bar when it was tapped: the field's placeholder, and what an empty
    /// "Search" press searches for (like TikTok / CapCut).
    var placeholder: String
}

/// Pushed from the search results to open the swipeable preview of one result.
struct SearchPreviewRoute: Hashable {
    let templateId: String
}

@MainActor
enum TemplateSearchAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    /// `GET /templates/search/trending?limit=` → hot searches, best first.
    static func fetchTrending(limit: Int = 10) async throws -> [TrendingSearch] {
        let object = try await get("/templates/search/trending", [URLQueryItem(name: "limit", value: String(limit))])
        var seen = Set<String>()
        return rows(object).compactMap { row -> TrendingSearch? in
            guard let text = text(of: row), seen.insert(text.lowercased()).inserted else { return nil }
            let dict = row as? [String: Any]
            return TrendingSearch(text: text,
                                  count: int(dict?["count"] ?? dict?["searchCount"] ?? dict?["score"]),
                                  isHot: (dict?["hot"] as? Bool) ?? false)
        }
    }

    /// `GET /templates/search/suggest?q=&limit=`. An empty `prefix` asks for "you may like" (personal, by the viewer).
    static func fetchSuggestions(_ prefix: String, limit: Int = 10) async throws -> [String] {
        let object = try await get("/templates/search/suggest", [URLQueryItem(name: "q", value: prefix),
                                                                  URLQueryItem(name: "limit", value: String(limit))])
        var seen = Set<String>()
        return rows(object).compactMap { text(of: $0) }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// `POST /templates/search/log` — a search the user submitted, so the server can rank "Trending". Best effort.
    static func logSearch(_ query: String) async {
        guard let url = URL(string: TemplateAPI.base + "/templates/search/log") else { return }
        var body: [String: Any] = ["query": query]
        if let viewer = TemplateAPI.viewer { body["username"] = viewer }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TemplateAPI.deviceId, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }

    // MARK: plumbing

    private static func get(_ path: String, _ items: [URLQueryItem]) async throws -> Any {
        var query = items
        if let viewer = TemplateAPI.viewer { query.append(URLQueryItem(name: "viewer", value: viewer)) }
        guard var components = URLComponents(string: TemplateAPI.base + path) else { throw TemplateAPIError.badResponse }
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw TemplateAPIError.badResponse }
        var request = URLRequest(url: url)
        request.setValue(TemplateAPI.deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw TemplateAPIError.badResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Tolerant: `{items:[...]}`, `{data:[...]}` or a bare array; each row a string or an object.
    private static func rows(_ object: Any) -> [Any] {
        if let array = object as? [Any] { return array }
        if let dict = object as? [String: Any] {
            for key in ["items", "data", "results", "keywords"] { if let array = dict[key] as? [Any] { return array } }
        }
        return []
    }

    private static func text(of row: Any) -> String? {
        var value: String?
        if let s = row as? String { value = s }
        else if let dict = row as? [String: Any] {
            value = (dict["query"] ?? dict["text"] ?? dict["keyword"] ?? dict["title"]) as? String
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - Hot searches, shared by the bar and the search screen

@MainActor
final class TemplateSearchHints: ObservableObject {
    static let shared = TemplateSearchHints()

    @Published private(set) var trending: [TrendingSearch] = []
    @Published private(set) var forYou: [String] = []
    private var loadedAt: Date?
    private var loading = false

    /// Loads once and again after 5 minutes (or when forced). Failures keep what is already shown.
    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let at = loadedAt, Date().timeIntervalSince(at) < 300 { return }
        loading = true
        defer { loading = false }
        async let hot = try? TemplateSearchAPI.fetchTrending()
        async let mine = try? TemplateSearchAPI.fetchSuggestions("", limit: 6)
        let (newHot, newMine) = await (hot, mine)
        if let newHot = newHot { trending = newHot }
        if let newMine = newMine { forYou = newMine }
        if newHot != nil || newMine != nil { loadedAt = Date() }
    }
}

// MARK: - Search history (this phone only)

@MainActor
final class TemplateSearchHistory: ObservableObject {
    static let shared = TemplateSearchHistory()
    private let key = "TemplateSearchHistory"
    private let limit = 20

    @Published private(set) var items: [String]

    private init() { items = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var next = items.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        next.insert(q, at: 0)
        items = Array(next.prefix(limit))
        save()
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() { UserDefaults.standard.set(items, forKey: key) }
}
