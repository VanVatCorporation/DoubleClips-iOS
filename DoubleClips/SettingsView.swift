import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    // MARK: - App Storage (UserDefaults)
    // Keys match Android's shared_preferences keys
    @AppStorage("theme_mode") private var themeMode: String = "system"
    @AppStorage("ads_popup") private var adsPopup: Bool = true
    @AppStorage("early_access_issues_notification") private var earlyAccessIssuesNotification: Bool = true

    // Van Vat Drive: this setting lives on the account (shared with the web and the Drive apps), not on this device.
    @State private var signedIn = DoubleClipsDrive.sessionToken() != nil
    @State private var thumbnails = true
    @State private var thumbnailsLoaded = false
    @State private var driveError: String?
    
    var body: some View {
        Form {
            // General Section
            Section(header: Text("General")) {
                // Theme Mode
                Picker("Theme", selection: $themeMode) {
                    Text("Dark Mode").tag("dark")
                    Text("Light Mode").tag("light")
                    Text("System Default").tag("system")
                }
                .pickerStyle(.menu) // Or .navigationLink based on preference
                
                // Ads Popup
                Toggle("Ads popup", isOn: $adsPopup)
                
                // Early Access Notification
                Toggle("Early access & Issues Notification Popup", isOn: $earlyAccessIssuesNotification)
            }
            
            // Van Vat Drive
            Section {
                Toggle("Preview thumbnails", isOn: Binding(get: { thumbnails }, set: { setThumbnails($0) }))
                    .disabled(!signedIn || !thumbnailsLoaded)
                Link(destination: DoubleClipsDrive.client.legalPageURL(slug: "terms", lang: nil)) { Label("Terms of Service", systemImage: "doc.text") }
                Link(destination: DoubleClipsDrive.client.legalPageURL(slug: "privacy", lang: nil)) { Label("Privacy Policy", systemImage: "hand.raised") }
            } header: { Text("VanVatDrive") } footer: {
                Text(signedIn
                     ? "Shows small previews of your images in the Storage tab. Every preview downloads the image once, so it uses your daily download allowance."
                     : "Sign in from the Profile tab to change this.")
            }

            // About / Info Section (Optional, but good for completeness)
            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard signedIn, let me = try? await DoubleClipsDrive.client.me() else { return }
            thumbnails = me.previewThumbnails
            thumbnailsLoaded = true
        }
        .alert("VanVatDrive", isPresented: Binding(get: { driveError != nil }, set: { if !$0 { driveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(driveError ?? "") }
    }

    /// Flips immediately, rolls back if the server refuses.
    private func setThumbnails(_ on: Bool) {
        let previous = thumbnails
        thumbnails = on
        Task {
            do { try await DoubleClipsDrive.client.updateSettings(previewThumbnails: on) }
            catch { thumbnails = previous; driveError = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
