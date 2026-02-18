import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    // MARK: - App Storage (UserDefaults)
    // Keys match Android's shared_preferences keys
    @AppStorage("theme_mode") private var themeMode: String = "system"
    @AppStorage("ads_popup") private var adsPopup: Bool = true
    @AppStorage("early_access_issues_notification") private var earlyAccessIssuesNotification: Bool = true
    
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
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
