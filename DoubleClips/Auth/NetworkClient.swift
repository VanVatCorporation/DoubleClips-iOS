import Foundation

class NetworkClient {
    static let shared = NetworkClient()
    private let baseURL = "https://account.vanvatcorp.com"
    
    // Cookie Storage using UserDefaults
    private let cookieStorage = HTTPCookieStorage.shared
    
    private init() {
        // Configure URLSession to accept and store cookies
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = cookieStorage
        
        session = URLSession(configuration: config)
        
        // Load persisted cookies
        loadCookies()
    }
    
    private var session: URLSession
    
    // MARK: - Cookie Persistence
    
    private let cookiesKey = "auth_cookies"
    
    private func saveCookies() {
        guard let cookies = cookieStorage.cookies else { return }
        
        let cookieData = cookies.compactMap { cookie -> [String: Any]? in
            var dict: [String: Any] = [:]
            dict["name"] = cookie.name
            dict["value"] = cookie.value
            dict["domain"] = cookie.domain
            dict["path"] = cookie.path
            dict["expiresDate"] = cookie.expiresDate?.timeIntervalSince1970
            dict["isSecure"] = cookie.isSecure
            dict["isHTTPOnly"] = cookie.isHTTPOnly
            return dict
        }
        
        UserDefaults.standard.set(cookieData, forKey: cookiesKey)
        UserDefaults.standard.synchronize()
    }
    
    private func loadCookies() {
        guard let cookieData = UserDefaults.standard.array(forKey: cookiesKey) as? [[String: Any]] else {
            return
        }
        
        for dict in cookieData {
            guard let name = dict["name"] as? String,
                  let value = dict["value"] as? String,
                  let domain = dict["domain"] as? String,
                  let path = dict["path"] as? String else {
                continue
            }
            
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path
            ]
            
            if let expiresTimestamp = dict["expiresDate"] as? TimeInterval {
                properties[.expires] = Date(timeIntervalSince1970: expiresTimestamp)
            }
            
            if let isSecure = dict["isSecure"] as? Bool, isSecure {
                properties[.secure] = "TRUE"
            }
            
            if let isHTTPOnly = dict["isHTTPOnly"] as? Bool, isHTTPOnly {
                properties[.init("HttpOnly")] = "TRUE"
            }
            
            if let cookie = HTTPCookie(properties: properties) {
                cookieStorage.setCookie(cookie)
            }
        }
    }
    
    func clearCookies() {
        if let cookies = cookieStorage.cookies {
            for cookie in cookies {
                cookieStorage.deleteCookie(cookie)
            }
        }
        UserDefaults.standard.removeObject(forKey: cookiesKey)
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Network Requests
    
    func request<T: Codable, R: Codable>(
        endpoint: String,
        method: String = "GET",
        body: T? = nil,
        completion: @escaping (Result<ApiResponse<R>, Error>) -> Void
    ) {
        guard let url = URL(string: baseURL + endpoint) else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Encode body if provided
        if let body = body {
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                completion(.failure(error))
                return
            }
        }
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No data", code: -1)))
                }
                return
            }
            
            // Save cookies after response
            self?.saveCookies()
            
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(ApiResponse<R>.self, from: data)
                DispatchQueue.main.async {
                    completion(.success(response))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
        task.resume()
    }
    
    
    struct EmptyBody: Codable {}
    // Convenience method for requests without body
    func get<R: Codable>(
        endpoint: String,
        completion: @escaping (Result<ApiResponse<R>, Error>) -> Void
    ) {
        request(endpoint: endpoint, method: "GET", body: nil as EmptyBody?, completion: completion)
    }
}
