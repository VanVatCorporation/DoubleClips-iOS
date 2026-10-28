import Foundation
import Combine

// The Templates backend (app.vanvatcorp.com/doubleclips/api, backend v2) and the one place the app talks to it.
// Contract: docs/doubleclips-template-api-v2.md.
//
// ONE state store: every like / bookmark / count the app learns (from a page, a like, a view...) lands in
// `TemplateStateStore`, and every screen reads templates back through `applied(_:)`. That is what keeps the grid,
// the preview pager and the Profile lists showing the same numbers.

/// Which list of templates a screen shows.
enum TemplateFeedSource: Hashable, Identifiable {
    case feed                  // the Templates tab: per-account suggestions
    case search(String)
    case liked                 // Profile → Liked Templates
    case bookmarked            // Profile → Saved Templates
    case mine                  // Profile → My Templates: what this account posted, newest first

    var id: String {
        switch self {
        case .feed: return "feed"
        case .search(let query): return "search:" + query
        case .liked: return "liked"
        case .bookmarked: return "bookmarked"
        case .mine: return "mine"
        }
    }
}

/// One page of the server's list envelope.
struct TemplatePage {
    var items: [TemplateData]
    var nextCursor: String?
    var hasMore: Bool
    var personalized: Bool
}

/// What the server last said about one template, for this viewer.
struct TemplateState: Equatable {
    var isLiked: Bool
    var isBookmarked: Bool
    var viewCount: Int
    var useCount: Int
    var heartCount: Int
    var bookmarkCount: Int
    var commentCount: Int

    init(_ t: TemplateData) {
        isLiked = t.isLiked ?? false
        isBookmarked = t.isBookmarked ?? false
        viewCount = t.viewCount
        useCount = t.useCount
        heartCount = t.heartCount
        bookmarkCount = t.bookmarkCount
        commentCount = t.commentCount
    }
}

enum TemplateAPIError: LocalizedError {
    case loginRequired
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .loginRequired: return L("Please login first")
        case .server(let message): return message
        case .badResponse: return L("Unexpected answer from the server")
        }
    }
}

// MARK: - Shared state

@MainActor
final class TemplateStateStore: ObservableObject {
    static let shared = TemplateStateStore()

    @Published private(set) var states: [String: TemplateState] = [:]
    /// The account the cached flags belong to; another one (sign in / out) must not inherit them.
    private var owner: String = TemplateAPI.currentOwner
    private var tickets: [String: Int] = [:]
    private var reportedViews = Set<String>()

    private func key(_ id: String) -> String { id.lowercased() }

    /// The newest numbers the app knows for this template (a pure read: safe to call from a view body).
    func state(for t: TemplateData) -> TemplateState {
        if owner == TemplateAPI.currentOwner, let s = states[key(t.templateId)] { return s }
        return TemplateState(t)
    }

    func applied(_ t: TemplateData) -> TemplateData {
        guard owner == TemplateAPI.currentOwner, let s = states[key(t.templateId)] else { return t }
        var c = t
        c.isLiked = s.isLiked
        c.isBookmarked = s.isBookmarked
        c.viewCount = s.viewCount
        c.useCount = s.useCount
        c.heartCount = s.heartCount
        c.bookmarkCount = s.bookmarkCount
        c.commentCount = s.commentCount
        return c
    }

    /// Anything the server sends about a template is the newest truth.
    func remember(_ items: [TemplateData]) {
        syncOwner()
        var next = states
        for t in items { next[key(t.templateId)] = TemplateState(t) }
        states = next
    }

    func set(_ id: String, _ state: TemplateState) {
        syncOwner()
        states[key(id)] = state
    }

    func syncOwner() {
        let now = TemplateAPI.currentOwner
        if owner != now {
            states = [:]
            tickets = [:]
            owner = now
        }
    }

    /// Only the newest tap per template + kind may report back, so a slow older answer cannot overwrite a newer one.
    func nextTicket(_ id: String, _ kind: String) -> Int {
        let k = kind + "|" + key(id)
        let n = (tickets[k] ?? 0) + 1
        tickets[k] = n
        return n
    }

    func isLatest(_ id: String, _ kind: String, _ ticket: Int) -> Bool {
        tickets[kind + "|" + key(id)] == ticket
    }

    /// true the first time a view is reported for this template in this run of the app.
    func markViewReported(_ id: String) -> Bool {
        reportedViews.insert(key(id)).inserted
    }
}

// MARK: - Requests

@MainActor
enum TemplateAPI {
    static let base = "https://app.vanvatcorp.com/doubleclips/api"
    static let pageSize = 20

    /// No local HTTP cache: the lists and counters must always be the server's.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// The signed-in username, or nil. (Self-asserted for now: the server has no token for the native apps yet.)
    static var viewer: String? {
        let name = AuthRepository.shared.currentUser?.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

    static var currentOwner: String { viewer?.lowercased() ?? "" }

    /// A random id kept on this install: lets the server dedupe views and avoid repeats for a signed-out user.
    static var deviceId: String {
        let key = "TemplateDeviceId"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    // MARK: lists

    static func fetchPage(_ source: TemplateFeedSource, cursor: String?, limit: Int = pageSize) async throws -> TemplatePage {
        TemplateStateStore.shared.syncOwner()
        var path = "/templates/feed"
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        switch source {
        case .feed: path = "/templates/feed"
        case .liked: path = "/templates/liked"
        case .bookmarked: path = "/templates/bookmarked"
        case .mine:
            // The same endpoint as browse, filtered by author = this account.
            guard let me = viewer else { throw TemplateAPIError.loginRequired }
            path = "/templates"
            query.append(URLQueryItem(name: "author", value: me))
            query.append(URLQueryItem(name: "sort", value: "new"))
        case .search(let text):
            path = "/templates"
            query.append(URLQueryItem(name: "q", value: text))
        }
        if let cursor = cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let viewer = viewer { query.append(URLQueryItem(name: "viewer", value: viewer)) }

        guard var components = URLComponents(string: base + path) else { throw TemplateAPIError.badResponse }
        components.queryItems = query
        // URLComponents leaves "+" alone, which the server would read as a space ("a+b" typed in the search box).
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw TemplateAPIError.badResponse }

        var request = URLRequest(url: url)
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        guard let page = TemplateData.decodePage(from: data) else { throw TemplateAPIError.badResponse }
        TemplateStateStore.shared.remember(page.items)
        return page
    }

    // MARK: like / bookmark

    /// Likes (liked == true) or unlikes. The screen answers at once; the request carries the wanted state, so a retry or a
    /// double tap cannot undo itself; the server's numbers then replace ours. On failure the screen goes back.
    static func setLike(_ template: TemplateData, liked: Bool) async throws {
        try await setInteraction(template, kind: "like", path: "/toggle-like", flag: "liked", answer: "isLiked", value: liked)
    }

    static func setBookmark(_ template: TemplateData, bookmarked: Bool) async throws {
        try await setInteraction(template, kind: "bookmark", path: "/toggle-bookmark", flag: "bookmarked", answer: "isBookmarked", value: bookmarked)
    }

    private static func setInteraction(_ template: TemplateData, kind: String, path: String, flag: String,
                                       answer: String, value: Bool) async throws {
        guard let user = viewer else { throw TemplateAPIError.loginRequired }
        let store = TemplateStateStore.shared
        store.syncOwner()
        let id = template.templateId

        // 1. instant answer
        let previous = store.state(for: template)
        var optimistic = previous
        if kind == "like" {
            if optimistic.isLiked != value { optimistic.heartCount = max(0, optimistic.heartCount + (value ? 1 : -1)) }
            optimistic.isLiked = value
        } else {
            if optimistic.isBookmarked != value { optimistic.bookmarkCount = max(0, optimistic.bookmarkCount + (value ? 1 : -1)) }
            optimistic.isBookmarked = value
        }
        store.set(id, optimistic)
        let ticket = store.nextTicket(id, kind)

        // 2. ask the server
        do {
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["username": user, "templateId": id, flag: value] as [String: Any])
            let (data, response) = try await session.data(for: request)
            try check(response, data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TemplateAPIError.badResponse }

            // 3. the server's numbers replace ours (only if no newer tap happened meanwhile)
            if store.isLatest(id, kind, ticket) {
                var truth = store.state(for: template)
                if let flagValue = object[answer] as? Bool {
                    if kind == "like" { truth.isLiked = flagValue } else { truth.isBookmarked = flagValue }
                }
                readCounts(object, into: &truth)
                store.set(id, truth)
            }
        } catch {
            if store.isLatest(id, kind, ticket) { store.set(id, previous) }
            throw error
        }
    }

    // MARK: view / use

    /// The template came on screen. The server counts it once per viewer per 30 minutes.
    static func postView(_ templateId: String) async {
        guard TemplateStateStore.shared.markViewReported(templateId) else { return }
        await postCounter(path: "/increment-view", templateId: templateId, answer: "newViewCount") { state, n in state.viewCount = n }
    }

    /// The template was actually used (exported).
    static func postUse(_ templateId: String) async {
        await postCounter(path: "/increment-use", templateId: templateId, answer: "newUseCount") { state, n in state.useCount = n }
    }

    private static func postCounter(path: String, templateId: String, answer: String,
                                    apply: (inout TemplateState, Int) -> Void) async {
        guard let url = URL(string: base + path) else { return }
        var body: [String: Any] = ["templateId": templateId]
        if let viewer = viewer { body["username"] = viewer }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Best effort: a lost counter must never bother the user.
        guard let (data, response) = try? await session.data(for: request), (try? check(response, data)) != nil,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = object[answer] as? Int else { return }
        let store = TemplateStateStore.shared
        let key = templateId
        if var state = store.states[key.lowercased()] {
            apply(&state, n)
            store.set(key, state)
        }
    }

    // MARK: plumbing

    private static func readCounts(_ object: [String: Any], into state: inout TemplateState) {
        if let v = object["viewCount"] as? Int { state.viewCount = v }
        if let v = object["useCount"] as? Int { state.useCount = v }
        if let v = object["heartCount"] as? Int { state.heartCount = v }
        if let v = object["bookmarkCount"] as? Int { state.bookmarkCount = v }
        if let v = object["commentCount"] as? Int { state.commentCount = v }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw TemplateAPIError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            var message = "Error \(http.statusCode)"
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let text = object["returnResult"] as? String { message = text }
            throw TemplateAPIError.server(message)
        }
    }
}
