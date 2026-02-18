import Foundation

struct ApiResponse<T: Codable>: Codable {
    let success: Bool
    let message: String?
    let error: String?
    let user: T?
}
