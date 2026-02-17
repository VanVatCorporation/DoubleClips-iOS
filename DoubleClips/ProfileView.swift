import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authRepo: AuthRepository
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.mdBackground.edgesIgnoringSafeArea(.all)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 1. Profile Header or Sign In Prompt
                        if let user = authRepo.currentUser {
                            // Logged In: Avatar & Name
                            VStack(spacing: 16) {
                                // Avatar
                                AsyncImage(url: URL(string: "https://account.vanvatcorp.com" + (user.avatarUrl ?? ""))) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .foregroundColor(.mdSecondaryContainer)
                                }
                                .frame(width: 120, height: 120)
                                .background(Color.mdSurfaceContainerHigh)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.mdOutline, lineWidth: 1))
                                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                                
                                // Name
                                Text(user.username)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                            .padding(.top, 40)
                        } else {
                            // Logged Out: Sign In Prompt
                            VStack(spacing: 16) {
                                Text("Sign in to sync your projects and access templates.")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                
                                NavigationLink(destination: LoginView().environmentObject(authRepo)) {
                                    Text("Sign In")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 32)
                                        .padding(.vertical, 12)
                                        .background(Color.mdPrimary)
                                        .cornerRadius(24)
                                }
                            }
                            .padding(.top, 60)
                            .padding(.bottom, 20)
                        }
                        
                        // 2. Settings Group: General
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GENERAL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 16)
                            
                            // Liquid Glass Card
                            VStack(spacing: 0) {
                                SettingsRow(icon: "gearshape.fill", title: "Settings", height: 50)
                            }
                            .background(.ultraThinMaterial)
                            .cornerRadius(16)
                        }
                        .padding(.horizontal, 16)
                        
                        // 3. Settings Group: Account
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ACCOUNT")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 16)
                            
                            // Liquid Glass Card
                            VStack(spacing: 0) {
                                if authRepo.currentUser != nil {
                                    SettingsRow(icon: "chart.bar.fill", title: "Statistics", height: 50)
                                    Divider().padding(.leading, 56)
                                    SettingsRow(icon: "heart.fill", title: "Saved Templates", height: 50)
                                    Divider().padding(.leading, 56)
                                    
                                    // Log Out
                                    Button(action: {
                                        authRepo.logout()
                                    }) {
                                        HStack(spacing: 16) {
                                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                                .font(.system(size: 20))
                                                .foregroundColor(.red)
                                                .frame(width: 24)
                                            
                                            Text("Log Out")
                                                .font(.system(size: 16))
                                                .foregroundColor(.red)
                                            
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .frame(height: 50)
                                    }
                                } else {
                                    SettingsRow(icon: "info.circle.fill", title: "About App", height: 50)
                                }
                            }
                            .background(.ultraThinMaterial)
                            .cornerRadius(16)
                        }
                        .padding(.horizontal, 16)
                        
                        Spacer(minLength: 50)
                    }
                }
                .refreshable {
                    authRepo.checkSession()
                }
                
                if authRepo.isLoading {
                    ProgressView().scaleEffect(1.5)
                }
            }
            .onAppear {
                // Check session on appear
                if authRepo.currentUser == nil {
                    authRepo.checkSession()
                }
            }
        }
    }
}

// Helper Row
struct SettingsRow: View {
    var icon: String
    var title: String
    var height: CGFloat
    
    var body: some View {
        Button(action: {}) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
                    .frame(width: 24)
                
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: height)
        }
    }
}

#Preview {
    ProfileView()
}
