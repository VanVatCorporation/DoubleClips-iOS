// Embedded copy of VanVatDriveKit (Sources/VanVatDriveKit/DriveClient.swift) so DoubleClips needs no package setup.
// Keep in sync with the package; replace with the package dependency later if you prefer.
import Foundation

public struct DriveEndpoints: Sendable {
    public var drive: URL
    public init(drive: URL = URL(string: "https://drive.vanvatcorp.com")!) { self.drive = drive }
}

private struct Empty: Decodable {}
private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Typed client for the Van Vat Drive API (docs/vanvat-drive-internal-api.md). Auth is `Authorization: Bearer <jwt>`.
public final class DriveClient: @unchecked Sendable {
    public let endpoints: DriveEndpoints
    let session: URLSession                 // internal: Thumbnails.swift downloads with it
    private let tokenProvider: @Sendable () -> String?

    /// The server sends a fresh JWT (X-Refreshed-Token) when the current one is close to expiring: store it.
    public var onTokenRefreshed: (@Sendable (String) -> Void)?
    /// Called on any 401, so the app can sign out.
    public var onUnauthorized: (@Sendable () -> Void)?
    /// Called when the API refuses with 403 tos_required: new terms were published, the app should refresh /me (its `legal` then shows the popup).
    public var onTosRequired: (@Sendable () -> Void)?

    public init(endpoints: DriveEndpoints = DriveEndpoints(), tokenProvider: @escaping @Sendable () -> String?) {
        self.endpoints = endpoints
        self.tokenProvider = tokenProvider
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false          // Bearer only; never mix with the browser cookie
        cfg.httpCookieAcceptPolicy = .never
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Plumbing

    func makeRequest(_ method: String, _ path: String, query: [String: String?] = [:], body: (any Encodable)? = nil, auth: Bool = true,
                     prefix: String = "api/v2/drive") throws -> URLRequest {
        guard var comps = URLComponents(url: endpoints.drive.appendingPathComponent(prefix + path), resolvingAgainstBaseURL: false) else {
            throw DriveError(status: 0, message: "Bad URL")
        }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { throw DriveError(status: 0, message: "Bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth, let token = tokenProvider() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(value: body))
        }
        return req
    }

    func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw DriveError(status: 0, message: "No response") }
        if let fresh = http.value(forHTTPHeaderField: "X-Refreshed-Token"), !fresh.isEmpty { onTokenRefreshed?(fresh) }
        guard (200..<300).contains(http.statusCode) else {
            var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            var code: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = (obj["message"] as? String) ?? message
                code = obj["code"] as? String
            }
            if http.statusCode == 401 { onUnauthorized?() }
            if http.statusCode == 403, code == "tos_required" { onTosRequired?() }
            throw DriveError(status: http.statusCode, code: code, message: message)
        }
    }

    private func send<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String,
                                    query: [String: String?] = [:], body: (any Encodable)? = nil, auth: Bool = true) async throws -> T {
        let req = try makeRequest(method, path, query: query, body: body, auth: auth)
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return try JSONDecoder.drive.decode(T.self, from: data)
    }

    // MARK: - Account

    public func me() async throws -> Me { try await send(Me.self, "GET", "/me") }

    /// The protected OpenEditz folder at the top of the user's space (created on first call).
    public func ensureOpenEditz() async throws -> DriveNode {
        struct R: Decodable { let node: DriveNode }
        return try await send(R.self, "POST", "/system/openeditz").node
    }

    // MARK: - Browse

    /// parentId nil = my root (things I own).
    public func list(parentId: String?) async throws -> Listing {
        try await send(Listing.self, "GET", "/nodes", query: ["parentId": parentId, "limit": "500"])
    }

    public func node(id: String) async throws -> DriveNode {
        struct R: Decodable { let node: DriveNode }
        return try await send(R.self, "GET", "/nodes/\(id)").node
    }

    public func shared() async throws -> [SharedItem] {
        struct R: Decodable { let items: [SharedItem] }
        return try await send(R.self, "GET", "/shared").items
    }

    public func trash() async throws -> [DriveNode] {
        struct R: Decodable { let items: [DriveNode] }
        return try await send(R.self, "GET", "/trash").items
    }

    // MARK: - Change

    public func createFolder(parentId: String?, name: String) async throws -> DriveNode {
        struct B: Encodable { let parentId: String?; let name: String }
        struct R: Decodable { let node: DriveNode }
        return try await send(R.self, "POST", "/folders", body: B(parentId: parentId, name: name)).node
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        struct B: Encodable { let name: String }
        struct R: Decodable { let node: DriveNode }
        return try await send(R.self, "PATCH", "/nodes/\(node.id)", body: B(name: name)).node
    }

    /// destination nil = the root (owner only).
    public func move(_ node: DriveNode, to destination: String?) async throws -> DriveNode {
        struct B: Encodable { let parentId: String?; let moveToRoot: Bool? }
        struct R: Decodable { let node: DriveNode }
        let body = destination == nil ? B(parentId: nil, moveToRoot: true) : B(parentId: destination, moveToRoot: nil)
        return try await send(R.self, "PATCH", "/nodes/\(node.id)", body: body).node
    }

    /// Turns image thumbnails on/off for this account (shared with the web and the Drive apps).
    public func updateSettings(previewThumbnails: Bool) async throws {
        struct B: Encodable { let previewThumbnails: Bool }
        _ = try await send(Empty.self, "PUT", "/settings", body: B(previewThumbnails: previewThumbnails))
    }

    public func trash(_ node: DriveNode) async throws { _ = try await send(Empty.self, "DELETE", "/nodes/\(node.id)") }
    public func restore(_ node: DriveNode) async throws { _ = try await send(Empty.self, "POST", "/nodes/\(node.id)/restore") }
    public func purge(_ node: DriveNode) async throws { _ = try await send(Empty.self, "DELETE", "/trash/\(node.id)") }
    public func emptyTrash() async throws { _ = try await send(Empty.self, "DELETE", "/trash") }

    // MARK: - Sharing (people)

    public func access(of node: DriveNode) async throws -> AccessInfo {
        try await send(AccessInfo.self, "GET", "/nodes/\(node.id)/access")
    }

    /// identifier = email or username of a Van Vat account.
    public func grant(_ node: DriveNode, identifier: String, role: DriveRole) async throws {
        struct B: Encodable { let identifier: String; let role: String }
        _ = try await send(Empty.self, "POST", "/nodes/\(node.id)/permissions", body: B(identifier: identifier, role: role.rawValue))
    }

    public func changeRole(permissionId: String, to role: DriveRole) async throws {
        struct B: Encodable { let role: String }
        _ = try await send(Empty.self, "PATCH", "/permissions/\(permissionId)", body: B(role: role.rawValue))
    }

    /// Also how someone removes a folder from their own "Shared with me" (leave).
    public func removeAccess(permissionId: String) async throws {
        _ = try await send(Empty.self, "DELETE", "/permissions/\(permissionId)")
    }

    // MARK: - Sharing (links)

    public func createLink(for node: DriveNode, expiresInHours: Int?, rawServing: Bool = false) async throws -> LinkInfo {
        struct B: Encodable { let expiresInHours: Int?; let rawServing: Bool }
        struct R: Decodable { let share: LinkInfo }
        return try await send(R.self, "POST", "/nodes/\(node.id)/shares", body: B(expiresInHours: expiresInHours, rawServing: rawServing)).share
    }

    public func setRawServing(linkId: String, _ on: Bool) async throws -> LinkInfo {
        struct B: Encodable { let rawServing: Bool }
        struct R: Decodable { let share: LinkInfo }
        return try await send(R.self, "PATCH", "/shares/\(linkId)", body: B(rawServing: on)).share
    }

    public func revokeLink(id: String) async throws { _ = try await send(Empty.self, "DELETE", "/shares/\(id)") }

    // MARK: - Download

    /// Downloads a file into Caches/VanVatDrive/<id>/<name> (the extension matters for Quick Look) and returns its URL.
    /// `progress(loaded, total)` is called a few times a second while the bytes arrive (`total` is 0 when the server doesn't say).
    /// Cancelling the calling Task stops the transfer and throws `CancellationError`.
    public func download(_ node: DriveNode, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let req = try makeRequest("GET", "/files/\(node.id)/content")
        return try await downloadFile(req, id: node.id, name: node.name, progress: progress)
    }

    func downloadFile(_ req: URLRequest, id: String, name: String,
                      progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let result: (URL, URLResponse)
        if let progress {
            result = try await ProgressDownload(progress: progress).run(req, configuration: session.configuration)
        } else {
            result = try await session.download(for: req)
        }
        let tmp = result.0, response = result.1
        try check(response, nil)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VanVatDrive", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Public links (no login)

    public func publicMeta(token: String) async throws -> PublicMeta {
        try await send(PublicMeta.self, "GET", "/public/s/\(token)", auth: false)
    }

    public func publicList(token: String, parentId: String? = nil) async throws -> PublicListing {
        try await send(PublicListing.self, "GET", "/public/s/\(token)/nodes", query: ["parentId": parentId], auth: false)
    }

    public func publicDownload(token: String, node: PublicNode) async throws -> URL {
        let req = try makeRequest("GET", "/public/s/\(token)/files/\(node.id)/content", auth: false)
        return try await downloadFile(req, id: node.id, name: node.name)
    }

    // MARK: - Resumable upload primitives (used by ResumableUpload)

    func createUpload(parentId: String?, name: String, size: Int64, mimeType: String?) async throws -> UploadSession {
        struct B: Encodable { let parentId: String?; let name: String; let size: Int64; let mimeType: String? }
        return try await send(UploadSession.self, "POST", "/uploads", body: B(parentId: parentId, name: name, size: size, mimeType: mimeType))
    }

    func uploadReceived(uploadId: String) async throws -> Int64 {
        struct R: Decodable { let received: Int64 }
        return try await send(R.self, "GET", "/uploads/\(uploadId)").received
    }

    func completeUpload(uploadId: String) async throws -> DriveNode {
        struct R: Decodable { let node: DriveNode }
        return try await send(R.self, "POST", "/uploads/\(uploadId)/complete").node
    }

    public func cancelUpload(uploadId: String) async { _ = try? await send(Empty.self, "DELETE", "/uploads/\(uploadId)") }

    enum ChunkResult { case ok(newOffset: Int64), mismatch(received: Int64) }

    func putChunk(uploadId: String, offset: Int64, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws -> ChunkResult {
        var req = try makeRequest("PUT", "/uploads/\(uploadId)")
        req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = ProgressDelegate(progress)
        let (body, response) = try await session.upload(for: req, from: data, delegate: delegate)

        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], obj["code"] as? String == "offset_mismatch" {
            return .mismatch(received: (obj["received"] as? NSNumber)?.int64Value ?? 0)
        }
        try check(response, body)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Upload-Offset")
        return .ok(newOffset: Int64(header ?? "") ?? offset + Int64(data.count))
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void
    init(_ onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}
