import Foundation
import Combine

// MARK: - Assets: community assets on top of Van Vat Drive
//
// The Assets tab shows files that people posted from their Drive (the OpenEditz folder). A posted file stays in its poster's Drive; the
// server only keeps a catalog entry and shows it while the file is live AND "anyone with the link" covers it, so restricting the
// file in Drive or OpenEditz (or trashing it) takes it off the tab by itself. Contract: docs/vanvat-drive-assets-api.md.

enum AssetKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case video, image, audio, font, effect, pack

    var id: String { rawValue }

    /// The filter chip.
    var title: String {
        switch self {
        case .video: return "Videos"
        case .image: return "Images"
        case .audio: return "Audio"
        case .font: return "Fonts"
        case .effect: return "Effects"
        case .pack: return "Packs"
        }
    }

    /// Singular, for one asset.
    var singular: String {
        switch self {
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        case .font: return "Font"
        case .effect: return "Effect"
        case .pack: return "Animation pack"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .font: return "textformat"
        case .effect: return "wand.and.stars"
        case .pack: return "shippingbox"
        }
    }

    /// File extensions the server accepts for this kind.
    var extensions: [String] {
        switch self {
        case .video: return ["mp4", "mov", "m4v", "webm"]
        case .image: return ["jpg", "jpeg", "png", "webp", "heic", "gif"]
        case .audio: return ["mp3", "m4a", "aac", "wav", "ogg", "flac"]
        case .font: return ["ttf", "otf", "ttc", "otc"]
        case .effect: return ["json"]
        case .pack: return ["zip"]
        }
    }

    static func detect(fileName: String) -> AssetKind? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }
}

struct CommunityAsset: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let description: String?
    let tags: [String]
    let ownerName: String?
    let fileName: String?
    let size: Int64
    let mimeType: String?
    let previewUrl: URL?
    let downloads: Int64
    let createdAt: Date

    var kindValue: AssetKind { AssetKind(rawValue: kind) ?? .pack }
}

/// An asset of mine: the public fields plus the state of the link behind it.
struct MyAsset: Decodable, Identifiable, Hashable {
    let id: String
    let nodeId: String
    let kind: String
    let title: String
    let description: String?
    let tags: [String]
    let fileName: String?
    let size: Int64
    let previewUrl: URL?
    let downloads: Int64
    let reportCount: Int
    let createdAt: Date
    /// public (listed) | restricted (no active link) | review (hidden by reports) | deleted (file in the trash)
    let state: String
    /// link | folder: what makes it public (folder = a link on a folder above it)
    let via: String?
    let folderName: String?

    var kindValue: AssetKind { AssetKind(rawValue: kind) ?? .pack }
}

/// Talks to the Drive host with the app's account token (see DoubleClipsDrive). Browsing needs no login.
struct AssetsClient {
    static let shared = AssetsClient()
    private var drive: DriveClient { DoubleClipsDrive.client }

    struct Page { let items: [CommunityAsset]; let next: String? }

    private struct Ok: Decodable {}

    private func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, query: [String: String?] = [:],
                                    body: (any Encodable)? = nil, auth: Bool = true) async throws -> T {
        let req = try drive.makeRequest(method, path, query: query, body: body, auth: auth)
        let (data, response) = try await drive.session.data(for: req)
        try drive.check(response, data)
        return try JSONDecoder.drive.decode(T.self, from: data)
    }

    // MARK: Browse (public)

    func list(kind: AssetKind?, query: String, sort: String, cursor: String?) async throws -> Page {
        struct R: Decodable { let items: [CommunityAsset]; let nextCursor: String? }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try await send(R.self, "GET", "/public/assets",
                               query: ["kind": kind?.rawValue, "q": q.isEmpty ? nil : q, "sort": sort, "cursor": cursor, "limit": "24"],
                               auth: false)
        return Page(items: r.items, next: r.nextCursor)
    }

    // MARK: Search: hot searches and suggestions (public), logging a search (signed in)

    /// The ranked hot searches ("Trending"), best first.
    func trending(limit: Int = 10) async throws -> [TrendingSearch] {
        struct Row: Decodable { let query: String; let count: Int?; let hot: Bool? }
        struct R: Decodable { let items: [Row] }
        let r = try await send(R.self, "GET", "/public/assets/search/trending", query: ["limit": String(limit)], auth: false)
        return r.items.map { TrendingSearch(text: $0.query, count: $0.count, isHot: $0.hot ?? false) }
    }

    /// Autocomplete for what is typed; an empty string asks for "You may like".
    func suggest(_ typed: String, limit: Int = 10) async throws -> [String] {
        struct R: Decodable { let items: [String] }
        return try await send(R.self, "GET", "/public/assets/search/suggest", query: ["q": typed, "limit": String(limit)], auth: false).items
    }

    /// A search the person submitted, so "Trending" can rank it. Only signed-in searches count (one person can't push a term up).
    func logSearch(_ query: String) async {
        guard DoubleClipsDrive.sessionToken() != nil else { return }
        struct B: Encodable { let query: String }
        _ = try? await send(Ok.self, "POST", "/assets/search/log", body: B(query: query))
    }

    // MARK: Download (login needed; charged to my daily allowance)

    func download(_ asset: CommunityAsset, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let req = try drive.makeRequest("GET", "/assets/\(asset.id)/content")
        return try await drive.downloadFile(req, id: "asset-" + asset.id, name: asset.fileName ?? asset.id, progress: progress)
    }

    func report(_ asset: CommunityAsset, reason: String, note: String) async throws {
        struct B: Encodable { let reason: String; let note: String }
        _ = try await send(Ok.self, "POST", "/assets/\(asset.id)/report", body: B(reason: reason, note: note))
    }

    // MARK: Mine

    func mine() async throws -> [MyAsset] {
        struct R: Decodable { let items: [MyAsset] }
        return try await send(R.self, "GET", "/assets/mine").items
    }

    func publish(node: DriveNode, kind: AssetKind, title: String, description: String, tags: [String]) async throws -> MyAsset {
        struct B: Encodable { let nodeId: String; let kind: String; let title: String; let description: String; let tags: [String]; let rights: Bool }
        struct R: Decodable { let asset: MyAsset }
        return try await send(R.self, "POST", "/assets",
                              body: B(nodeId: node.id, kind: kind.rawValue, title: title, description: description, tags: tags, rights: true)).asset
    }

    func update(_ asset: MyAsset, title: String, description: String, tags: [String]) async throws -> MyAsset {
        struct B: Encodable { let title: String; let description: String; let tags: [String] }
        struct R: Decodable { let asset: MyAsset }
        return try await send(R.self, "PATCH", "/assets/\(asset.id)", body: B(title: title, description: description, tags: tags)).asset
    }

    /// A JPEG of at most 200 KB.
    func uploadPreview(assetId: String, jpeg: Data) async throws {
        var req = try drive.makeRequest("PUT", "/assets/\(assetId)/preview")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await drive.session.upload(for: req, from: jpeg)
        try drive.check(response, data)
    }

    /// Takes it off the tab; the file stays in Drive. `revokeLink` also removes the file's own link.
    func remove(_ asset: MyAsset, revokeLink: Bool) async throws {
        _ = try await send(Ok.self, "DELETE", "/assets/\(asset.id)", query: ["revokeLink": revokeLink ? "1" : nil])
    }

    /// "Restricted". Throws a DriveError with code `inherited_link` when a folder's link still covers the file.
    func restrict(_ asset: MyAsset) async throws -> MyAsset {
        struct R: Decodable { let asset: MyAsset }
        return try await send(R.self, "POST", "/assets/\(asset.id)/restrict").asset
    }

    /// Back to "anyone with the link".
    func share(_ asset: MyAsset) async throws -> MyAsset {
        struct R: Decodable { let asset: MyAsset }
        return try await send(R.self, "POST", "/assets/\(asset.id)/share").asset
    }
}

/// People whose assets this phone hides. Local to the phone, like the report button it goes with. Names are compared in lower case;
/// the name as it was written is kept too, so Settings > Hidden content can show it.
enum BlockedAuthors {
    private static let key = "AssetsBlockedAuthors"            // lower-case names: what is compared
    private static let namesKey = "AssetsBlockedAuthorNames"    // lower-case name -> the name as written: what is shown

    static var all: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func contains(_ name: String?) -> Bool { name.map { all.contains($0.lowercased()) } ?? false }

    private static var written: [String: String] {
        UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    /// The hidden names as they were written, alphabetical.
    static var displayNames: [String] {
        let names = written
        return all.map { names[$0] ?? $0 }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func block(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var set = all
        set.insert(trimmed.lowercased())
        var names = written
        names[trimmed.lowercased()] = trimmed
        UserDefaults.standard.set(Array(set), forKey: key)
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    static func unblock(_ name: String) {
        var set = all
        set.remove(name.lowercased())
        var names = written
        names.removeValue(forKey: name.lowercased())
        UserDefaults.standard.set(Array(set), forKey: key)
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    static func unblockAll() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: namesKey)
    }
}

/// Everything the user hid on this phone: asset authors ("Hide assets from X" in the Assets tab) and templates ("Hide this template"
/// in the long-press menu and the preview). Both stay on this phone. Settings > Hidden content lists them and shows them again.
/// Screens that draw lists observe this, so a hide or a "show again" is reflected at once; a list that was already loaded without a
/// template reloads (see `unhideStamp`) to bring it back.
@MainActor
final class HiddenContent: ObservableObject {
    static let shared = HiddenContent()

    struct HiddenTemplate: Codable, Identifiable, Hashable {
        let id: String            // the template's id
        var title: String
        var author: String
    }

    @Published private(set) var authors: [String]
    @Published private(set) var templates: [HiddenTemplate]
    /// Goes up whenever something is shown again: a feed loaded before that has to reload to bring it back.
    @Published private(set) var unhideStamp = 0

    private static let templatesKey = "HiddenTemplates"
    private var templateIds: Set<String>

    private init() {
        authors = BlockedAuthors.displayNames
        let stored = UserDefaults.standard.data(forKey: Self.templatesKey)
            .flatMap { try? JSONDecoder().decode([HiddenTemplate].self, from: $0) } ?? []
        templates = stored
        templateIds = Set(stored.map { $0.id.lowercased() })
    }

    // MARK: asset authors

    func hideAuthor(_ name: String) {
        BlockedAuthors.block(name)
        authors = BlockedAuthors.displayNames
    }

    func showAuthor(_ name: String) {
        BlockedAuthors.unblock(name)
        authors = BlockedAuthors.displayNames
        unhideStamp += 1
    }

    func showAllAuthors() {
        BlockedAuthors.unblockAll()
        authors = []
        unhideStamp += 1
    }

    // MARK: templates

    func isHidden(templateId: String) -> Bool { templateIds.contains(templateId.lowercased()) }

    func hide(_ template: TemplateData) {
        let id = template.templateId
        guard !id.isEmpty, !isHidden(templateId: id) else { return }
        templates.append(HiddenTemplate(id: id, title: template.templateTitle, author: template.templateAuthor))
        templateIds.insert(id.lowercased())
        saveTemplates()
    }

    func show(templateId: String) {
        templates.removeAll { $0.id.lowercased() == templateId.lowercased() }
        templateIds.remove(templateId.lowercased())
        saveTemplates()
        unhideStamp += 1
    }

    func showAllTemplates() {
        templates = []
        templateIds = []
        saveTemplates()
        unhideStamp += 1
    }

    private func saveTemplates() {
        UserDefaults.standard.set(try? JSONEncoder().encode(templates), forKey: Self.templatesKey)
    }
}
