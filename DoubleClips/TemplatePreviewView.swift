import SwiftUI

struct TemplatePreviewView: View {
    @State var templates: [TemplateData] // Passed from previous screen
    @State var initialScrollIndex: Int = 0 // Which item to start on
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.edgesIgnoringSafeArea(.all) // Ensure black background
                
                if templates.isEmpty {
                    Text("No Templates")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Vertical Paging using Rotated TabView
                    // Width and Height are swapped for the container
                    TabView(selection: $initialScrollIndex) {
                        ForEach(Array(templates.enumerated()), id: \.offset) { index, template in
                            TemplatePreviewItemView(
                                template: template,
                                index: index,
                                currentIndex: initialScrollIndex
                            )
                            .tag(index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .rotationEffect(.degrees(-90)) // Counter-rotate content
                        }
                    }
                    .frame(width: proxy.size.height, height: proxy.size.width) // Horizontal becomes Vertical dimensions
                    .rotationEffect(.degrees(90), anchor: .topLeading) // Rotate container
                    .offset(x: proxy.size.width) // Shift back to view coordinates
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar) // Hide Tab Bar if present
        .edgesIgnoringSafeArea(.all)
        .overlay(
            // Back Button (Top Left)
            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.3))
                    .clipShape(Circle())
            }
            .padding(.top, 40) // Status bar padding
            .padding(.leading, 16)
            , alignment: .topLeading
        )
        // Mock Comments Overlay Container (Empty for now)
        .overlay(
            VStack {
                Spacer()
                // Placeholder for CommentAreaScreen if needed later
            }
        )
    }
}

struct TemplatePreviewItemView: View {
    let template: TemplateData
    let index: Int
    let currentIndex: Int
    
    // Computed property for active state
    var isActive: Bool {
        index == currentIndex
    }
    
    /// The preview video + its clock (the strip follows it); only holds a video while this page is on screen.
    @StateObject private var preview = TemplatePreviewPlayer()
    /// The template's clips for the strip under the video.
    @State private var timelineInfo: TemplateTimelineInfo?
    
    // Mock States for interactivity
    @State private var isLiked: Bool = false
    @State private var likeCount: Int = 0
    @State private var isBookmarked: Bool = false
    @State private var bookmarkCount: Int = 0
    
    @State private var showLoginAlert: Bool = false
    // "Use template" -> TemplateExportView (Android: TemplateExportActivity)
    @State private var showTemplateExport: Bool = false
    
    // API Function
    func toggleLike() {
        guard let user = AuthRepository.shared.currentUser else {
            showLoginAlert = true
            return
        }
        
        // Optimistic Update
        let wasLiked = isLiked
        isLiked.toggle()
        likeCount += isLiked ? 1 : -1
        
        // API Call
        guard let url = URL(string: "https://app.vanvatcorp.com/doubleclips/api/toggle-like") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "username": user.username,
            "templateId": template.templateId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("Failed to encode like body: \(error)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Like API Error: \(error)")
                DispatchQueue.main.async {
                    // Revert on error
                    isLiked = wasLiked
                    likeCount += isLiked ? 1 : -1
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Like API Failed Status: \(httpResponse.statusCode)")
                DispatchQueue.main.async {
                    // Revert on failure
                    isLiked = wasLiked
                    likeCount += isLiked ? 1 : -1
                }
            }
        }.resume()
    }
    
    // Bookmark Function
    func toggleBookmark() {
        guard let user = AuthRepository.shared.currentUser else {
            showLoginAlert = true
            return
        }
        
        // Optimistic Update
        let wasBookmarked = isBookmarked
        isBookmarked.toggle()
        bookmarkCount += isBookmarked ? 1 : -1
        
        // API Call
        guard let url = URL(string: "https://app.vanvatcorp.com/doubleclips/api/toggle-bookmark") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "username": user.username,
            "templateId": template.templateId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("Failed to encode bookmark body: \(error)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Bookmark API Error: \(error)")
                DispatchQueue.main.async {
                    // Revert on error
                    isBookmarked = wasBookmarked
                    bookmarkCount += isBookmarked ? 1 : -1
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Bookmark API Failed Status: \(httpResponse.statusCode)")
                DispatchQueue.main.async {
                    // Revert on failure
                    isBookmarked = wasBookmarked
                    bookmarkCount += isBookmarked ? 1 : -1
                }
            }
        }.resume()
    }
    
    var body: some View {
        ZStack {
            // 1. Media Layer (Thumbnail / Video Mock)
            Color.black
            
            // Video Layer Logic: Only load the video if this is the active page
            if isActive, preview.hasVideo {
                TemplatePlayerLayerView(player: preview.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Fallback / Placeholder Thumbnail (Visible when not active or loading)
                AsyncImage(url: URL(string: template.templateSnapshotLink)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit) // Fit within bounds
                    } else {
                        Color.gray
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Paused Indicator (Only relevant if active)
            if isActive && preview.hasVideo && !preview.isPlaying {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // UI Overlay Layer
            HStack(alignment: .bottom) {
                
                // Left Zone (Bottom Info)
                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    
                    // Username
                    Text("@" + template.templateAuthor)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 1)
                    
                    // Info Row (Clips & Duration)
                    HStack(spacing: 15) {
                        HStack(spacing: 4) {
                            Image(systemName: "film") // baseline_local_movies_24
                                .foregroundColor(.white)
                            Text("\(template.templateTotalClip)")
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        
                        HStack(spacing: 4) {
                            Image(systemName: "hourglass.bottomhalf.fill") // baseline_hourglass_bottom_24
                                .foregroundColor(.white)
                            Text(formatDuration(template.templateDuration))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                    }
                    .font(.caption)
                    
                    // Timeline/Playhead Mock (FrameLayout + Playhead)
                    // Simplified representation
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 30) // Timeline height
                        .overlay(
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 2)
                        )
                        .cornerRadius(4)
                }
                .padding(.bottom, 80 + Constants.TEMPLATE_STRIP_BLOCK_HEIGHT) // Space for the strip + "Use Template" button
                .padding(.leading, 10)
                
                Spacer()
                
                // Right Zone (Actions) - Width 75dp approx
                VStack(spacing: 20) {
                    Spacer()
                    
                    // Heart
                    ActionItem(
                        icon: isLiked ? "heart.fill" : "heart",
                        label: "\(/*isLiked ? likeCount + 1 : */likeCount)",
                        color: isLiked ? .red : .white
                    ) {
                        toggleLike()
                    }
                    
                    // Comment
                    ActionItem(
                        icon: "bubble.right.fill", // baseline_comment_24
                        label: "\(template.comments.count)", // assuming mock comments or 0
                        color: .white
                    ) {
                        print("Open Comments")
                    }
                    
                    // Bookmark
                    ActionItem(
                        icon: isBookmarked ? "bookmark.fill" : "bookmark",
                        label: "\(/*isBookmarked ? bookmarkCount + 1 : */bookmarkCount)",
                        color: isBookmarked ? .yellow : .white
                    ) {
                        toggleBookmark()
                    }
                    
                    // Other/Menu
                    Button(action: {
                        print("More options")
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding()
                            .shadow(radius: 2)
                    }
                    .padding(.bottom, 80 + Constants.TEMPLATE_STRIP_BLOCK_HEIGHT)
                }
                .frame(width: 75)
            }
            .contentShape(Rectangle()) // Make empty areas tappable
            .onTapGesture {
                if preview.hasVideo { preview.toggle() }
            }
            
            // Bottom: the template's timeline (red playhead, clips by role) above the "Use Template" button
            VStack(spacing: 10) {
                Spacer()
                if isActive, let info = timelineInfo, !info.clips.isEmpty {
                    TemplateTimelineStrip(info: info, currentTime: preview.currentTime,
                                          onScrub: { preview.scrub(to: $0) },
                                          onScrubEnd: { preview.endScrub() })
                        .padding(.horizontal, 10)
                }
                Button(action: {
                    preview.pause()          // stop the preview video behind the new screen
                    showTemplateExport = true
                }) {
                    Text("Use template")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.mdPrimary)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 20) // Safe area
            }
        }
        
        .onAppear {
            if isActive { activatePreview() }
            // Init mock counts
            likeCount = template.heartCount
            bookmarkCount = template.bookmarkCount
            isLiked = template.isLiked ?? false
            isBookmarked = template.isBookmarked ?? false
        }
        .onChange(of: isActive) { active in
            if active { activatePreview() } else { preview.deactivate() }
        }
        .task(id: isActive) {
            // The template's timeline for the strip: from the server's timeline JSON when it has one,
            // otherwise one white stripe per clip slot.
            guard isActive, timelineInfo == nil else { return }
            if !template.templateTimelineLink.isEmpty, let info = try? await TemplateTimelineLoader.load(for: template) {
                timelineInfo = info
            } else {
                timelineInfo = TemplateTimelineInfo.legacy(template)
            }
        }
        .fullScreenCover(isPresented: $showTemplateExport) {
            TemplateExportView(template: template)
        }
        .alert("Login Required", isPresented: $showLoginAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Login") {
                // Navigate to login? Or just dismiss for now.
                // In Android it just shows "Please login to like this template"
            }
        } message: {
            Text("Please login to like this template")
        }
    }
    
    private func activatePreview() {
        if let url = URL(string: template.templateVideoLink) { preview.activate(url) }
    }
    
    // Helper to format duration ms -> mm:ss
    func formatDuration(_ ms: Int64) -> String {
        let seconds = ms / 1000
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// Helper for Action Buttons (Heart, Comment etc)
struct ActionItem: View {
    var icon: String
    var label: String
    var color: Color
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .foregroundColor(color)
                    .shadow(radius: 2)
                
                Text(label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
        }
    }
}

// Temporary Mock for TemplateData extension if comments missing in model
extension TemplateData {
    var comments: [String] { [] } // Placeholder until Comment model added
}
