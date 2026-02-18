import SwiftUI

/// iOS equivalent of EditingActivity + layout-port/layout_editing.xml
/// Portrait layout with 3 main zones:
///   1. previewZone  – video preview + top bar + controller bar
///   2. editingZone  – timeline tracks + toolbar (300dp)
struct EditingView: View {
    let project: ProjectData
    @Environment(\.dismiss) var dismiss
    
    // Playback state
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0.0
    @State private var totalDuration: Double = 30.0 // placeholder
    
    // Timeline state
    @State private var tracks: [TrackModel] = []
    @State private var selectedToolbar: ToolbarMode = .default
    
    // Canvas paused alert
    @State private var isCanvasPaused: Bool = false
    
    enum ToolbarMode {
        case `default`, clip, track, clips
    }
    
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                
                // ── PREVIEW ZONE ──────────────────────────────────────────────
                // Fills all space above the editing zone
                ZStack {
                    Color.black // Video canvas background
                    
                    // ── Video Preview Area ─────────────────────────────────
                    ZStack {
                        // Placeholder for actual video renderer
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 56))
                                .foregroundColor(.white.opacity(0.3))
                            Text("Video Preview")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        
                        // Paused canvas alert (android:id="pausedCanvasAlertPanel")
                        if isCanvasPaused {
                            ZStack {
                                Color.gray.opacity(0.85)
                                VStack(spacing: 12) {
                                    Text("Canvas was paused to save resource.")
                                        .font(.system(size: 15))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                    Button("Resume") {
                                        isCanvasPaused = false
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding()
                            }
                        }
                    }
                    
                    VStack {
                        // ── Top Bar (50dp) ─────────────────────────────────
                        // android:id="top_bar" height=50dp
                        HStack(spacing: 0) {
                            // Back button (android:id="backButton")
                            Button(action: { dismiss() }) {
                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                            }
                            
                            // Settings button (android:id="settingsButton")
                            Button(action: { /* Open video properties */ }) {
                                Image(systemName: "display")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                            }
                            
                            Spacer()
                            
                            // Center canvas info (android:id="textCanvasControllerInfo")
                            Text(project.projectTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            // Export button (android:id="exportButton")
                            Button(action: { /* Launch export */ }) {
                                Text("EXPORT")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.mdPrimary)
                                    .cornerRadius(8)
                            }
                            .padding(.trailing, 12)
                        }
                        .frame(height: 50)
                        .background(Color.black.opacity(0.5))
                        
                        Spacer()
                        
                        // ── Controller Bar (40dp) ──────────────────────────
                        // android:id="controller_bar" height=40dp
                        // Undo | Play/Pause (center) | Redo
                        HStack {
                            // Undo (android:id="undoButton")
                            Button(action: { /* Undo */ }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                            }
                            
                            Spacer()
                            
                            // Play/Pause (android:id="playPauseButton", centered)
                            Button(action: { isPlaying.toggle() }) {
                                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                            }
                            
                            Spacer()
                            
                            // Redo (android:id="redoButton")
                            Button(action: { /* Redo */ }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                            }
                        }
                        .frame(height: 40)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.5))
                    }
                }
                
                // ── EDITING ZONE (300dp) ──────────────────────────────────────
                // android:id="editingZone" height=300dp, alignParentBottom
                VStack(spacing: 0) {
                    
                    // ── Editing Track Zone ─────────────────────────────────
                    // android:id="editingTrackZone" fills above editingToolsZone
                    VStack(spacing: 0) {
                        
                        // ── Timestamp Bar (20dp) ───────────────────────────
                        // android:id="timestampBar"
                        HStack {
                            Text(formatTime(currentTime))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Text(formatTime(totalDuration))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .frame(height: 20)
                        .padding(.horizontal, 8)
                        .background(Color(hex: "#1A1A1A"))
                        
                        // ── Timeline Area ──────────────────────────────────
                        // android:id="timelineArea"
                        HStack(spacing: 0) {
                            
                            // Track Info Column (50dp) — android:id="trackInfoScroll"
                            // Contains add-track button + track labels
                            VStack(spacing: 0) {
                                Button(action: { addTrack() }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 50, height: 50)
                                        .background(Color(hex: "#222222"))
                                }
                                
                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(tracks) { track in
                                            TrackLabelView(track: track)
                                        }
                                    }
                                }
                            }
                            .frame(width: 50)
                            .background(Color(hex: "#1A1A1A"))
                            
                            // Timeline Wrapper — ruler + tracks + playhead
                            ZStack(alignment: .top) {
                                VStack(spacing: 0) {
                                    // Ruler (15sp height) — android:id="ruler_scroll"
                                    TimelineRulerView(
                                        currentTime: currentTime,
                                        totalDuration: totalDuration
                                    )
                                    .frame(height: 20)
                                    
                                    // Tracks scroll area — android:id="trackVerticalScrollView"
                                    ScrollView([.vertical, .horizontal], showsIndicators: false) {
                                        LazyVStack(spacing: 0) {
                                            ForEach(tracks) { track in
                                                TrackRowView(track: track)
                                            }
                                            // Blank spacer track (addNewTrackBlankTrackSpacer)
                                            Color(hex: "#222222")
                                                .frame(height: 100)
                                        }
                                        .frame(minWidth: geo.size.width - 50)
                                    }
                                    .background(Color(hex: "#111111"))
                                }
                                
                                // Playhead — android:id="playhead" (red, centered)
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 2)
                                    .frame(maxHeight: .infinity)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    
                    // ── Editing Tools Zone (60dp) ──────────────────────────
                    // android:id="editingToolsZone" height=60dp, alignParentBottom
                    // Toolbar switches based on selection context
                    Group {
                        switch selectedToolbar {
                        case .default:
                            DefaultToolbarView()
                        case .clip:
                            ClipToolbarView()
                        case .track:
                            TrackToolbarView()
                        case .clips:
                            ClipsToolbarView()
                        }
                    }
                    .frame(height: 60)
                    .background(Color(hex: "#1A1A1A"))
                }
                .frame(height: 300)
                .background(Color(hex: "#111111"))
            }
        }
        
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar) // Hide Tab Bar if present
        .edgesIgnoringSafeArea(.all)
        
        .ignoresSafeArea()
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear {
            // Add one default track on open
            if tracks.isEmpty { addTrack() }
        }
    }
    
    // MARK: - Actions
    
    private func addTrack() {
        let newTrack = TrackModel(index: tracks.count)
        withAnimation { tracks.append(newTrack) }
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

// MARK: - Data Models

struct TrackModel: Identifiable {
    let id = UUID()
    var index: Int
    var clips: [ClipModel] = []
}

struct ClipModel: Identifiable {
    let id = UUID()
    var name: String
    var startTime: Double
    var duration: Double
}

// MARK: - Sub-Views

/// Track label shown in the left 50dp column
private struct TrackLabelView: View {
    let track: TrackModel
    var body: some View {
        VStack(spacing: 2) {
            Text("T\(track.index + 1)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(width: 50, height: 100)
        .background(Color(hex: "#222222"))
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// One track row in the timeline scroll area
private struct TrackRowView: View {
    let track: TrackModel
    var body: some View {
        ZStack(alignment: .leading) {
            Color(hex: "#1A1A1A")
            HStack(spacing: 2) {
                ForEach(track.clips) { clip in
                    ClipBlockView(clip: clip)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 100)
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// A single clip block on the timeline
private struct ClipBlockView: View {
    let clip: ClipModel
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.mdPrimary.opacity(0.8))
            .frame(width: max(40, CGFloat(clip.duration) * 100), height: 88)
            .overlay(
                Text(clip.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4),
                alignment: .leading
            )
    }
}

/// Time ruler showing tick marks
private struct TimelineRulerView: View {
    let currentTime: Double
    let totalDuration: Double
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let pixelsPerSecond: CGFloat = 100
                let totalWidth = max(size.width, CGFloat(totalDuration) * pixelsPerSecond + size.width)
                
                // Draw tick marks every second
                var t: CGFloat = 0
                while t * pixelsPerSecond < totalWidth {
                    let x = size.width / 2 + t * pixelsPerSecond - CGFloat(currentTime) * pixelsPerSecond
                    let isMajor = Int(t) % 5 == 0
                    let tickHeight: CGFloat = isMajor ? 12 : 6
                    
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                        },
                        with: .color(.white.opacity(isMajor ? 0.6 : 0.3)),
                        lineWidth: 1
                    )
                    
                    if isMajor {
                        let label = String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
                        context.draw(
                            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.6)),
                            at: CGPoint(x: x + 2, y: 2),
                            anchor: .topLeading
                        )
                    }
                    t += 1
                }
            }
        }
        .background(Color(hex: "#1A1A1A"))
    }
}

// MARK: - Toolbar Views

/// Default toolbar — view_toolbar_default.xml
/// Buttons: Add, Delete, Cut, Files, Import
private struct DefaultToolbarView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "photo.badge.plus", label: "Add") {}
                ToolbarButton(icon: "trash", label: "Delete") {}
                ToolbarButton(icon: "scissors", label: "Cut") {}
                ToolbarButton(icon: "folder", label: "Files") {}
                ToolbarButton(icon: "square.and.arrow.down", label: "Import") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Clip toolbar — view_toolbar_clip.xml
/// Buttons: Delete, Split, Clone, Edit, Keyframe, SelectMultiple, AllKeyframe, Restate, Export
private struct ClipToolbarView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") {}
                ToolbarButton(icon: "scissors", label: "Split") {}
                ToolbarButton(icon: "doc.on.doc", label: "Clone") {}
                ToolbarButton(icon: "pencil.and.outline", label: "Edit") {}
                ToolbarButton(icon: "sparkles", label: "Keyframe") {}
                ToolbarButton(icon: "list.bullet", label: "Multi") {}
                ToolbarButton(icon: "arrow.triangle.merge", label: "AllKey") {}
                ToolbarButton(icon: "arrow.counterclockwise", label: "Restate") {}
                ToolbarButton(icon: "square.and.arrow.up", label: "Export") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Track toolbar — view_toolbar_track.xml (placeholder)
private struct TrackToolbarView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") {}
                ToolbarButton(icon: "square.and.arrow.up", label: "Export") {}
                ToolbarButton(icon: "square.and.arrow.down", label: "Import") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Clips (multi-select) toolbar — view_toolbar_clips.xml (placeholder)
private struct ClipsToolbarView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") {}
                ToolbarButton(icon: "scissors", label: "Split") {}
                ToolbarButton(icon: "doc.on.doc", label: "Clone") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Reusable toolbar icon button — equivalent of NavigationIconLayout
private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(width: 60, height: 56)
        }
    }
}


#Preview {
    EditingView(project: ProjectData(
        projectPath: "/preview",
        projectTitle: "My Project",
        projectTimestamp: 1700000000000,
        projectSize: 0,
        projectDuration: 0
    ))
}
