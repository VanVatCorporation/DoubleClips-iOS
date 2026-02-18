import Foundation
import Combine

class AuthRepository: ObservableObject {
    static let shared = AuthRepository()
    
    // Published property for reactive UI updates (equivalent to LiveData)
    @Published private(set) var currentUser: User?
    
    private let networkClient = NetworkClient.shared
    
    private init() {
        // Private initializer for singleton
    }
    
    // MARK: - Authentication Methods
    
    func login(email: String, password: String, completion: @escaping (Result<User, Error>) -> Void) {
        let request = LoginRequest(email: email, password: password)
        
        networkClient.request(endpoint: "/api/login", method: "POST", body: request) { [weak self] (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    self?.cacheUser(user)
                    completion(.success(user))
                } else {
                    let error = NSError(
                        domain: "Auth",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: response.error ?? "Login failed"]
                    )
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func loginWithGoogle(idToken: String, completion: @escaping (Result<User, Error>) -> Void) {
        let request = GoogleLoginRequest(idToken: idToken)
        
        networkClient.request(endpoint: "/api/login/google", method: "POST", body: request) { [weak self] (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    self?.cacheUser(user)
                    completion(.success(user))
                } else {
                    let error = NSError(
                        domain: "Auth",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: response.error ?? "Google login failed"]
                    )
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func register(
        username: String,
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        completion: @escaping (Result<User, Error>) -> Void
    ) {
        let request = RegisterRequest(
            username: username,
            email: email,
            password: password,
            firstName: firstName,
            lastName: lastName
        )
        
        networkClient.request(endpoint: "/api/register", method: "POST", body: request) { [weak self] (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    self?.cacheUser(user)
                    completion(.success(user))
                } else {
                    let error = NSError(
                        domain: "Auth",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: response.error ?? "Registration failed"]
                    )
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func checkSession(completion: @escaping (Result<User, Error>) -> Void) {
        networkClient.get(endpoint: "/api/profile") { [weak self] (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if let user = response.user {
                    self?.cacheUser(user)
                    completion(.success(user))
                } else {
                    self?.clearUser()
                    let error = NSError(
                        domain: "Auth",
                        code: 401,
                        userInfo: [NSLocalizedDescriptionKey: "Not logged in"]
                    )
                    completion(.failure(error))
                }
            case .failure(let error):
                self?.clearUser()
                completion(.failure(error))
            }
        }
    }
    
    func logout(completion: @escaping (Result<Void, Error>) -> Void) {
        struct EmptyBody: Codable {}
        
        networkClient.request(endpoint: "/api/logout", method: "POST", body: nil as EmptyBody?) { [weak self] (result: Result<ApiResponse<User>, Error>) in
            // Clear session regardless of network result (for UX)
            self?.clearUser()
            self?.clearLocalSession()
            
            switch result {
            case .success:
                completion(.success(()))
            case .failure:
                // Still treat as success from UI perspective
                completion(.success(()))
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func cacheUser(_ user: User) {
        self.currentUser = user
    }
    
    private func clearUser() {
        self.currentUser = nil
    }
    
    private func clearLocalSession() {
        networkClient.clearCookies()
    }
}
