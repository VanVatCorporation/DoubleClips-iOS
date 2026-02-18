import SwiftUI

/// Early access warning popup - equivalent of MainActivity.loadCurrentIssuesAndShow()
/// Fetches current known issues from the server and displays them.
/// Controlled by `early_access_issues_notification` UserDefaults key.
struct EarlyAccessPopup: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("early_access_issues_notification") private var showEarlyAccess: Bool = true
    
    @State private var issues: String = "Loading…"
    @State private var isLoading: Bool = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 24)
                
                // Title
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 24))
                    Text("Early access warning")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 24)
                
                // Main message
                Text("This app will undergo many core changes in the near future. If you update to the latest version and find that your project can't be edited or modified, don't panic—just click the three-line menu button and select \"Share project\" to create a backup. Your work is still there; it just needs to be migrated to the new version. Then visit our GitHub page and submit an issue including the version. Thank you for using our app.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                
                // Issues section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Known issues in this version:")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Fetching issues…")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(issues)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
                .background(Color.mdSurfaceContainerHigh)
                .cornerRadius(12)
                .padding(.horizontal, 24)
                
                Text("This popup can be disabled in Settings, and usually takes about a few kilobytes of internet depending on how many issues there are.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                
                // Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        dismiss()
                    }) {
                        Text("OK")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.mdPrimary)
                            .cornerRadius(12)
                    }
                    
                    Button(action: {
                        // Write false to UserDefaults — same as Android's "Don't show again"
                        showEarlyAccess = false
                        dismiss()
                    }) {
                        Text("Don't show again")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)
                
                Spacer(minLength: 32)
            }
        }
        .background(Color.mdBackground.edgesIgnoringSafeArea(.all))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            fetchIssues()
        }
    }
    
    // MARK: - Fetch Issues from Server
    
    private func fetchIssues() {
        isLoading = true
        guard let url = URL(string: "https://app.vanvatcorp.com/doubleclips/api/fetch-issues") else {
            issues = "Failed to get issues from server."
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let error = error {
                    issues = "Failed to get issues from server."
                    return
                }
                
                guard let data = data,
                      let issueArray = try? JSONDecoder().decode([String].self, from: data) else {
                    issues = "Failed to get issues from server."
                    return
                }
                
                if issueArray.isEmpty {
                    issues = "None"
                } else {
                    issues = issueArray.map { "• \($0)" }.joined(separator: "\n")
                }
            }
        }.resume()
    }
}

#Preview {
    EarlyAccessPopup()
}
