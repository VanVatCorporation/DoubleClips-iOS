// Embedded copy of VanVatDriveKit (Sources/VanVatDriveKit/Models.swift) so DoubleClips needs no package setup.
// Keep in sync with the package; replace with the package dependency later if you prefer.
import Foundation

public enum DriveRole: String, Codable, Sendable, Comparable, CaseIterable {
    case viewer, editor, manager, owner

    private var rank: Int {
        switch self {
        case .viewer: return 1
        case .editor: return 2
        case .manager: return 3
        case .owner: return 4
        }
    }
    public static func < (a: DriveRole, b: DriveRole) -> Bool { a.rank < b.rank }

    public var canEdit: Bool { self >= .editor }
    public var canManage: Bool { self >= .manager }
    /// Roles that can be handed to another account.
    public static let grantable: [DriveRole] = [.viewer, .editor, .manager]
}

public struct DriveNode: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let parentId: String?
    public let ownerId: String
    public let createdBy: String
    public var name: String
    public let isFolder: Bool
    public let size: Int64
    public let mimeType: String?
    public let sha256: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    /// "openeditz" for the protected OpenEditz folder.
    public let systemKey: String?
    public let myRole: DriveRole

    public var isSystemFolder: Bool { systemKey != nil }
}

public struct PathItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct Me: Codable, Sendable, Equatable {
    public let userId: String
    public let username: String?
    public let email: String?
    public let quotaBytes: Int64
    public let usedBytes: Int64
    public let chunkSize: Int
    /// Largest single file the plan allows (nil from older servers).
    public let maxFileBytes: Int64?
    /// The account tier (free, personal, pro...). Tiers are bought in the Account Center.
    public let plan: Plan?
    /// Today's transfer counters and the account-wide compute quota.
    public let usage: Usage?
    /// Per-account Drive preferences (nil from older servers).
    public let settings: Settings?
    /// Terms of Service / Privacy Policy: what this user still has to accept (a blocking popup when `required`).
    public let legal: LegalStatus?

    public struct Settings: Codable, Sendable, Equatable {
        /// nil = default (on).
        public let previewThumbnails: Bool?
    }

    /// Image thumbnails in the lists: on unless the account turned them off.
    public var previewThumbnails: Bool { settings?.previewThumbnails ?? true }

    public struct Plan: Codable, Sendable, Equatable {
        public let key: String
        public let name: String
        public let expiresAt: Date?
    }

    public struct Usage: Codable, Sendable, Equatable {
        public let uploadedBytes: Int64
        public let downloadedBytes: Int64
        public let uploadLimit: Int64
        public let downloadLimit: Int64
        public let resetsAt: Date
        /// Credits, shared with every Van Vat service.
        public let computeUsed: Double?
        public let computeLimit: Double?

        public var uploadFree: Int64 { max(0, uploadLimit - uploadedBytes) }
        public var downloadFree: Int64 { max(0, downloadLimit - downloadedBytes) }
    }
}

public struct Listing: Decodable, Sendable {
    public let role: DriveRole
    public let path: [PathItem]
    public let items: [DriveNode]
    public let hasMore: Bool
}

public struct SharedItem: Decodable, Sendable, Identifiable {
    public let node: DriveNode
    public let permissionId: String
    public let sharedBy: String?
    public var id: String { node.id }
}

public struct Person: Decodable, Sendable, Identifiable {
    public let permissionId: String
    public let granteeId: String
    public let role: DriveRole
    public let username: String?
    public let email: String?
    public var id: String { permissionId }
}

public struct LinkInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let nodeId: String
    public let token: String
    public let url: String
    public let rawServing: Bool
    public let expiresAt: Date?
    public let createdAt: Date
    public let downloadCount: Int64
}

public struct AccessInfo: Decodable, Sendable {
    public struct Owner: Decodable, Sendable { public let id: String; public let username: String? }
    public let myRole: DriveRole
    public let owner: Owner
    public let people: [Person]
    public let links: [LinkInfo]
}

public struct PublicNode: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let mimeType: String?
    public let updatedAt: Date
}

public struct PublicMeta: Decodable, Sendable {
    public let rawServing: Bool
    public let node: PublicNode
}

public struct PublicListing: Decodable, Sendable {
    public struct Root: Decodable, Sendable { public let id: String; public let name: String }
    public let root: Root
    public let parentId: String
    public let items: [PublicNode]
}

public struct UploadSession: Decodable, Sendable {
    public let uploadId: String
    public let chunkSize: Int
    public let received: Int64
}

// MARK: - Dates (.NET writes up to 7 fractional digits)

enum DriveDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        var s = raw
        // DateTimes read from the database (plan expiry...) can come without a zone marker: they are UTC.
        if s.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil { s += "Z" }
        if let r = s.range(of: #"(\.\d{3})\d+"#, options: .regularExpression) {
            s.replaceSubrange(r, with: String(s[r].prefix(4)))
        }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

extension JSONDecoder {
    static let drive: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = DriveDates.parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(raw)"))
            }
            return date
        }
        return d
    }()
}

// MARK: - Errors

public struct DriveError: LocalizedError, Sendable {
    public let status: Int
    public let code: String?
    public let message: String
    public init(status: Int, code: String? = nil, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
    public var isUnauthorized: Bool { status == 401 }

    /// New terms were published and the user has not accepted them yet.
    public var isTosRequired: Bool { code == "tos_required" }

    /// The server refused because of a quota or plan limit (storage, file size, daily transfer, compute):
    /// the useful next step is "Get more resources" (the account tier upgrade).
    public var isQuotaLimit: Bool {
        guard let code else { return false }
        return ["quota_exceeded", "file_too_large", "daily_upload_limit", "daily_download_limit", "daily_compute_limit"].contains(code)
    }
}
