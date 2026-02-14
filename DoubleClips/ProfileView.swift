import SwiftUI

struct ProfileView: View {
    @State private var isLoggedIn: Bool = false // Mock state - toggle to test
    @State private var isLoading: Bool = false
    
    var body: some View {
        ZStack {
            Color.mdBackground.edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 24) {
                    // 1. Profile Header or Sign In Prompt
                    if isLoggedIn {
                        // Logged In: Avatar & Name
                        VStack(spacing: 16) {
                            // Avatar
                            Image(systemName: "person.crop.circle.fill") // Placeholder
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .foregroundColor(.mdSecondaryContainer)
                                .background(Color.mdSurfaceContainerHigh)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.mdOutline, lineWidth: 1))
                                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                            
                            // Name
                            Text("Van Vat Employee")
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
                            
                            Button(action: {
                                isLoggedIn = true
                            }) {
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
                            if isLoggedIn {
                                SettingsRow(icon: "chart.bar.fill", title: "Statistics", height: 50)
                                Divider().padding(.leading, 56)
                                SettingsRow(icon: "heart.fill", title: "Saved Templates", height: 50)
                                Divider().padding(.leading, 56)
                                
                                // Log Out
                                Button(action: {
                                    isLoggedIn = false
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
                                // If logged out, maybe show "About" or similar, or just empty?
                                // Android structure shows these options but likely requires login to access.
                                // For visual parity with xml (it handles visibility dynamically), let's show items but protected.
                                // But keeping it simple: Android hides Log Out.
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
                // mock reload
            }
            
            if isLoading {
                ProgressView().scaleEffect(1.5)
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
