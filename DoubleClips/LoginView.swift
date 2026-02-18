import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var authRepo = AuthRepository.shared
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var rememberMe: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)
                
                // MARK: - Branding Card
                VStack(spacing: 16) {
                    // App Icon
                    Circle()
                        .fill(Color.mdPrimary)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Image(systemName: "video.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white)
                        )
                    
                    // App Name
                    Text("DoubleClips")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.mdOnPrimaryContainer)
                    
                    // Tagline
                    Text("Sign in to your account")
                        .font(.system(size: 16))
                        .foregroundColor(.mdOnPrimaryContainer.opacity(0.8))
                }
                .frame(maxWidth: 500)
                .padding(.vertical, 32)
                .padding(.horizontal, 24)
                .background(Color.mdPrimaryContainer)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                .padding(.horizontal, 16)
                
                // MARK: - Login Form Card
                VStack(alignment: .leading, spacing: 20) {
                    // Header with Register Button
                    HStack {
                        Text("Sign In")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button("Register") {
                            // TODO: Navigate to Register screen
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.mdPrimary)
                    }
                    
                    // Email Input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            
                            TextField("Email or Username", text: $email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                        }
                        .padding(16)
                        .background(Color.mdSurfaceContainerHigh)
                        .cornerRadius(12)
                    }
                    
                    // Password Input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                        .padding(16)
                        .background(Color.mdSurfaceContainerHigh)
                        .cornerRadius(12)
                    }
                    
                    // Remember Me Checkbox
                    Toggle(isOn: $rememberMe) {
                        Text("Remember me")
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                    }
                    .toggleStyle(CheckboxToggleStyle())
                    
                    // Error Message
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding(.vertical, 8)
                    }
                    
                    // Login Button
                    Button(action: performLogin) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Text("Sign In")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.mdPrimary)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                    .opacity((isLoading || email.isEmpty || password.isEmpty) ? 0.6 : 1.0)
                }
                .frame(maxWidth: 500)
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                .padding(.horizontal, 16)
                
                Spacer(minLength: 40)
            }
        }
        .background(Color.mdBackground.edgesIgnoringSafeArea(.all))
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkExistingSession()
        }
    }
    
    // MARK: - Helper Methods
    
    private func checkExistingSession() {
        authRepo.checkSession { result in
            switch result {
            case .success(let user):
                // Already logged in, dismiss
                dismiss()
            case .failure:
                // Not logged in, stay on login screen
                break
            }
        }
    }
    
    private func performLogin() {
        errorMessage = nil
        isLoading = true
        
        authRepo.login(email: email, password: password) { result in
            isLoading = false
            
            switch result {
            case .success(let user):
                // Success! Dismiss login screen
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

// Custom Checkbox Toggle Style
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .mdPrimary : .secondary)
                .font(.system(size: 22))
                .onTapGesture {
                    configuration.isOn.toggle()
                }
            
            configuration.label
        }
    }
}

#Preview {
    NavigationStack {
        LoginView()
    }
}
