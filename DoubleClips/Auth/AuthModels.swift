import Foundation

// MARK: - Models

struct User: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let email: String
    let firstName: String?
    let lastName: String?
    let bio: String?
    let avatarUrl: String?
    let reputation: Int
    
    // Add CodingKeys if JSON keys differ (e.g. snake_case vs camelCase)
    // Based on Java model, they seem to match, but verified against typical JSON API standards.
}

// MARK: - Requests

struct LoginRequest: Codable {
    let email: String
    let password: String
}

struct GoogleLoginRequest: Codable {
    let idToken: String
}

struct RegisterRequest: Codable {
    let username: String
    let email: String
    let password: String
    let firstName: String
    let lastName: String
}

// MARK: - Responses

struct ApiResponse<T: Codable>: Codable {
    let success: Bool
    let message: String?
    let error: String?
    let user: T? 
    // Note: The Java ApiResponse has a generic 'T user' field. 
    // In Swift, we might want to make this 'data' or 'user' depending on actual API response.
    // However, looking at the Java code, it specifically uses `private T user;`.
}

struct EmptyResponse: Codable {}
