import Foundation

class APIClient {
    static let shared = APIClient()
    private let baseURL = "https://account.vanvatcorp.com"
    
    // Cookie Storage: URLSession.shared uses HTTPCookieStorage.shared automatically.
    // Cookies set by the server (Set-Cookie) will be stored and sent with subsequent requests.
    // Ensure "App Sandbox" -> "Network: Outgoing Connections (Client)" is checked in Xcode capabilities.
    private let session = URLSession.shared
    
    // MARK: - Generic Request
    
    private func request<T: Codable>(endpoint: String, method: String, body: Codable?, completion: @escaping (Result<ApiResponse<T>, Error>) -> Void) {
        guard let url = URL(string: baseURL + endpoint) else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Serialize Body
        if let body = body {
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                completion(.failure(error))
                return
            }
        }
        
        // Execute Request
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid Response", code: -1, userInfo: nil)))
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode), let data = data else {
                // Try decoding error json if available
                if let data = data {
                     do {
                        let apiError = try JSONDecoder().decode(ApiResponse<T>.self, from: data)
                         completion(.success(apiError)) // Return structured error if possible
                    } catch {
                        completion(.failure(NSError(domain: "Server Error: \(httpResponse.statusCode)", code: httpResponse.statusCode, userInfo: nil)))
                    }
                } else {
                    completion(.failure(NSError(domain: "Server Error", code: httpResponse.statusCode, userInfo: nil)))
                }
                return
            }
            
            // Decode Response
            do {
                let decodedResponse = try JSONDecoder().decode(ApiResponse<T>.self, from: data)
                completion(.success(decodedResponse))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Auth Endpoints
    
    func login(getRequest: LoginRequest, completion: @escaping (Result<User, Error>) -> Void) {
        request(endpoint: "/api/login", method: "POST", body: getRequest) { (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    completion(.success(user))
                } else {
                    completion(.failure(NSError(domain: response.error ?? response.message ?? "Login failed", code: 400)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func loginWithGoogle(getRequest: GoogleLoginRequest, completion: @escaping (Result<User, Error>) -> Void) {
        request(endpoint: "/api/login/google", method: "POST", body: getRequest) { (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    completion(.success(user))
                } else {
                    completion(.failure(NSError(domain: response.error ?? response.message ?? "Google Login failed", code: 400)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func register(getRequest: RegisterRequest, completion: @escaping (Result<User, Error>) -> Void) {
        request(endpoint: "/api/register", method: "POST", body: getRequest) { (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    completion(.success(user))
                } else {
                    completion(.failure(NSError(domain: response.error ?? response.message ?? "Registration failed", code: 400)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // Check Session (Get Profile purely via Cookie)
    func getProfile(completion: @escaping (Result<User, Error>) -> Void) {
        // Empty body for GET requests usually, but request helper handles nil body.
        request(endpoint: "/api/profile", method: "GET", body: nil as LoginRequest?) { (result: Result<ApiResponse<User>, Error>) in
            switch result {
            case .success(let response):
                if response.success, let user = response.user {
                    completion(.success(user))
                } else {
                    completion(.failure(NSError(domain: "Session Invalid", code: 401)))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
        
    func logout(completion: @escaping (Result<Void, Error>) -> Void) {
        // ApiResponse<Void> is tricky because T must be Codable and Void isn't.
        // We can use a dummy struct or specific handling. 
        // For simplicity, let's use ApiResponse<EmptyResponse> or just String.
        
        request(endpoint: "/api/logout", method: "POST", body: nil as LoginRequest?) { (result: Result<ApiResponse<EmptyResponse>, Error>) in
             switch result {
            case .success(_):
                // Clear cookies locally as well
                self.clearCookies()
                completion(.success(()))
            case .failure(let error):
                // Still clear cookies locally
                self.clearCookies()
                completion(.failure(error))
            }
        }
    }
    
    // Cookie Management
    func clearCookies() {
        let storage = HTTPCookieStorage.shared
        if let cookies = storage.cookies {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
    }
}
