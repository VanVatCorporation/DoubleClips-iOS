import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    // MARK: - App Storage (UserDefaults)
    // Keys match Android's shared_preferences keys
    @AppStorage("theme_mode") private var themeMode: String = "system"
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system
    @AppStorage("ads_popup") private var adsPopup: Bool = true
    @AppStorage("early_access_issues_notification") private var earlyAccessIssuesNotification: Bool = true

    // Van Vat Drive: this setting lives on the account (shared with the web and the Drive apps), not on this device.
    @State private var signedIn = DoubleClipsDrive.sessionToken() != nil
    @State private var thumbnails = true
    @State private var thumbnailsLoaded = false
    @State private var driveError: String?
    /// Hidden asset authors / templates: the count in the row follows what Settings > Hidden content does.
    @ObservedObject private var hidden = HiddenContent.shared
    
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
                
                // Language: System Default first, then the languages by name (each in its own language).
                Picker("Language", selection: $appLanguage) {
                    Text("System Default").tag(AppLanguage.system)
                    ForEach(AppLanguage.sortedForPicker) { language in
                        Text(verbatim: language.nativeName).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                
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
                Text(L(signedIn
                     ? "Shows small previews of your images in the Storage tab. Every preview downloads the image once, so it uses your daily download allowance."
                     : "Sign in from the Profile tab to change this."))
            }

            // Hidden content: asset authors (Assets tab) and templates the user hid on this phone, with a way back
            Section {
                NavigationLink {
                    HiddenContentView()
                } label: {
                    HStack {
                        Label("Hidden content", systemImage: "eye.slash")
                        Spacer()
                        let count = hidden.authors.count + hidden.templates.count
                        if count > 0 { Text("\(count)").foregroundColor(.secondary) }
                    }
                }
            } footer: {
                Text("Asset authors and templates you hid. They stay hidden on this phone only; show them again here.")
            }

            // About / Info Section (Optional, but good for completeness)
            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }
                NavigationLink { OpenSourceLicensesView() } label: { Text("Open-source licences") }
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
        } message: { Text(L(driveError ?? "")) }
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

// MARK: - Settings > Hidden content

/// What the user hid: asset authors ("Hide assets from X" in the Assets tab) and templates ("Hide this template").
/// "Show again" brings one back (the Assets list redraws at once; the Templates feed reloads the next time it is on screen),
/// "Show all" brings back the whole list.
struct HiddenContentView: View {
    @ObservedObject private var hidden = HiddenContent.shared

    var body: some View {
        List {
            Section {
                if hidden.authors.isEmpty {
                    Text("No hidden asset authors.").foregroundColor(.secondary)
                }
                ForEach(hidden.authors, id: \.self) { name in
                    row(title: "@" + name, subtitle: nil) { hidden.showAuthor(name) }
                }
            } header: {
                header("Asset authors", showAll: hidden.authors.isEmpty ? nil : { hidden.showAllAuthors() })
            }

            Section {
                if hidden.templates.isEmpty {
                    Text("No hidden templates.").foregroundColor(.secondary)
                }
                ForEach(hidden.templates) { template in
                    row(title: template.title.isEmpty ? template.id : template.title,
                        subtitle: template.author.isEmpty ? nil : "@" + template.author) { hidden.show(templateId: template.id) }
                }
            } header: {
                header("Templates", showAll: hidden.templates.isEmpty ? nil : { hidden.showAllTemplates() })
            } footer: {
                Text("What you hid stays hidden on this phone only. Show it again here.")
            }
        }
        .navigationTitle("Hidden content")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ title: LocalizedStringKey, showAll: (() -> Void)?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let showAll { Button("Show all", action: showAll).font(.footnote).textCase(nil) }
        }
    }

    private func row(title: String, subtitle: String?, showAgain: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                if let subtitle { Text(verbatim: subtitle).font(.footnote).foregroundColor(.secondary) }
            }
            Spacer()
            Button("Show again", action: showAgain).buttonStyle(.bordered)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
