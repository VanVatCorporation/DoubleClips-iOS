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
    
    @State private var isPlaying: Bool = false
    
    // Mock States for interactivity
    @State private var isLiked: Bool = false
    @State private var likeCount: Int = 0
    @State private var isBookmarked: Bool = false
    @State private var bookmarkCount: Int = 0
    
    var body: some View {
        ZStack {
            // 1. Media Layer (Thumbnail / Video Mock)
            Color.black
            
            // Video Layer Logic: Only load VideoPlayer if this is the active page
            if isActive, let videoURL = URL(string: template.templateVideoLink) {
                VideoPlayerView(url: videoURL, isPlaying: $isPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        isPlaying = true
                    }
                    .onDisappear {
                        isPlaying = false
                    }
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
            if isActive && !isPlaying {
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
                .padding(.bottom, 80) // Space for "Use Template" button
                .padding(.leading, 10)
                
                Spacer()
                
                // Right Zone (Actions) - Width 75dp approx
                VStack(spacing: 20) {
                    Spacer()
                    
                    // Heart
                    ActionItem(
                        icon: isLiked ? "heart.fill" : "heart",
                        label: "\(isLiked ? likeCount + 1 : likeCount)",
                        color: isLiked ? .red : .white
                    ) {
                        isLiked.toggle()
                        // Mock API call: toggle-like
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
                        label: "\(isBookmarked ? bookmarkCount + 1 : bookmarkCount)",
                        color: isBookmarked ? .yellow : .white
                    ) {
                        isBookmarked.toggle()
                         // Mock API call: toggle-bookmark
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
                    .padding(.bottom, 80)
                }
                .frame(width: 75)
            }
            .contentShape(Rectangle()) // Make empty areas tappable
            .onTapGesture {
                isPlaying.toggle()
            }
            
            // Bottom "Use Template" Button
            VStack {
                Spacer()
                Button(action: {
                    print("Use Template: \(template.templateTitle)")
                    // Navigate to TemplateExportActivity equivalent
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
            // Init mock counts
            likeCount = template.heartCount
            bookmarkCount = template.bookmarkCount
        }
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
