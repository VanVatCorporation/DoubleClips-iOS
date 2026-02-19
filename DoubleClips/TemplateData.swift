import Foundation

struct TemplateData: Identifiable, Codable, Hashable {
    var id: String { templateId } // Mapped from templateId
    var templateAuthor: String
    var templateId: String
    var templateTitle: String
    var templateDescription: String
    var ffmpegCommand: String
    var templateSnapshotLink: String
    var templateVideoLink: String
    var templateTimestamp: Int64
    var templateDuration: Int64
    var templateTotalClip: Int
    var additionalResourceName: [String]?
    var viewCount: Int
    var useCount: Int
    var heartCount: Int
    // var comments: [TemplateComment] // Deferred for now as per "handle later" instruction
    var bookmarkCount: Int
    
    // User Interaction State
    var isLiked: Bool?
    var isBookmarked: Bool?
}
