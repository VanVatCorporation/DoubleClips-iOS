import Foundation

// "My statistics" from the server (Profile → Statistics): GET /templates/stats.
// Contract: docs/doubleclips-template-api-v2.md → "Author statistics". The server does the counting (all-time totals, other
// people's activity per local day for this period and the one before it, and the account's templates with their counters), so
// nothing here pages through the template list.

/// The answer of `GET /templates/stats`.
struct AuthorStats: Decodable {
    /// All time: the templates' own counters, plus the distinct people who opened them (the author excluded).
    struct Totals: Decodable {
        let templates: Int
        let views: Int
        let uses: Int
        let likes: Int
        let saves: Int
        let comments: Int
        let uniqueViewers: Int
    }

    /// Other people's activity over a whole period.
    struct Counts: Decodable {
        let newViewers: Int
        let uses: Int
        let likes: Int
        let saves: Int
        let comments: Int
    }

    struct Period: Decodable {
        let current: Counts
        let previous: Counts
    }

    /// One local day (`yyyy-MM-dd`) of the current period.
    struct Day: Decodable, Identifiable {
        let date: String
        let newViewers: Int
        let uses: Int
        let likes: Int
        let saves: Int
        let comments: Int
        var id: String { date }
    }

    struct Item: Decodable, Identifiable {
        let templateId: String
        let title: String?
        let dateMs: Int64?
        let views: Int
        let uses: Int
        let likes: Int
        let saves: Int
        let comments: Int
        var id: String { templateId }
    }

    let days: Int
    let totals: Totals
    let period: Period
    /// The current period, oldest day first.
    let series: [Day]
    /// The account's newest 100 templates.
    let templates: [Item]
    let templatesTruncated: Bool
}

@MainActor
enum AuthorStatsAPI {
    /// No local HTTP cache: the numbers must be the server's.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// - Parameter days: the length of the period, 7...90; the server also loads the same number of days before it, for the trend.
    static func fetch(days: Int) async throws -> AuthorStats {
        guard let me = TemplateAPI.viewer else { throw TemplateAPIError.loginRequired }

        // The days are the user's LOCAL days: tell the server how far this phone is from UTC (minutes east, Vietnam = 420).
        let tz = TimeZone.current.secondsFromGMT() / 60

        guard var components = URLComponents(string: TemplateAPI.base + "/templates/stats") else { throw TemplateAPIError.badResponse }
        components.queryItems = [
            URLQueryItem(name: "days", value: String(days)),
            URLQueryItem(name: "tz", value: String(tz)),
            URLQueryItem(name: "viewer", value: me),
        ]
        guard let url = components.url else { throw TemplateAPIError.badResponse }

        var request = URLRequest(url: url)
        request.setValue(TemplateAPI.deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TemplateAPIError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            var message = "Error \(http.statusCode)"
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let text = object["returnResult"] as? String { message = text }
            throw TemplateAPIError.server(message)
        }
        do {
            return try JSONDecoder().decode(AuthorStats.self, from: data)
        } catch {
            throw TemplateAPIError.badResponse
        }
    }
}
