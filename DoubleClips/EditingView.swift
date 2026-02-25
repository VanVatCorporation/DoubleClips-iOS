import SwiftUI
import _AVKit_SwiftUI
import Combine

/// iOS equivalent of EditingActivity + layout-port/layout_editing.xml
/// Portrait layout with 3 main zones:
///   1. previewZone  – video preview + top bar + controller bar
///   2. editingZone  – timeline tracks + toolbar (300dp)
struct EditingView: View {
    let project: ProjectData
    @Environment(\.dismiss) var dismiss
    
    // Playback engine
    @StateObject private var engine = EditingPlayer()
    @State private var totalDuration: Double = 30.0 // placeholder
    
    // Timeline state
    @StateObject private var timeline: Timeline = Timeline()
    @State private var selectedToolbar: ToolbarMode = .default
    @State private var selectedTrackID: UUID?
    @State private var selectedClipID: UUID?
    @State private var activeOverlay: OverlayType?
    
    // Zoom state
    @State private var pixelsPerSecond: CGFloat = 50.0
    @GestureState private var pinchScale: CGFloat = 1.0
    
    // File Importer state
    @State private var showFileImporter = false
    
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
                        // Native AVPlayer Renderer
                        if engine.player.currentItem != nil {
                            VideoPlayer(player: engine.player)
                                .disabled(true) // Hide native controls
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 56))
                                    .foregroundColor(.white.opacity(0.3))
                                Text("Add media to begin")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.4))
                            }
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
                            Button(action: { engine.togglePlayPause() }) {
                                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
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
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                    
                    // ── Editing Track Zone ─────────────────────────────────
                    // android:id="editingTrackZone" fills above editingToolsZone
                    VStack(spacing: 0) {
                        
                        // ── Timestamp Bar (20dp) ───────────────────────────
                        // android:id="timestampBar"
                        HStack {
                            Text(formatTime(engine.currentTime))
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
                                        ForEach(timeline.tracks) { track in
                                            TrackLabelView(track: track)
                                        }
                                    }
                                }
                            }
                            .frame(width: 50)
                            .background(Color(hex: "#1A1A1A"))
                            
                            // Timeline Wrapper — ruler + tracks + playhead
                            ZStack(alignment: .top) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    VStack(spacing: 0) {
                                    // Ruler (15sp height) — android:id="ruler_scroll"
                                        TimelineRulerView(
                                            currentTime: engine.currentTime,
                                            totalDuration: totalDuration,
                                            pps: pixelsPerSecond * pinchScale
                                        )
                                        .frame(height: 20)
                                        
                                        // Tracks scroll area — android:id="trackVerticalScrollView"
                                        ScrollView(.vertical, showsIndicators: false) {
                                            LazyVStack(spacing: 0) {
                                                ForEach(timeline.tracks) { track in
                                                    TrackRowView(
                                                        track: track,
                                                        isSelected: selectedTrackID == track.id,
                                                        selectedClipID: selectedClipID,
                                                        pps: pixelsPerSecond * pinchScale,
                                                        onClipTap: { clip in selectingClip(clip) },
                                                        onTap: { selectingTrack(track) }
                                                    )
                                                }
                                                // Blank spacer track (addNewTrackBlankTrackSpacer)
                                                Color(hex: "#222222")
                                                    .frame(height: 100)
                                                    .onTapGesture {
                                                        addTrack()
                                                    }
                                            }
                                        }
                                        .background(Color(hex: "#111111"))
                                    }
                                    .frame(minWidth: geo.size.width - 50)
                                    .gesture(
                                        MagnificationGesture()
                                            .updating($pinchScale) { currentState, gestureState, _ in
                                                gestureState = currentState
                                            }
                                            .onEnded { scale in
                                                // Clamp zoom level to prevent absurd scaling
                                                let newScale = pixelsPerSecond * scale
                                                pixelsPerSecond = max(10, min(newScale, 800))
                                            }
                                    )
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
                    
                    // Editing Tools Zone (60dp) ──────────────────────────
                    // android:id="editingToolsZone" height=60dp, alignParentBottom
                    // Toolbar switches based on selection context
                    Group {
                        switch selectedToolbar {
                        case .default:
                            DefaultToolbarView()
                        case .clip:
                            ClipToolbarView(
                                onEdit: { withAnimation { activeOverlay = .videoProperties } }
                            )
                        case .track:
                            TrackToolbarView(onAddMedia: { showFileImporter = true })
                        case .clips:
                            ClipsToolbarView()
                        }
                    }
                    .frame(height: 60)
                    .background(Color(hex: "#1A1A1A"))
                }
                
                // Specific Edit Overlays (slides up over editingZone)
                if let overlayType = activeOverlay {
                    let selectedClip = timeline.tracks.flatMap({ $0.clips }).first(where: { $0.id == selectedClipID })
                    SpecificEditOverlay(type: overlayType, clip: selectedClip) {
                        withAnimation { activeOverlay = nil }
                    }
                }
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
            setupPreview()
            setupTimelinePinchAndZoom()
            setupSpecificEdit()
            setupToolbars()
            handleEditZoneInteraction()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audiovisualContent, .image],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }
    
    // MARK: - Activity Lifecycle Mimic (onCreate flow)
    
    private func setupPreview() {
        // Initialize preview dimensions/state
        if timeline.tracks.isEmpty { addTrack() }
    }
    
    private func setupTimelinePinchAndZoom() {
        // Future: Attach magnification gesture logic to scale pixelsPerSecond
    }
    
    private func setupSpecificEdit() {
        // Future: specific edit screens init (TextEdit, EffectEdit, etc.)
    }
    
    private func setupToolbars() {
        // Set initial toolbar states
        updateToolbarState()
    }
    
    private func handleEditZoneInteraction() {
        // Future: Setup overall interaction states (e.g. tap to deselect)
    }
    
    // MARK: - Actions
    
    private func selectingTrack(_ track: EditingView.Track) {
        if selectedTrackID == track.id {
            selectedTrackID = nil
        } else {
            selectedTrackID = track.id
            selectedClipID = nil
        }
        updateToolbarState()
    }
    
    private func selectingClip(_ clip: EditingView.Clip) {
        if selectedClipID == clip.id {
            selectedClipID = nil
        } else {
            selectedClipID = clip.id
            selectedTrackID = nil
        }
        updateToolbarState()
    }
    
    private func updateToolbarState() {
        if selectedClipID != nil {
            selectedToolbar = .clip
        } else if selectedTrackID != nil {
            selectedToolbar = .track
        } else {
            selectedToolbar = .default
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let trackID = selectedTrackID,
              let trackIndex = timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        switch result {
        case .success(let urls):
            for url in urls {
                let defaultDuration: Float = 3.0
                let newClip = Clip(
                    clipName: url.lastPathComponent,
                    startTime: Float(engine.currentTime),
                    duration: defaultDuration,
                    trackIndex: trackIndex,
                    type: .video,
                    isClipHasAudio: true,
                    width: 1920,
                    height: 1080
                )
                timeline.tracks[trackIndex].clips.append(newClip)
                // Advance playhead sequentially
                engine.seek(to: engine.currentTime + Double(defaultDuration))
                totalDuration = max(totalDuration, engine.currentTime)
            }
            // Trigger rebuilding AVFoundation composition
            engine.rebuildComposition(from: timeline, projectDir: URL(fileURLWithPath: project.projectPath))
        case .failure(let error):
            print("Failed to import media: \(error)")
        }
    }
    
    private func addTrack() {
        let newTrack = Track(timelineIndex: timeline.tracks.count)
        withAnimation { timeline.tracks.append(newTrack) }
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

// MARK: - Sub-Views

/// Track label shown in the left 50dp column
private struct TrackLabelView: View {
    @ObservedObject var track: EditingView.Track
    var body: some View {
        VStack(spacing: 2) {
            Text("T\(track.timelineIndex + 1)")
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
    @ObservedObject var track: EditingView.Track
    var isSelected: Bool = false
    var selectedClipID: UUID?
    var pps: CGFloat
    
    var onClipTap: (EditingView.Clip) -> Void
    var onTap: () -> Void
    
    var body: some View {
        ZStack(alignment: .leading) {
            Color(hex: isSelected ? "#333333" : "#1A1A1A")
            HStack(spacing: 2) {
                ForEach(track.clips) { clip in
                    ClipBlockView(
                        clip: clip,
                        isSelected: selectedClipID == clip.id,
                        pps: pps
                    )
                    .onTapGesture {
                        onClipTap(clip)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 100)
        .overlay(
            Rectangle()
                .stroke(isSelected ? Color.mdPrimary : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
        )
        .onTapGesture {
            onTap()
        }
    }
}

/// A single clip block on the timeline
private struct ClipBlockView: View {
    @ObservedObject var clip: EditingView.Clip
    var isSelected: Bool
    var pps: CGFloat
    
    @State private var dragInitialDuration: Float = 0
    @State private var dragInitialStartTime: Float = 0
    @State private var dragInitialStartTrim: Float = 0
    @State private var dragInitialEndTrim: Float = 0
    
    // Derived values for the clip block
    var blockWidth: CGFloat {
        max(20, CGFloat(clip.duration) * pps)
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.mdPrimary.opacity(0.8))
            
            Text(clip.clipName)
                .font(.system(size: 10))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, lineWidth: 2)
                
                // Left Handle
                HStack {
                    ZStack {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 12)
                        Image(systemName: "chevron.compact.left")
                            .font(.system(size: 10))
                            .foregroundColor(.black)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragInitialDuration == 0 {
                                    dragInitialDuration = clip.duration
                                    dragInitialStartTime = clip.startTime
                                    dragInitialStartTrim = clip.startClipTrim
                                }
                                let delta = Float(value.translation.width / pps)
                                let newDuration = max(0.5, dragInitialDuration - delta)
                                let actualDelta = dragInitialDuration - newDuration
                                
                                clip.duration = newDuration
                                clip.startTime = dragInitialStartTime + actualDelta
                                clip.startClipTrim = max(0, dragInitialStartTrim + actualDelta)
                            }
                            .onEnded { _ in dragInitialDuration = 0 }
                    )
                    
                    Spacer()
                    
                    // Right Handle
                    ZStack {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 12)
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 10))
                            .foregroundColor(.black)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragInitialDuration == 0 {
                                    dragInitialDuration = clip.duration
                                    dragInitialEndTrim = clip.endClipTrim
                                }
                                let delta = Float(value.translation.width / pps)
                                let newDuration = max(0.5, dragInitialDuration + delta)
                                
                                clip.duration = newDuration
                                clip.endClipTrim = max(0, clip.originalDuration - clip.duration - clip.startClipTrim)
                            }
                            .onEnded { _ in dragInitialDuration = 0 }
                    )
                }
            }
        }
        .frame(width: blockWidth, height: 88)
        .clipped()
    }
}

/// Time ruler showing tick marks
private struct TimelineRulerView: View {
    let currentTime: Double
    let totalDuration: Double
    let pps: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let totalWidth = max(size.width, CGFloat(totalDuration) * pps + size.width)
                
                // Draw tick marks every second
                var t: CGFloat = 0
                while t * pps < totalWidth {
                    let x = size.width / 2 + t * pps - CGFloat(currentTime) * pps
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
    var onEdit: () -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") {}
                ToolbarButton(icon: "scissors", label: "Split") {}
                ToolbarButton(icon: "doc.on.doc", label: "Clone") {}
                ToolbarButton(icon: "pencil.and.outline", label: "Edit") { onEdit() }
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
    var onAddMedia: () -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "photo.badge.plus", label: "Add media") { onAddMedia() }
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
