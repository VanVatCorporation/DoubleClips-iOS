# iOS Authentication Integration Guide

## Overview
This library provides JWT-based authentication for iOS using the DoubleClips authentication backend. It manages user sessions via HTTP cookies and provides automatic persistence.

## Architecture
- **`AuthModels.swift`**: Data models (`User`, `LoginRequest`, `RegisterRequest`, etc.)
- **`APIClient.swift`**: Network layer using `URLSession` with automatic cookie management
- **`AuthRepository.swift`**: Observable singleton managing authentication state

## Installation
Copy all files from this directory into your Xcode project.

No external dependencies required - uses native Swift Foundation and Combine frameworks.

## Usage

### 1. Initialize in Your App
The `AuthRepository` is a singleton that uses `@Published` properties for SwiftUI reactivity.

```swift
import SwiftUI

@main
struct YourApp: App {
    @StateObject private var authRepo = AuthRepository.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authRepo)
                .onAppear {
                    // Check if user is already logged in via persistent cookie
                    authRepo.checkSession()
                }
        }
    }
}
```

### 2. Login
```swift
AuthRepository.shared.login(email: "user@example.com", password: "password")

// Observe state changes
@EnvironmentObject var authRepo: AuthRepository

if let user = authRepo.currentUser {
    Text("Welcome, \(user.username)!")
}
```

### 3. Register
```swift
AuthRepository.shared.register(
    username: "newuser",
    email: "user@example.com",
    password: "password",
    firstName: "John",
    lastName: "Doe"
)
```

### 4. Google Login
```swift
// After obtaining ID token from Google Sign-In SDK
AuthRepository.shared.loginWithGoogle(idToken: googleIdToken)
```

> **Note**: You'll need to integrate the Google Sign-In iOS SDK separately and obtain the ID token.

### 5. Logout
```swift
AuthRepository.shared.logout()
```

### 6. Check Session (Auto Login)
Automatically called on app launch to restore user session from persistent cookies:
```swift
AuthRepository.shared.checkSession()
```

## Observing State in SwiftUI
```swift
struct ProfileView: View {
    @EnvironmentObject var authRepo: AuthRepository
    
    var body: some View {
        if authRepo.isLoading {
            ProgressView()
        } else if let user = authRepo.currentUser {
            Text("Logged in as: \(user.username)")
        } else {
            Button("Sign In") {
                authRepo.login(email: "...", password: "...")
            }
        }
    }
}
```

## Cookie Persistence
Sessions are automatically persisted via `HTTPCookieStorage.shared`. The cookies will survive app restarts unless explicitly cleared via logout.

## API Endpoints
Base URL: `https://account.vanvatcorp.com`

- `POST /api/login` - Email/password login
- `POST /api/login/google` - Google SSO login
- `POST /api/register` - Create new account
- `GET /api/profile` - Get current user (session check)
- `POST /api/logout` - End session

## Error Handling
Errors are published via `AuthRepository.errorMessage`:
```swift
if let error = authRepo.errorMessage {
    Text("Error: \(error)")
        .foregroundColor(.red)
}
```
