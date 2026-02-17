import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authRepo: AuthRepository
    @Environment(\.dismiss) var dismiss
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var rememberMe: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Branding Card
                VStack(spacing: 16) {
                    // App Icon
                    Image(systemName: "film.circle.fill")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.mdPrimary)
                        .background(
                            Circle()
                                .fill(Color.mdPrimaryContainer)
                                .frame(width: 120, height: 120)
                        )
                    
                    // App Name
                    Text("DoubleClips")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.mdOnPrimaryContainer)
                    
                    // Tagline
                    Text("Sign in to continue")
                        .font(.system(size: 16))
                        .foregroundColor(.mdOnPrimaryContainer.opacity(0.8))
                }
                .frame(maxWidth: 500)
                .padding(.vertical, 32)
                .padding(.horizontal, 24)
                .background(Color.mdPrimaryContainer)
                .cornerRadius(16)
                .padding(.top, 40)
                
                // Login Form Card
                VStack(alignment: .leading, spacing: 20) {
                    // Header with Register Link
                    HStack {
                        Text("Sign In")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        NavigationLink(destination: Text("Register Screen Placeholder")) {
                            Text("Register")
                                .font(.system(size: 16))
                                .foregroundColor(.mdPrimary)
                        }
                    }
                    
                    // Email Input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 24)
                            
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
                                .frame(width: 24)
                            
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }
                        .padding(16)
                        .background(Color.mdSurfaceContainerHigh)
                        .cornerRadius(12)
                    }
                    
                    // Remember Me
                    Toggle(isOn: $rememberMe) {
                        Text("Remember me")
                            .font(.system(size: 14))
                    }
                    
                    // Error Message
                    if let error = authRepo.errorMessage {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding(.vertical, 8)
                    }
                    
                    // Login Button
                    Button(action: {
                        authRepo.login(email: email, password: password)
                    }) {
                        if authRepo.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        } else {
                            Text("Sign In")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                    }
                    .background(Color.mdPrimary)
                    .cornerRadius(12)
                    .disabled(authRepo.isLoading || email.isEmpty || password.isEmpty)
                    .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                }
                .padding(24)
                .frame(maxWidth: 500)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.mdBackground.edgesIgnoringSafeArea(.all))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: authRepo.currentUser) { newUser in
            if newUser != nil {
                // Dismiss on successful login
                dismiss()
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoginView()
            .environmentObject(AuthRepository.shared)
    }
}
