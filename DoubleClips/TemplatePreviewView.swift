import SwiftUI

struct TemplatePreviewView: View {
    /// The list the user came from (feed / search / liked / saved). Shared with that screen: swiping near the end
    /// loads the next page into the same list, so the grid underneath grows too.
    @ObservedObject var pager: TemplatePager
    @State var initialScrollIndex: Int // Which item to start on
    
    @Environment(\.presentationMode) var presentationMode
    
    init(pager: TemplatePager, initialScrollIndex: Int = 0) {
        self.pager = pager
        _initialScrollIndex = State(initialValue: initialScrollIndex)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.edgesIgnoringSafeArea(.all) // Ensure black background
                
                if pager.items.isEmpty {
                    Text("No Templates")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Vertical Paging using Rotated TabView
                    // Width and Height are swapped for the container
                    TabView(selection: $initialScrollIndex) {
                        ForEach(Array(pager.items.enumerated()), id: \.offset) { index, template in
                            TemplatePreviewItemView(
                                template: template,
                                index: index,
                                currentIndex: initialScrollIndex,
                                onBecameActive: { pager.loadNextIfNeeded(afterIndex: index) }
                            )
                            .background(ScrollEdgeEffectProbe()) // switches the paging scroll view's edge blur off
                            .tag(index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .rotationEffect(.degrees(-90)) // Counter-rotate content
                        }
                    }
                    .frame(width: proxy.size.height, height: proxy.size.width) // Horizontal becomes Vertical dimensions
                    .rotationEffect(.degrees(90), anchor: .topLeading) // Rotate container
                    .offset(x: proxy.size.width) // Shift back to view coordinates
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .hidingScrollEdgeEffect()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar) // the bar's scroll-edge blur would be drawn down the rotated page's side
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
    /// This page came on screen (the parent loads the next page when it is near the end of the list).
    var onBecameActive: () -> Void = { }
    
    /// Likes, bookmarks and counters: the newest numbers the app knows (grid, Profile lists and this page agree).
    @ObservedObject private var states = TemplateStateStore.shared
    private var live: TemplateData { states.applied(template) }
    
    // Computed property for active state
    var isActive: Bool {
        index == currentIndex
    }
    
    /// The preview video + its clock (the strip follows it); only holds a video while this page is on screen.
    @StateObject private var preview = TemplatePreviewPlayer()
    /// The template's clips for the strip under the video (from its timeline JSON)...
    @State private var timelineInfo: TemplateTimelineInfo?
    /// ...or, for an old template without a timeline, one white stripe per clip slot.
    @State private var legacyInfo: TemplateTimelineInfo?
    /// Why the timeline couldn't be loaded (the strip then says so instead of drawing stand-in stripes).
    @State private var timelineError: String?
    @State private var showOldTemplate = false
    
    @State private var showLoginAlert: Bool = false
    @State private var loginMessage: String = "Please login to like this template"
    @State private var actionError: String?
    // "Use template" -> TemplateExportView (Android: TemplateExportActivity)
    @State private var showTemplateExport: Bool = false
    
    // Like / bookmark: the heart answers at once, the request carries the wanted state, the server's numbers replace ours,
    // and a failure puts everything back (all in TemplateAPI).
    func toggleLike() {
        guard TemplateAPI.viewer != nil else {
            loginMessage = "Please login to like this template"
            showLoginAlert = true
            return
        }
        let want = !(live.isLiked ?? false)
        Task {
            do { try await TemplateAPI.setLike(template, liked: want) }
            catch { actionError = error.localizedDescription }
        }
    }
    
    func toggleBookmark() {
        guard TemplateAPI.viewer != nil else {
            loginMessage = "Please login to bookmark this template"
            showLoginAlert = true
            return
        }
        let want = !(live.isBookmarked ?? false)
        Task {
            do { try await TemplateAPI.setBookmark(template, bookmarked: want) }
            catch { actionError = error.localizedDescription }
        }
    }
    
    /// This page is the one on screen: report the view (the server counts once per viewer per 30 minutes)
    /// and let the parent load more when the list is nearly over.
    private func pageBecameActive() {
        activatePreview()
        onBecameActive()
        Task { await TemplateAPI.postView(template.templateId) }
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
                            // The list may say 0 (the server doesn't know it): then the video's own length.
                            Text(formatDuration(template.templateDuration > 0
                                                ? template.templateDuration : Int64(preview.duration * 1000)))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                    }
                    .font(.caption)
                }
                .padding(.bottom, 80 + Constants.TEMPLATE_STRIP_BLOCK_HEIGHT) // Space for the strip + "Use Template" button
                .padding(.leading, 10)
                
                Spacer()
                
                // Right Zone (Actions) - Width 75dp approx
                VStack(spacing: 20) {
                    Spacer()
                    
                    // Heart
                    ActionItem(
                        icon: (live.isLiked ?? false) ? "heart.fill" : "heart",
                        label: "\(live.heartCount)",
                        color: (live.isLiked ?? false) ? .red : .white
                    ) {
                        toggleLike()
                    }
                    
                    // Comment
                    ActionItem(
                        icon: "bubble.right.fill", // baseline_comment_24
                        label: "\(live.commentCount)", // the server's count (the comments panel is not on iOS yet)
                        color: .white
                    ) {
                        print("Open Comments")
                    }
                    
                    // Bookmark
                    ActionItem(
                        icon: (live.isBookmarked ?? false) ? "bookmark.fill" : "bookmark",
                        label: "\(live.bookmarkCount)",
                        color: (live.isBookmarked ?? false) ? .yellow : .white
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
                if isActive, let info = timelineInfo ?? legacyInfo, !info.clips.isEmpty {
                    TemplateTimelineStrip(info: info, currentTime: preview.currentTime,
                                          onScrub: { preview.scrub(to: $0) },
                                          onScrubEnd: { preview.endScrub() })
                        .padding(.horizontal, 10)
                } else if isActive, let error = timelineError {
                    Button { Task { await loadTimeline() } } label: {
                        Label("Couldn't load the timeline. Tap to retry.\n\(error)", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal, 10)
                }
                Button(action: {
                    // No timeline = made before timeline templates: only FFmpeg could render it, and iOS has none.
                    guard !template.templateTimelineLink.isEmpty else {
                        showOldTemplate = true
                        return
                    }
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
            if isActive { pageBecameActive() }
        }
        .onChange(of: isActive) { active in
            if active { pageBecameActive() } else { preview.deactivate() }
        }
        .task(id: isActive) {
            // The template's timeline for the strip: from the server's timeline JSON when it has one,
            // otherwise one white stripe per clip slot.
            guard isActive, timelineInfo == nil else { return }
            await loadTimeline()
        }
        .onChange(of: preview.duration) { seconds in
            // The strip of an old template spreads its stripes over the video's length once that is known.
            if timelineInfo == nil, template.templateTimelineLink.isEmpty, template.templateDuration <= 0 {
                legacyInfo = TemplateTimelineInfo.legacy(template, duration: seconds)
            }
        }
        .alert("This template is old", isPresented: $showOldTemplate) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("It was made with an older version of DoubleClips and can only be rendered with FFmpeg, which isn't available on iOS. Try another template.")
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
            Text(loginMessage)
        }
        .alert("Couldn't update", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
    }
    
    /// The template's timeline for the strip. Only a template WITHOUT a timeline link gets the evenly spaced
    /// stand-in; a link that fails to load is reported (screen + console), not hidden behind the stand-in.
    private func loadTimeline() async {
        timelineError = nil
        guard !template.templateTimelineLink.isEmpty else {
            print("[Template] \(template.templateId): the list has no templateTimelineLink (old template, or the list endpoint doesn't send it yet)")
            legacyInfo = TemplateTimelineInfo.legacy(template, duration: preview.duration)
            return
        }
        do {
            timelineInfo = try await TemplateTimelineLoader.load(for: template)
        } catch {
            timelineError = error.localizedDescription
            print("[Template] \(template.templateId): timeline load failed (\(template.templateTimelineLink)): \(error.localizedDescription)")
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
                
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
        }
    }
}
