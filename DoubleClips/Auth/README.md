# iOS Authentication Library

This folder contains the iOS authentication library, ported from the Android `dynamiclibs/auth` implementation.

## Architecture

The library follows the same architecture as the Android version:

### Core Components

1. **Models**
   - `User.swift`: User data model
   - `ApiResponse.swift`: Generic API response wrapper
   - `AuthRequests.swift`: Request DTOs (LoginRequest, RegisterRequest, GoogleLoginRequest)

2. **Network Layer**
   - `NetworkClient.swift`: URLSession-based HTTP client with persistent cookie storage
     - Equivalent to Android's `RetrofitClient`
     - Uses `HTTPCookieStorage` and `UserDefaults` for cookie persistence
     - Handles JSON encoding/decoding with `Codable`

3. **Repository**
   - `AuthRepository.swift`: Singleton repository managing authentication state
     - Uses `@Published` property for reactive UI updates (equivalent to Android's LiveData)
     - Provides methods: `login()`, `loginWithGoogle()`, `register()`, `checkSession()`, `logout()`
     - Manages in-memory user cache

## Usage

### Login
```swift
AuthRepository.shared.login(email: "user@example.com", password: "password") { result in
    switch result {
    case .success(let user):
        print("Logged in as \(user.username ?? "")")
    case .failure(let error):
        print("Login failed: \(error.localizedDescription)")
    }
}
```

### Check Session (Auto-login)
```swift
AuthRepository.shared.checkSession { result in
    switch result {
    case .success(let user):
        print("Session valid, user: \(user.username ?? "")")
    case .failure:
        print("No active session")
    }
}
```

### Logout
```swift
AuthRepository.shared.logout { result in
    print("Logged out")
}
```

### Reactive UI Updates (SwiftUI)
```swift
struct ContentView: View {
    @ObservedObject var authRepo = AuthRepository.shared
    
    var body: some View {
        if let user = authRepo.currentUser {
            Text("Welcome, \(user.username ?? "User")")
        } else {
            Text("Please sign in")
        }
    }
}
```

## Backend Endpoints

The library connects to: `https://account.vanvatcorp.com`

- `POST /api/login` - Email/password login
- `POST /api/login/google` - Google OAuth login
- `POST /api/register` - User registration
- `GET /api/profile` - Get current user profile
- `POST /api/logout` - Logout

## Cookie Management

Cookies are automatically:
- Stored in `HTTPCookieStorage.shared`
- Persisted to `UserDefaults` across app launches
- Sent with all requests to the auth domain
- Cleared on logout

## Dependencies

- Foundation
- Combine (for `@Published` reactive properties)
