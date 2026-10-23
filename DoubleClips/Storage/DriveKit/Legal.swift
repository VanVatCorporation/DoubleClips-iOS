import Foundation

// Terms of Service / Privacy Policy: documents + acceptance (backend-v2, Subdomain/LegalApp.cs).
// The server parses the Markdown into blocks of styled runs, so the apps only have to draw them.

/// One styled run of text (only the flags that are on are present).
public struct LegalSpan: Codable, Sendable, Equatable {
    public let t: String
    public let b: Bool?
    public let i: Bool?
    public let c: Bool?
    public let href: String?
}

/// h = heading (level), p = paragraph, li = list item (depth, ordered, number), quote, rule.
public struct LegalBlock: Codable, Sendable, Equatable {
    public let type: String
    public let spans: [LegalSpan]
    public let level: Int?
    public let depth: Int?
    public let ordered: Bool?
    public let number: Int?
}

public struct LegalDocument: Codable, Sendable, Equatable {
    public let key: String
    public let slug: String
    public let version: String
    /// yyyy-MM-dd
    public let lastUpdated: String
    /// The language actually served (it falls back when the requested one has no translation).
    public let lang: String
    public let fallback: Bool
    public let title: String
    public let languages: [String]
    public let blocks: [LegalBlock]
}

public struct LegalStatusDoc: Codable, Sendable, Equatable {
    public let key: String
    public let slug: String
    public let version: String
    public let lastUpdated: String
    public let title: String
    public let accepted: Bool
}

/// What the signed-in user still has to accept for this product (also inside GET /me as `legal`).
public struct LegalStatus: Codable, Sendable, Equatable {
    public let product: String
    public let required: Bool
    /// The document shown in full inside the popup (the product's own terms).
    public let inline: String
    public let documents: [LegalStatusDoc]
}

extension DriveClient {
    /// Public. The language falls back: lang -> Accept-Language -> English.
    public func legalDocument(key: String, lang: String?) async throws -> LegalDocument {
        struct R: Decodable { let document: LegalDocument }
        let req = try makeRequest("GET", "/documents/\(key)", query: ["lang": lang], auth: false, prefix: "api/v2/legal")
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return try JSONDecoder.drive.decode(R.self, from: data).document
    }

    /// Records that the user accepted exactly the versions they were shown. 409 `version_changed` = new terms were published meanwhile.
    public func acceptLegal(versions: [String: String], lang: String) async throws -> LegalStatus {
        struct B: Encodable { let versions: [String: String]; let lang: String }
        struct R: Decodable { let status: LegalStatus }
        var req = try makeRequest("POST", "/accept", body: B(versions: versions, lang: lang), prefix: "api/v2/legal")
        req.setValue("ios", forHTTPHeaderField: "X-Client")
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return try JSONDecoder.drive.decode(R.self, from: data).status
    }

    /// Where the full pages live (the web app): /terms and /privacy, in the given language.
    public func legalPageURL(slug: String, lang: String?) -> URL {
        var c = URLComponents(url: endpoints.drive.appendingPathComponent(slug), resolvingAgainstBaseURL: false)!
        if let lang { c.queryItems = [URLQueryItem(name: "lang", value: lang)] }
        return c.url ?? endpoints.drive
    }
}
