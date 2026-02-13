import SwiftUI

struct ProfileView: View {
    @State private var isLoggedIn: Bool = false // Mock state
    @State private var isLoading: Bool = false
    
    var body: some View {
        ZStack {
            Color.mdBackground.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header Frame
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color.mdPrimaryContainer)
                        .frame(height: 180)
                        
                        // Rounded bottom corners for header
                        .clipShape(RoundedCorner(radius: Dimens.cornerBase, corners: [.bottomLeft, .bottomRight]))
                        .shadow(radius: 2)
                    
                    // Profile Header Content
                    HStack(alignment: .top, spacing: Dimens.spacingBase) {
                        // Avatar
                        Circle() // Avatar placeholder
                            .fill(Color.mdSecondaryContainer)
                            .frame(width: Dimens.avatarSizeXxl, height: Dimens.avatarSizeXxl)
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: 4) // Optional border
                            )
                            .shadow(radius: 4)
                        
                        // Name
                        if isLoggedIn {
                            Text("Van Vat Employee")
                                .font(.mdHeadlineSmall)
                                .foregroundColor(.mdOnPrimaryContainer)
                                .padding(.top, Dimens.spacingMd)
                        }
                    }
                    .padding(Dimens.spacingLg)
                    
                    // Sign In Overlay
                    if !isLoggedIn {
                        ZStack {
                            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                                .fill(Color.mdSurface.opacity(0.9)) // Slightly translucent
                                .shadow(radius: 1)
                            
                            VStack(spacing: Dimens.spacingBase) {
                                Image(systemName: "person.fill")
                                    .resizable()
                                    .frame(width: Dimens.iconSizeXl, height: Dimens.iconSizeXl)
                                    .foregroundColor(.mdOnSurface.opacity(0.6))
                                
                                Button(action: {
                                    // Trigger Sign In
                                    isLoggedIn = true // Mock action
                                }) {
                                    Text("Sign In")
                                        .font(.mdLabelSmall) // Or button font
                                        .padding(.horizontal, Dimens.spacingLg)
                                        .padding(.vertical, Dimens.spacingSm)
                                        .background(Color.mdPrimary)
                                        .foregroundColor(.mdOnPrimary)
                                        .cornerRadius(Dimens.cornerFull)
                                }
                            }
                        }
                        .padding(Dimens.spacingLg)
                    }
                }
                .frame(height: 220) // Give space for the avatar to overhang or fit
                .zIndex(1) // Ensure header is above content
                
                // Settings List
                ScrollView {
                    VStack(spacing: Dimens.spacingBase) {
                        
                        // General Settings
                        SectionView(title: "General") {
                            SettingsButton(title: "Settings", icon: "gearshape.fill")
                        }
                        
                        // Account Settings
                        SectionView(title: "Account") {
                            SettingsButton(title: "Statistics", icon: "chart.bar.fill")
                            SettingsButton(title: "Saved Templates", icon: "heart.fill")
                            
                            // Log Out Button
                            Button(action: {
                                isLoggedIn = false
                            }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Log Out")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .foregroundColor(.mdOnErrorContainer)
                                .background(Color.mdErrorContainer)
                                .cornerRadius(Dimens.cornerBase)
                            }
                            .padding(.top, Dimens.spacingBase)
                        }
                    }
                    .padding(Dimens.spacingBase)
                }
            }
            
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
    }
}

// Helper for settings buttons
struct SettingsButton: View {
    var title: String
    var icon: String
    
    var body: some View {
        Button(action: {}) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.mdPrimary)
                Text(title)
                    .foregroundColor(.mdOnSurface)
                Spacer()
            }
            .padding()
            .background(Color.mdSurface) // Or transparent if in a list
            // .overlay(RoundedRectangle(...).stroke(...)) // If outlined style matches
        }
    }
}

// Helper for specific corner rounding
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
