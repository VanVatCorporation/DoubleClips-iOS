import Foundation
import Combine

class AuthRepository: ObservableObject {
    static let shared = AuthRepository()
    
    @Published var currentUser: User?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    var isAuthenticated: Bool {
        return currentUser != nil
    }
    
    private let apiClient = APIClient.shared
    
    private init() {
        // Automatically check session on init? 
        // Better to let the App lifecycle call checkSession() explicitly.
    }
    
    // MARK: - Actions
    
    func login(email: String, password: String) {
        isLoading = true
        errorMessage = nil
        
        let request = LoginRequest(email: email, password: password)
        APIClient.shared.login(getRequest: request) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let user):
                    self?.currentUser = user
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func loginWithGoogle(idToken: String) {
        isLoading = true
        errorMessage = nil
        
        let request = GoogleLoginRequest(idToken: idToken)
        APIClient.shared.loginWithGoogle(getRequest: request) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let user):
                    self?.currentUser = user
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func register(username: String, email: String, password: String, firstName: String, lastName: String) {
        isLoading = true
        errorMessage = nil
        
        let request = RegisterRequest(username: username, email: email, password: password, firstName: firstName, lastName: lastName)
        APIClient.shared.register(getRequest: request) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let user):
                    self?.currentUser = user
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func logout() {
        isLoading = true
        APIClient.shared.logout { [weak self] _ in
            DispatchQueue.main.async {
                self?.isLoading = false
                self?.currentUser = nil
                self?.errorMessage = nil
            }
        }
    }
    
    func checkSession() {
        isLoading = true
        APIClient.shared.getProfile { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let user):
                    self?.currentUser = user
                case .failure(_):
                    self?.currentUser = nil
                    // Session invalid, silent fail (user stays logged out)
                }
            }
        }
    }
}
