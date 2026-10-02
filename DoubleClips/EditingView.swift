import SwiftUI
import _AVKit_SwiftUI
import Combine
import UIKit

/// iOS equivalent of EditingActivity + layout-port/layout_editing.xml
/// Portrait layout with 3 main zones:
///   1. previewZone  – video preview + top bar + controller bar
///   2. editingZone  – timeline tracks + toolbar (300dp)
struct EditingView: View {
    let project: ProjectData
    let isPreview: Bool
    @Environment(\.dismiss) var dismiss
    
    // Playback engine
    @StateObject private var engine = EditingPlayer()
    @StateObject private var previewSession = PreviewEditSession()
    /// Ghost of the clip being long-press-dragged (nil = no drag). See EditingView+ClipDrag.swift.
    @State private var clipGhost: ClipGhost?
    
    // Undo/Redo — equivalent of EditingActivity's static `actionManager` (CommandManager)
    @StateObject private var commandManager = CommandManager()
    
    // Timeline state
    @StateObject private var timeline: Timeline = Timeline()
    
    // Persistence (project.timeline) — see EditingView+Persistence.swift
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasLoadedProject = false
    @State private var loadNote: String?
    @State private var autosaveWork: DispatchWorkItem?
    @State private var selectedToolbar: ToolbarMode = .default
    @State private var selectedTrackID: UUID?
    @State private var selectedClipID: UUID?
    // Multi-select — equivalent of Android's `isClipSelectMultiple` + `selectedClips`
    @State private var isMultiSelectMode: Bool = false
    @State private var selectedClipIDs: Set<UUID> = []
    @State private var activeOverlay: OverlayType?
    
    // Zoom state
    @State private var pixelsPerSecond: CGFloat = 50.0
    @GestureState private var pinchScale: CGFloat = 1.0
    
    // Timeline scroll & center-offset (mirrors Android centerOffset mechanism)
    // centerOffset = (trackAreaWidth / 2) so that time=0 aligns with the fixed
    // center playhead when scrollOffset == 0.
    @State private var timelineScrollOffset: CGFloat = 0
    
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
                    // On-canvas move / pinch / twist + selection box (Android: ClipRenderer gestures)
                    .overlay(
                        Group {
                            if engine.player.currentItem != nil {
                                PreviewInteractionLayer(
                                    timeline: timeline,
                                    selectedClipID: selectedClipID,
                                    playhead: Float(engine.currentTime),
                                    settings: engine.settings,
                                    commandManager: commandManager,
                                    session: previewSession,
                                    onSelect: { selectingClip($0) },
                                    onLiveChange: { engine.refreshFrame() },
                                    onChanged: { rebuildPreview() }
                                )
                            }
                        }
                    )
                    
                    VStack {
                        if !isPreview {
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
                        }
                        
                        Spacer()
                        
                        if !isPreview {
                            // ── Controller Bar (40dp) ──────────────────────────
                            // android:id="controller_bar" height=40dp
                            // Undo | Play/Pause (center) | Redo
                            HStack {
                                // Undo (android:id="undoButton")
                                Button(action: { performUndo() }) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 22))
                                        .foregroundColor(commandManager.canUndo ? .white : .white.opacity(0.3))
                                        .frame(width: 40, height: 40)
                                }
                                .disabled(!commandManager.canUndo)
                                
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
                                Button(action: { performRedo() }) {
                                    Image(systemName: "arrow.uturn.forward")
                                        .font(.system(size: 22))
                                        .foregroundColor(commandManager.canRedo ? .white : .white.opacity(0.3))
                                        .frame(width: 40, height: 40)
                                }
                                .disabled(!commandManager.canRedo)
                            }
                            .frame(height: 40)
                            .padding(.horizontal, 16)
                            .background(Color.black.opacity(0.5))
                        }
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
                            Text(formatTime(Double(timeline.duration)))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .frame(height: 20)
                        .padding(.horizontal, 8)
                        .background(Color(hex: "#1A1A1A"))
                        
                        // ── Timeline Area ──────────────────────────────────
                        // android:id="timelineArea"
                        // Layout: fixed ruler on top, then ONE vertical scroll
                        // containing HStack(labels col | horizontal tracks scroll)
                        // This mirrors Android: trackInfoLayout and timelineTracksContainer
                        // share the same vertical ScrollView parent.
                        VStack(spacing: 0) {
                            // ── Ruler row — fixed, not part of vertical scroll ──
                            HStack(spacing: 0) {
                                Color(hex: "#1A1A1A").frame(width: 50, height: 20) // blank spacer under label col
                                TimelineRulerView(
                                    currentTime: engine.currentTime,
                                    totalDuration: Double(timeline.duration),
                                    pps: pixelsPerSecond * pinchScale
                                )
                                .frame(width: geo.size.width - 50, height: 20)
                            }
                            .frame(height: 20)
                            
                            // ── Shared vertical scroll ──────────────────────────
                            // Both label col and track rows scroll together
                            ScrollView(.vertical, showsIndicators: false) {
                                HStack(spacing: 0) {
                                    // Track Info Column (50dp) — android:id="trackInfoScroll" / trackInfoLayout
                                    VStack(spacing: 0) {
                                        ForEach(timeline.tracks) { track in
                                            TrackLabelView(track: track)
                                        }
                                        // Add-track button at bottom — matches Android addNewTrackButton position
                                        Button(action: { addTrack() }) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundColor(.white)
                                                .frame(width: 50, height: 100)
                                                .background(Color(hex: "#222222"))
                                        }
                                    }
                                    .frame(width: 50)
                                    .background(Color(hex: "#1A1A1A"))
                                    
                                    // Horizontal scroll for clip rows — android:id="trackHorizontalScrollView"
                                    // centerOffset = half the track-area width (geo.size.width - 50dp label col)
                                    // Mirrors Android: prepend a leading spacer so time=0 lands under the
                                    // fixed center playhead when scrollOffset == 0.
                                    //
                                    // NOTE: previously this used SwiftUI's ScrollView + a GeometryReader/
                                    // PreferenceKey trick to read the scroll offset. That combo does not
                                    // reliably re-fire on every frame of an interactive drag (especially
                                    // nested inside another ScrollView), which is why the time readout and
                                    // ruler appeared frozen while the content visibly scrolled. Swapped for
                                    // a thin UIScrollView wrapper (TrackingHScrollView below), whose
                                    // scrollViewDidScroll fires every frame, guaranteed.
                                    let centerOffset = (geo.size.width - 50) / 2
                                    let effectivePPS = pixelsPerSecond * pinchScale
                                    // Content width tied to timeline.duration (same basis the ruler uses),
                                    // NOT to however wide the clips happen to be. This keeps the
                                    // scrollable range and the ruler in sync, and guarantees there's
                                    // always enough width to scroll to the actual end of the timeline.
                                    let trackContentWidth = max(geo.size.width - 50, CGFloat(timeline.duration) * effectivePPS)
                                    let scrollableContentWidth = trackContentWidth + centerOffset * 2
                                    let contentHeight = CGFloat(timeline.tracks.count + 1) * 100

                                    TrackingHScrollView(
                                        offset: Binding(
                                            get: { timelineScrollOffset },
                                            set: { newValue in
                                                // Raw contentOffset.x already lines up correctly with
                                                // time=0 at the fixed center playhead: the leading
                                                // centerOffset padding on the content does that job, so
                                                // no further +/- centerOffset adjustment belongs here.
                                                // (An earlier version of this code subtracted centerOffset,
                                                // which created a dead zone where the readout clamped to
                                                // 00:00 before the content had actually scrolled that far —
                                                // the playhead would sit inside the first clip instead of
                                                // at its left edge.)
                                                let clampedOffset = max(0, newValue)
                                                timelineScrollOffset = clampedOffset
                                                if !engine.isPlaying {
                                                    engine.scrub(to: Double(clampedOffset / effectivePPS))
                                                }
                                            }
                                        ),
                                        contentWidth: scrollableContentWidth,
                                        contentHeight: contentHeight,
                                        onDragBegin: {
                                            // Android equivalent: handleEditZoneInteraction's
                                            // ACTION_MOVE handler calling stopPlayback(true) the
                                            // instant the user starts dragging the timeline while
                                            // playing. Scrubbing takes over from playback rather
                                            // than being silently ignored.
                                            engine.pause()
                                        },
                                        onUserScroll: { rawOffset in
                                            // Android: pumpDecoderAudioSeek / desktop: requestAudioBurst.
                                            // Only fires for the user's own drag, so programmatic offset
                                            // syncs (playback, seeks after import) stay silent.
                                            engine.playScrubBurst(at: Double(max(0, rawOffset) / effectivePPS))
                                        },
                                        onUserScrollEnd: { engine.endScrub() },
                                        onLongPress: { phase, point in
                                            handleClipLongPress(phase, at: point, centerOffset: centerOffset, pps: effectivePPS)
                                        }
                                    ) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(timeline.tracks) { track in
                                                TrackRowView(
                                                    track: track,
                                                    isSelected: selectedTrackID == track.id,
                                                    selectedClipID: selectedClipID,
                                                    selectedClipIDs: selectedClipIDs,
                                                    pps: effectivePPS,
                                                    rowWidth: trackContentWidth,
                                                    timeline: timeline,
                                                    currentTime: Float(engine.currentTime),
                                                    draggingClipID: clipGhost?.clip.id,
                                                    media: ClipMediaContext(projectPath: project.projectPath,
                                                                            scrollOffset: timelineScrollOffset,
                                                                            viewportWidth: geo.size.width - 50,
                                                                            centerOffset: centerOffset),
                                                    onClipTap: { clip in selectingClip(clip) },
                                                    onTap: { selectingTrack(track) },
                                                    onClipMoved: { rebuildPreview() },
                                                    onClipDragBegin: { engine.pause() }
                                                )
                                            }
                                            // Blank spacer track — android:id="addNewTrackBlankTrackSpacer"
                                            Color(hex: "#222222")
                                                .frame(width: trackContentWidth, height: 100)
                                                .onTapGesture { addTrack() }
                                        }
                                        // Ghost lives in the same coordinate space as the rows (origin = time 0
                                        // of the track area), so it is positioned by time + track.
                                        .overlay(alignment: .topLeading) {
                                            if let ghost = clipGhost {
                                                ClipGhostView(ghost: ghost, pps: effectivePPS,
                                                              media: ClipMediaContext(projectPath: project.projectPath,
                                                                                      scrollOffset: timelineScrollOffset,
                                                                                      viewportWidth: geo.size.width - 50,
                                                                                      centerOffset: centerOffset))
                                            }
                                        }
                                        // ─── centerOffset leading + trailing padding ───────────────
                                        // Equivalent to Android's start/end spacer Views of width=centerOffset.
                                        // Leading padding means scrollOffset==0 puts time=0 at the center
                                        // playhead; matching trailing padding means you can keep scrolling
                                        // until the very end of the timeline reaches the center playhead too.
                                        .padding(.leading, centerOffset)
                                        .padding(.trailing, centerOffset)
                                    }
                                    .frame(width: geo.size.width - 50, height: contentHeight)
                                    .simultaneousGesture(
                                        MagnificationGesture()
                                            .updating($pinchScale) { currentState, gestureState, _ in
                                                gestureState = currentState
                                            }
                                            .onEnded { scale in
                                                let newScale = pixelsPerSecond * scale
                                                pixelsPerSecond = max(10, min(newScale, 800))
                                            }
                                    )
                                    .background(Color(hex: "#111111"))
                                }
                            }
                            // Android: timelineScroll.requestDisallowInterceptTouchEvent(true) for the
                            // duration of the drag, so vertical finger movement picks a track instead of
                            // scrolling the track list.
                            .scrollDisabled(clipGhost != nil)
                        }
                        // Overlay playhead on top of the whole timeline area.
                        // NOTE: alignment: .center here would center the line over the FULL
                        // width including the 50pt label column on the left — but the ruler
                        // and track content only occupy the area to the right of that column,
                        // whose true center is 50 + (trackAreaWidth / 2), not width / 2. That
                        // mismatch (25pt off with a 50pt column) was the playhead misalignment.
                        .overlay(
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 2)
                                .offset(x: 50 + (geo.size.width - 50) / 2)
                                .allowsHitTesting(false),
                            alignment: .leading
                        )
                    }
                    .frame(maxHeight: .infinity)
                    
                    // Editing Tools Zone (60dp) ──────────────────────────
                    // android:id="editingToolsZone" height=60dp, alignParentBottom
                    // Toolbar switches based on selection context
                        
                        if(!isPreview)
                        {
                            Group {
                                switch selectedToolbar {
                                case .default:
                                    DefaultToolbarView(
                                        onAddTrack: { addTrack() },
                                        onSplit: { splitAtPlayhead() }
                                    )
                                case .clip:
                                    ClipToolbarView(
                                        onDelete: { deleteSelectedClip() },
                                        onSplit: { splitSelectedClip() },
                                        onClone: { cloneSelectedClip() },
                                        onEdit: { openClipEditor() },
                                        onMultiToggle: { toggleMultiSelect() },
                                        onKeyframe: { addKeyframeToSelectedClip() },
                                        onAllKeyframe: { applyKeyframesToAllClips(selectedOnly: false) },
                                        onRestate: { restateSelectedClip() }
                                    )
                                case .track:
                                    TrackToolbarView(
                                        onAddMedia: { showFileImporter = true },
                                        onDeleteTrack: { deleteSelectedTrack() },
                                        onSplit: { splitAtPlayhead() },
                                        onAddText: { addTextClip() },
                                        onAddEffect: { addEffectClip() },
                                        onSelectAll: { selectAllInTrack() },
                                        onAutoSnap: { autoSnapTrack() }
                                    )
                                case .clips:
                                    ClipsToolbarView(
                                        onDelete: { deleteSelectedClips() },
                                        onClone: { cloneSelectedClips() },
                                        onMultiToggle: { toggleMultiSelect() },
                                        onAllKeyframe: { applyKeyframesToAllClips(selectedOnly: true) },
                                        onRestate: { restateSelectedClips() }
                                    )
                                }
                            }
                            .frame(height: 60)
                            .background(Color(hex: "#1A1A1A"))
                        }
                        
                }
                
                // Specific Edit Overlays (slides up over editingZone)
                if let overlayType = activeOverlay {
                    let selectedClip = timeline.tracks.flatMap({ $0.clips }).first(where: { $0.id == selectedClipID })
                    SpecificEditOverlay(
                        type: overlayType,
                        clip: selectedClip,
                        commandManager: commandManager,
                        playhead: Float(engine.currentTime),
                        frameRate: projectFrameRate,
                        onChanged: { rebuildPreview() }
                    ) {
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
            loadProjectFromDisk()   // must run first: setupPreview() adds a track to an EMPTY timeline
            setupPreview()
            setupTimelinePinchAndZoom()
            setupSpecificEdit()
            setupToolbars()
            handleEditZoneInteraction()
            if hasLoadedProject, !timeline.tracks.isEmpty { rebuildPreview(markDirty: false) }
        }
        .onDisappear {
            saveNow()
            engine.releaseAudio()
        }
        // Playback drives the ruler through engine.currentTime, but the track area is a
        // UIScrollView whose offset only ever came from the user's finger: while playing, the
        // ruler advanced and the clips stood still. Feed the playhead into the scroll offset
        // (same formula as scrubbing, inverted: offset = time * pixelsPerSecond).
        .onChange(of: engine.currentTime) { time in
            guard engine.isPlaying else { return }
            timelineScrollOffset = CGFloat(time) * (pixelsPerSecond * pinchScale)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { saveNow() }   // Android saves in onPause/onStop too
        }
        .alert("Project recovered", isPresented: Binding(get: { loadNote != nil }, set: { if !$0 { loadNote = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(loadNote ?? "")
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
        // Equivalent of Android's `selectingClip(Clip)`: while multi-select is on, a tap
        // toggles the clip in/out of `selectedClips` instead of replacing a single selection.
        if isMultiSelectMode {
            selectedClipID = nil
            if selectedClipIDs.contains(clip.id) {
                selectedClipIDs.remove(clip.id)
            } else {
                selectedClipIDs.insert(clip.id)
            }
        } else if selectedClipID == clip.id {
            selectedClipID = nil
        } else {
            selectedClipID = clip.id
            selectedTrackID = nil
        }
        updateToolbarState()
    }
    
    private func updateToolbarState() {
        if isMultiSelectMode {
            selectedToolbar = .clips
        } else if selectedClipID != nil {
            selectedToolbar = .clip
        } else if selectedTrackID != nil {
            selectedToolbar = .track
        } else {
            selectedToolbar = .default
        }
    }
    
    /// Equivalent of Android's `setClipSelectMultiple(!getClipSelectMultiple())`, which the
    /// "Multi" button on both the Clip and Clips toolbars calls to flip multi-select mode —
    /// converting the current single selection into the multi set, or vice-versa.
    private func toggleMultiSelect() {
        isMultiSelectMode.toggle()
        if isMultiSelectMode {
            if let id = selectedClipID {
                selectedClipIDs = [id]
                selectedClipID = nil
            }
        } else {
            selectedClipID = selectedClipIDs.first
            selectedClipIDs.removeAll()
        }
        updateToolbarState()
    }
    
    /// Rebuilds the AVPlayer composition so the preview reflects the timeline's current
    /// state — called after every structural edit (move/split/delete/clone/undo/redo),
    /// since none of those otherwise touch the player.
    private func rebuildPreview(markDirty: Bool = true) {
        engine.rebuildComposition(from: timeline, projectDir: URL(fileURLWithPath: project.projectPath))
        if markDirty { scheduleAutosave() }
    }
    
    // MARK: - Clip long-press drag (Android: handleClipInteraction)
    
    /// Returns whether the gesture should keep going: `.began` returns false when no clip is under
    /// the finger, so holding on empty space does nothing and never blocks scrolling.
    private func handleClipLongPress(_ phase: ClipLongPressPhase, at point: CGPoint,
                                     centerOffset: CGFloat, pps: CGFloat) -> Bool {
        switch phase {
        case .began:
            guard let ghost = ClipGhostMath.hitTest(point: point, timeline: timeline,
                                                    centerOffset: centerOffset, pps: pps) else { return false }
            engine.pause()                      // Android: stopPlayback when a clip drag starts
            clipGhost = ghost
            return true
            
        case .moved:
            guard let ghost = clipGhost else { return false }
            clipGhost = ClipGhostMath.moved(ghost, to: point, timeline: timeline, centerOffset: centerOffset,
                                            pps: pps, currentTime: Float(engine.currentTime))
            return true
            
        case .ended:
            guard let ghost = clipGhost else { return false }
            let final = ClipGhostMath.moved(ghost, to: point, timeline: timeline, centerOffset: centerOffset,
                                            pps: pps, currentTime: Float(engine.currentTime))
            if ClipGhostMath.commit(final, timeline: timeline, commandManager: commandManager,
                                    frameRate: projectFrameRate) {
                rebuildPreview()
            }
            clipGhost = nil
            return true
            
        case .cancelled:
            clipGhost = nil                     // nothing was ever applied to the clip
            return true
        }
    }
    
    // MARK: - Persistence (Android: Timeline.loadTimeline / saveTimeline)
    
    /// Read project.timeline + project.settings. Runs once; never in SwiftUI previews.
    private func loadProjectFromDisk() {
        guard !hasLoadedProject, !isPreview else { return }
        let result = TimelineStore.load(project: project)
        timeline.tracks = result.timeline.tracks
        timeline.duration = result.timeline.duration
        engine.settings = result.settings
        loadNote = result.recoveryNote
        // Only after this point may anything be written — an empty timeline can never
        // replace real data that simply hadn't been read yet.
        hasLoadedProject = true
    }
    
    /// Debounced: bursts of edits (slider drags, nudges) become a single write.
    private func scheduleAutosave() {
        guard hasLoadedProject, !isPreview else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    
    private func saveNow() {
        guard hasLoadedProject, !isPreview else { return }
        autosaveWork?.cancel()
        autosaveWork = nil
        do {
            try TimelineStore.save(project: project, timeline: timeline, settings: engine.settings)
        } catch {
            print("[Project] Timeline not saved (previous file left untouched): \(error)")
        }
    }
    
    private func performUndo() {
        commandManager.undo()
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func performRedo() {
        commandManager.redo()
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func allClips() -> [EditingView.Clip] {
        timeline.tracks.flatMap { $0.clips }
    }
    
    /// Duplicates `source`, placing the clone immediately after it on the same track —
    /// equivalent of Android's `new Clip(selectedClip)` + `cloneClip.startTime = ...`.
    private func makeClone(of source: EditingView.Clip) -> EditingView.Clip {
        let clone = source.copy()
        clone.startTime = source.startTime + source.duration
        return clone
    }
    
    // MARK: - Clip Toolbar Actions (single selection)
    
    private func deleteSelectedClip() {
        guard let id = selectedClipID, let clip = allClips().first(where: { $0.id == id }) else { return }
        commandManager.execute(DeleteClipCommand(timeline: timeline, clip: clip, onDeselect: {
            selectedClipID = nil
            updateToolbarState()
        }))
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func splitSelectedClip() {
        guard let id = selectedClipID, let clip = allClips().first(where: { $0.id == id }) else { return }
        let t = Float(engine.currentTime)
        // Matches Android's guard: `affectedClips.contains(selectedClip)` before splitting.
        guard t > clip.startTime && t < clip.startTime + clip.duration else { return }
        commandManager.execute(SplitClipCommand(timeline: timeline, clip: clip, globalSplitTime: t))
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func cloneSelectedClip() {
        guard let id = selectedClipID, let clip = allClips().first(where: { $0.id == id }) else { return }
        guard clip.trackIndex >= 0 && clip.trackIndex < timeline.tracks.count else { return }
        let track = timeline.tracks[clip.trackIndex]
        commandManager.execute(AddClipCommand(track: track, clip: makeClone(of: clip)))
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    // MARK: - Clip editing (ports of the Android toolbarClip / toolbarClips handlers)
    
    /// Frame rate from the project's `project.settings` (falls back to Android's default, 30).
    private var projectFrameRate: Int { max(engine.settings.frameRate, 1) }
    
    private var selectedClip: EditingView.Clip? {
        guard let id = selectedClipID else { return nil }
        return allClips().first(where: { $0.id == id })
    }
    
    /// editMediaButton: TEXT clips open the text editor, everything else the property editor.
    private func openClipEditor() {
        guard let clip = selectedClip else { return }
        withAnimation { activeOverlay = clip.type == .text ? .textEdit : .videoProperties }
    }
    
    /// addKeyframeButton
    private func addKeyframeToSelectedClip() {
        guard let clip = selectedClip else { return }
        let time = Float(engine.currentTime)
        let before = clip.keyframes
        let fps = projectFrameRate
        // Probe on a copy first so an out-of-range / duplicate press doesn't push a no-op undo entry.
        var probe = before
        let local = time - clip.startTime
        guard local >= 0, local <= clip.duration,
              !probe.keyframes.contains(where: { abs($0.time - local) <= EditingView.minimumKeyframeSpacing }) else { return }
        probe.keyframes.append(EditingView.Keyframe(time: local, value: clip.videoProperties, easing: .none))
        probe.sortKeyframes()
        probe.reassignKeyframes(frameRate: fps)
        let after = probe
        commandManager.execute(GenericCommand(
            description: "Add Keyframe: \(clip.clipName)",
            undo: { clip.keyframes = before },
            redo: { clip.keyframes = after }
        ))
        rebuildPreview()
    }
    
    /// applyKeyframeToAllClip — copy the current clip's keyframes onto every other clip
    /// (single-select) or onto the rest of the multi-selection (multi-select).
    private func applyKeyframesToAllClips(selectedOnly: Bool) {
        let source: EditingView.Clip?
        let targets: [EditingView.Clip]
        if selectedOnly {
            let picked = allClips().filter { selectedClipIDs.contains($0.id) }
            source = picked.first
            targets = Array(picked.dropFirst())
        } else {
            source = selectedClip
            targets = allClips().filter { $0.id != source?.id && ($0.type == .video || $0.type == .image || $0.type == .text) }
        }
        guard let source, !targets.isEmpty else { return }
        let sourceKeys = source.keyframes
        let batch = BatchCommand("Apply keyframes to all")
        for t in targets {
            let old = t.keyframes
            var new = sourceKeys
            // Keyframes are in local clip time; drop those beyond a shorter target clip.
            new.keyframes.removeAll { $0.time > t.duration }
            batch.add(GenericCommand(description: "Keyframes: \(t.clipName)", undo: { t.keyframes = old }, redo: { t.keyframes = new }))
        }
        commandManager.execute(batch)
        rebuildPreview()
    }
    
    /// restateButton — reset a clip's properties to defaults.
    private func restateSelectedClip() {
        guard let clip = selectedClip else { return }
        restate([clip])
    }
    
    private func restateSelectedClips() {
        restate(allClips().filter { selectedClipIDs.contains($0.id) })
    }
    
    private func restate(_ clips: [EditingView.Clip]) {
        guard !clips.isEmpty else { return }
        let batch = BatchCommand("Restate")
        for c in clips {
            let old = c.videoProperties
            batch.add(GenericCommand(description: "Restate: \(c.clipName)",
                                     undo: { c.videoProperties = old },
                                     redo: { c.videoProperties = EditingView.VideoProperties() }))
        }
        commandManager.execute(batch)
        rebuildPreview()
    }
    
    // MARK: - Clips Toolbar Actions (multi-select)
    
    private func deleteSelectedClips() {
        let clips = allClips().filter { selectedClipIDs.contains($0.id) }
        guard !clips.isEmpty else { return }
        let batch = BatchCommand("Delete Multiple Clips")
        for clip in clips { batch.add(DeleteClipCommand(timeline: timeline, clip: clip)) }
        commandManager.execute(batch)
        selectedClipIDs.removeAll()
        updateToolbarState()
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func cloneSelectedClips() {
        let clips = allClips().filter { selectedClipIDs.contains($0.id) }
        guard !clips.isEmpty else { return }
        let batch = BatchCommand("Clone Multiple Clips")
        for clip in clips where clip.trackIndex >= 0 && clip.trackIndex < timeline.tracks.count {
            let track = timeline.tracks[clip.trackIndex]
            batch.add(AddClipCommand(track: track, clip: makeClone(of: clip)))
        }
        commandManager.execute(batch)
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    // MARK: - Default / Track Toolbar Actions
    
    /// "Cut" on the Default toolbar and "Cut" on the Track toolbar both call this — Android
    /// wires both `toolbarDefault` and `toolbarTrack`'s `splitMediaButton` to the identical
    /// handler: split the selected clip if the playhead is over it, else split every clip
    /// the playhead intersects.
    private func splitAtPlayhead() {
        let t = Float(engine.currentTime)
        let affected = timeline.clipsAtCurrentTime(t)
        if let id = selectedClipID, let clip = affected.first(where: { $0.id == id }) {
            commandManager.execute(SplitClipCommand(timeline: timeline, clip: clip, globalSplitTime: t))
        } else if !affected.isEmpty {
            let batch = BatchCommand("Split Clips at Playhead")
            for clip in affected { batch.add(SplitClipCommand(timeline: timeline, clip: clip, globalSplitTime: t)) }
            commandManager.execute(batch)
        } else {
            return
        }
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func deleteSelectedTrack() {
        guard let id = selectedTrackID, let track = timeline.tracks.first(where: { $0.id == id }) else { return }
        timeline.removeTrack(track)
        selectedTrackID = nil
        updateToolbarState()
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    /// Equivalent of Android's `addTextButton` handler — adds a default "Simple text" clip
    /// to the selected track at the playhead. Preview compositing for text clips isn't
    /// implemented yet (that's the AVFoundation/Core Animation overlay work tracked
    /// separately), so the clip appears on the timeline but won't render in the player.
    private func addTextClip() {
        guard let id = selectedTrackID, let trackIndex = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        let clip = Clip(clipName: "TEXT", startTime: Float(engine.currentTime), duration: 3, trackIndex: trackIndex, type: .text, isClipHasAudio: false, width: 0, height: 0)
        clip.textContent = "Simple text"
        clip.fontSize = 30
        commandManager.execute(AddClipCommand(track: timeline.tracks[trackIndex], clip: clip))
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    /// Equivalent of Android's `addEffectButton` handler. As with text clips, this places
    /// an EFFECT clip on the timeline; it doesn't yet composite into the preview.
    private func addEffectClip() {
        guard let id = selectedTrackID, let trackIndex = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        let clip = Clip(clipName: "EFFECT", startTime: Float(engine.currentTime), duration: 3, trackIndex: trackIndex, type: .effect, isClipHasAudio: false, width: 0, height: 0)
        clip.effect = EffectTemplate(type: nil, style: "glitch-pulse", duration: 1.2, offset: 4.0)
        commandManager.execute(AddClipCommand(track: timeline.tracks[trackIndex], clip: clip))
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    /// Equivalent of Android's `selectAllButton` — enters multi-select and selects every
    /// clip on the currently-selected track.
    private func selectAllInTrack() {
        guard let id = selectedTrackID, let track = timeline.tracks.first(where: { $0.id == id }) else { return }
        isMultiSelectMode = true
        selectedClipID = nil
        selectedClipIDs = Set(track.clips.map { $0.id })
        updateToolbarState()
    }
    
    /// Equivalent of Android's `autoSnapButton` — lines clips up back-to-back in start-time
    /// order, removing gaps and overlaps within the selected track.
    private func autoSnapTrack() {
        guard let id = selectedTrackID, let track = timeline.tracks.first(where: { $0.id == id }) else { return }
        track.sortClips()
        guard track.clips.count > 1 else { return }
        for i in 1..<track.clips.count {
            let prev = track.clips[i - 1]
            track.clips[i].startTime = prev.startTime + prev.duration
        }
        timeline.recalculateDuration()
        rebuildPreview()
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let trackID = selectedTrackID,
              let trackIndex = timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    // NOTE: startAccessingSecurityScopedResource() returning false does NOT
                    // always mean access failed - it can simply mean the resource doesn't
                    // require scoping. Gating on it here caused every imported file to be
                    // silently skipped. We still track it so we only stop what we started.
                    let didStartAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    let filename = url.lastPathComponent
                    let ext = url.pathExtension.lowercased()
                    let isImage = ["png", "jpg", "jpeg"].contains(ext)
                    
                    let clipDir = IOHelper.combinePath(project.projectPath, Constants.DEFAULT_CLIP_DIRECTORY)
                    IOHelper.createEmptyDirectories(clipDir)
                    let targetPath = IOHelper.combinePath(clipDir, filename)
                    let targetUrl = URL(fileURLWithPath: targetPath)
                    
                    if !FileManager.default.fileExists(atPath: targetPath) {
                        do {
                            try FileManager.default.copyItem(at: url, to: targetUrl)
                        } catch {
                            print("File copy error: \(error)")
                            continue
                        }
                    }
                    
                    var durationSeconds: Float = 3.0
                    var trackWidth: Int = 1920
                    var trackHeight: Int = 1080
                    var hasAudio = false
                    
                    if isImage {
                        durationSeconds = 3.0
                    } else {
                        let asset = AVURLAsset(url: targetUrl)
                        if #available(iOS 15.0, *) {
                            if let duration = try? await asset.load(.duration) {
                                durationSeconds = Float(duration.seconds)
                            }
                            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                               let size = try? await videoTrack.load(.naturalSize) {
                                // naturalSize ignores the rotation flag: portrait iPhone video would be
                                // stored sideways (and composited squashed). Apply preferredTransform.
                                let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                                let oriented = size.applying(transform)
                                trackWidth = Int(abs(oriented.width))
                                trackHeight = Int(abs(oriented.height))
                            }
                            if let _ = try? await asset.loadTracks(withMediaType: .audio).first {
                                hasAudio = true
                            }
                        } else {
                            durationSeconds = Float(asset.duration.seconds)
                            if let videoTrack = asset.tracks(withMediaType: .video).first {
                                let oriented = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
                                trackWidth = Int(abs(oriented.width))
                                trackHeight = Int(abs(oriented.height))
                            }
                            hasAudio = asset.tracks(withMediaType: .audio).first != nil
                        }
                    }
                    
                    let finalDuration = max(0.5, durationSeconds) // Guard against 0 duration
                    let type: EditingView.ClipType = isImage ? .image : .video

                    await MainActor.run {
                        let newClip = Clip(
                            clipName: filename,
                            startTime: Float(engine.currentTime),
                            duration: Float(finalDuration),
                            trackIndex: trackIndex,
                            type: type,
                            isClipHasAudio: hasAudio,
                            width: trackWidth,
                            height: trackHeight
                        )
                        timeline.tracks[trackIndex].clips.append(newClip)
                        engine.seek(to: engine.currentTime + Double(finalDuration))
                        // Recompute from actual clip end times (max of startTime + duration
                        // across every track), matching Android's Track.getTrackEndTime() /
                        // Timeline.recalculateDuration() — NOT the old placeholder, which only
                        // tracked how far the playhead had moved and had no real relationship
                        // to where clips actually end.
                        timeline.recalculateDuration()
                    }
                }
                
                await MainActor.run {
                    rebuildPreview()
                }
            }
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

// MARK: - Tracking Horizontal ScrollView

/// A UIScrollView-backed horizontal scroll wrapper.
///
/// SwiftUI's `ScrollView` + a `GeometryReader`/`PreferenceKey` in `.background()` is a common
/// trick for reading scroll offset, but it does not reliably re-run on every frame of an
/// interactive drag — especially when nested inside another ScrollView, as the timeline is here
/// (vertical ScrollView containing this horizontal one). That gap is what caused the time
/// readout and ruler to look frozen while the timeline content visibly scrolled: the content
/// moved via the ScrollView's own rendering, but `offset` (and therefore `engine.currentTime`)
/// never got updated to match.
///
/// `UIScrollView.scrollViewDidScroll(_:)` fires on every scroll frame, guaranteed, so driving
/// the offset binding from there keeps the ruler/readout in sync with the actual scroll position.
struct TrackingHScrollView<Content: View>: UIViewRepresentable {
    @Binding var offset: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// Fired from `scrollViewWillBeginDragging`, which UIKit calls only for a genuine
    /// user touch-drag — never for the programmatic `contentOffset.x` writes this same
    /// view makes in `updateUIView`. Safe hook for "user grabbed the timeline" logic
    /// (e.g. pausing playback) without misfiring on our own scroll-syncing.
    var onDragBegin: (() -> Void)? = nil
    /// Raw contentOffset.x on every scroll frame that comes from the user's finger (dragging or
    /// the deceleration after a flick) — never for our own programmatic offset writes.
    var onUserScroll: ((CGFloat) -> Void)? = nil
    /// The finger lifted and any flick deceleration finished.
    var onUserScrollEnd: (() -> Void)? = nil
    /// Long press anywhere on the content, in CONTENT coordinates. For `.began` the return value
    /// decides whether the gesture may begin (false = nothing to drag here); for the other phases
    /// it is ignored.
    var onLongPress: ((ClipLongPressPhase, CGPoint) -> Bool)? = nil
    let content: Content

    init(offset: Binding<CGFloat>, contentWidth: CGFloat, contentHeight: CGFloat, onDragBegin: (() -> Void)? = nil, onUserScroll: ((CGFloat) -> Void)? = nil, onUserScrollEnd: (() -> Void)? = nil, onLongPress: ((ClipLongPressPhase, CGPoint) -> Bool)? = nil, @ViewBuilder content: () -> Content) {
        self._offset = offset
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.onDragBegin = onDragBegin
        self.onUserScroll = onUserScroll
        self.onUserScrollEnd = onUserScrollEnd
        self.onLongPress = onLongPress
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear

        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        scrollView.addSubview(hosting.view)
        context.coordinator.hostingController = hosting
        
        // Long press = pick up a clip. Moving before it fires (scrubbing) fails it and the
        // scroll view takes the touch as usual — that is what keeps scrubbing from grabbing clips.
        let longPress = UILongPressGestureRecognizer(target: context.coordinator.longPressHandler,
                                                     action: #selector(ClipLongPressHandler.handle(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = 10
        // Once it fires, the content (SwiftUI tap/trim gestures) must not also see the touch,
        // otherwise releasing the drag could also "tap" a clip.
        longPress.cancelsTouchesInView = true
        longPress.delegate = context.coordinator.longPressHandler
        scrollView.addGestureRecognizer(longPress)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.longPressHandler.onLongPress = onLongPress
        context.coordinator.hostingController?.rootView = content

        let size = CGSize(width: contentWidth, height: contentHeight)
        context.coordinator.hostingController?.view.frame = CGRect(origin: .zero, size: size)
        if uiView.contentSize != size {
            uiView.contentSize = size
        }
        // Only push programmatic changes (e.g. playback-driven seeks) into the UIScrollView;
        // avoid fighting the user's own finger during an active drag.
        if abs(uiView.contentOffset.x - offset) > 0.5 {
            uiView.contentOffset.x = offset
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: TrackingHScrollView
        var hostingController: UIHostingController<Content>?
        /// Non-generic on purpose: @objc selectors inside a class nested in a generic type are fragile.
        let longPressHandler = ClipLongPressHandler()
        init(_ parent: TrackingHScrollView) { self.parent = parent }

        private var isUserScrolling = false
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            parent.onDragBegin?()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                isUserScrolling = false
                parent.onUserScrollEnd?()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserScrolling = false
            parent.onUserScrollEnd?()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let newOffset = scrollView.contentOffset.x
            if isUserScrolling { parent.onUserScroll?(newOffset) }
            DispatchQueue.main.async {
                self.parent.offset = newOffset
            }
        }
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
    var selectedClipIDs: Set<UUID> = []
    var pps: CGFloat
    /// Full scrollable width of the timeline (tied to timeline.duration), NOT just
    /// however wide this track's clips happen to be. Without this, each row's
    /// background/scroll-content only extends as far as its own clips, so the
    /// ScrollView runs out of content to scroll through well before the ruler's
    /// actual end — this is what caused scrolling to get "blocked halfway".
    var rowWidth: CGFloat
    /// Needed by ClipBlockView for whole-clip move: snapping looks at sibling clips
    /// across the whole timeline, and cross-track drops need every track to reassign into.
    @ObservedObject var timeline: EditingView.Timeline
    var currentTime: Float
    var trackRowHeight: CGFloat = 100
    /// The clip whose ghost is being dragged: its real block is hidden meanwhile (Android: INVISIBLE).
    var draggingClipID: UUID? = nil
    /// Project path + scroll window: lets each block build only the thumbnails/bars on screen.
    var media: ClipMediaContext = .empty
    
    var onClipTap: (EditingView.Clip) -> Void
    var onTap: () -> Void
    /// Fired after a move/resize commits — parent uses this to rebuild the preview.
    var onClipMoved: () -> Void = {}
    /// Fired the instant a whole-clip move drag begins — parent pauses playback,
    /// matching the timeline-scroll drag's same behavior.
    var onClipDragBegin: () -> Void = {}
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: isSelected ? "#333333" : "#1A1A1A")
            // Absolute positioning by startTime — NOT an HStack. An HStack packs
            // clips left-to-right in array order with a fixed gap, which silently
            // ignores clip.startTime; it only looked right when there happened to
            // be a single clip starting at 0. Real (loaded, or multi-clip) data
            // needs each block placed at its actual time, including gaps, exactly
            // like Android's clipView.setX(getTimeInX(data.startTime)).
            ForEach(track.clips) { clip in
                ClipBlockView(
                    clip: clip,
                    timeline: timeline,
                    isSelected: selectedClipID == clip.id,
                    isMultiSelected: selectedClipIDs.contains(clip.id),
                    isGhostSource: draggingClipID == clip.id,
                    media: media,
                    pps: pps,
                    currentTime: currentTime,
                    trackRowHeight: trackRowHeight,
                    onMoved: onClipMoved,
                    onDragBegin: onClipDragBegin
                )
                // Vertical inset centers the 88pt-tall block in the 100pt row,
                // matching the HStack's previous default .center alignment.
                .offset(x: CGFloat(clip.startTime) * pps, y: 6)
                .onTapGesture {
                    onClipTap(clip)
                }
            }
        }
        .frame(width: rowWidth, height: 100, alignment: .leading)
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
    /// Needed for whole-clip move: snapping against sibling clips, and reassigning
    /// tracks on drop. Equivalent of Android's access to the shared `timeline` field
    /// from inside `handleClipInteraction`.
    @ObservedObject var timeline: EditingView.Timeline
    var isSelected: Bool
    var isMultiSelected: Bool = false
    /// True while this clip's ghost is being dragged: the block stays in layout but is invisible.
    var isGhostSource: Bool = false
    var media: ClipMediaContext = .empty
    var pps: CGFloat
    var currentTime: Float
    var trackRowHeight: CGFloat = 100
    /// Fired once a move/resize commits, so the parent can rebuild the preview.
    var onMoved: () -> Void = {}
    /// Fired the instant a whole-clip move drag begins (not on trim-handle drags),
    /// matching Android's `stopPlayback` call the moment a clip drag starts.
    var onDragBegin: () -> Void = {}
    
    @State private var dragInitialDuration: Float = 0
    @State private var dragInitialStartTime: Float = 0
    @State private var dragInitialStartTrim: Float = 0
    @State private var dragInitialEndTrim: Float = 0
    
    // Derived values for the clip block
    var blockWidth: CGFloat {
        max(20, CGFloat(clip.duration) * pps)
    }
    
    private var hasMediaVisual: Bool {
        !media.projectPath.isEmpty && (clip.type == .video || clip.type == .image || clip.type == .audio)
    }
    
    private var borderColor: Color {
        if isMultiSelected { return .orange }
        if isSelected { return .white }
        return .clear
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.mdPrimary.opacity(0.8))
            
            // Video/image: tile strip. Audio: waveform. Others: nothing (the plain fill above).
            ClipVisualContent(clip: clip, displayStartTime: clip.startTime, pps: pps,
                              blockWidth: blockWidth, height: 88, media: media)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            
            // Over thumbnails/waveforms the label sits top-left on a soft shadow so it stays readable.
            Text(clip.clipName)
                .font(.system(size: 10, weight: hasMediaVisual ? .semibold : .regular))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(hasMediaVisual ? 0.85 : 0), radius: 2)
                .lineLimit(1)
                .padding(.horizontal, hasMediaVisual ? 6 : 16)
                .padding(.top, hasMediaVisual ? 4 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: hasMediaVisual ? .topLeading : .leading)
            
            if isSelected || isMultiSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 2)
            }
            
            // Trim handles — only for a true single selection, and hidden mid-move
            // (Android: `dragContext.clip.toggleHandlesVisibility(false)` on ACTION_MOVE
            // of the clip body, restored on ACTION_UP).
            if isSelected && !isMultiSelected && !isGhostSource {
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
                            .onEnded { _ in
                                dragInitialDuration = 0
                                onMoved()
                            }
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
                            .onEnded { _ in
                                dragInitialDuration = 0
                                onMoved()
                            }
                    )
                }
            }
        }
        .frame(width: blockWidth, height: 88)
        .clipped()
        // No drag gesture here on purpose: a plain touch on a clip is a tap (select) or the start of a
        // timeline scrub. Moving a clip is a long-press + ghost, handled at the scroll-view level.
        .opacity(isGhostSource ? 0 : 1)
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
/// Android buttons: addTrackButton, splitMediaButton, projectFilesViewerButton, importTrackButton.
/// Files/Import stay no-ops here — they open screens (Project Files viewer, track import)
/// that are a separate piece of work from clip editing.
private struct DefaultToolbarView: View {
    var onAddTrack: () -> Void = {}
    var onSplit: () -> Void = {}
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "rectangle.stack.badge.plus", label: "Add Track") { onAddTrack() }
                ToolbarButton(icon: "scissors", label: "Cut") { onSplit() }
                ToolbarButton(icon: "folder", label: "Files") {}
                ToolbarButton(icon: "square.and.arrow.down", label: "Import") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Clip toolbar — view_toolbar_clip.xml
/// Buttons: Delete, Split, Clone, Edit, Keyframe, SelectMultiple, AllKeyframe, Restate, Export.
/// Export stays a no-op — clip export is separate work.
private struct ClipToolbarView: View {
    var onDelete: () -> Void = {}
    var onSplit: () -> Void = {}
    var onClone: () -> Void = {}
    var onEdit: () -> Void = {}
    var onMultiToggle: () -> Void = {}
    var onKeyframe: () -> Void = {}
    var onAllKeyframe: () -> Void = {}
    var onRestate: () -> Void = {}
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") { onDelete() }
                ToolbarButton(icon: "scissors", label: "Split") { onSplit() }
                ToolbarButton(icon: "doc.on.doc", label: "Clone") { onClone() }
                ToolbarButton(icon: "pencil.and.outline", label: "Edit") { onEdit() }
                ToolbarButton(icon: "diamond", label: "Keyframe") { onKeyframe() }
                ToolbarButton(icon: "list.bullet", label: "Multi") { onMultiToggle() }
                ToolbarButton(icon: "arrow.triangle.merge", label: "AllKey") { onAllKeyframe() }
                ToolbarButton(icon: "arrow.counterclockwise", label: "Restate") { onRestate() }
                ToolbarButton(icon: "square.and.arrow.up", label: "Export") {}
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Track toolbar — view_toolbar_track.xml
/// Android buttons: addMediaButton, deleteTrackButton, splitMediaButton, addTextButton,
/// addEffectButton, selectAllButton, autoSnapButton, importClipButton, exportTrackButton.
/// Import/Export clip stay no-ops here.
private struct TrackToolbarView: View {
    var onAddMedia: () -> Void
    var onDeleteTrack: () -> Void = {}
    var onSplit: () -> Void = {}
    var onAddText: () -> Void = {}
    var onAddEffect: () -> Void = {}
    var onSelectAll: () -> Void = {}
    var onAutoSnap: () -> Void = {}
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "photo.badge.plus", label: "Add media") { onAddMedia() }
                ToolbarButton(icon: "trash", label: "Delete") { onDeleteTrack() }
                ToolbarButton(icon: "scissors", label: "Cut") { onSplit() }
                ToolbarButton(icon: "textformat", label: "Text") { onAddText() }
                ToolbarButton(icon: "wand.and.stars", label: "Effect") { onAddEffect() }
                ToolbarButton(icon: "checklist", label: "Select All") { onSelectAll() }
                ToolbarButton(icon: "arrow.left.and.line.vertical.and.arrow.right", label: "Auto-snap") { onAutoSnap() }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Clips (multi-select) toolbar — view_toolbar_clips.xml
/// Android buttons: deleteMediaButton, cloneMediaButton, editMediaButton, selectMultipleButton,
/// applyKeyframeToAllClip, restateButton. Edit/AllKeyframe/Restate for a multi-selection stay
/// no-ops here (batch keyframe UI is separate work); "Done" exits multi-select mode.
private struct ClipsToolbarView: View {
    var onDelete: () -> Void = {}
    var onClone: () -> Void = {}
    var onMultiToggle: () -> Void = {}
    var onAllKeyframe: () -> Void = {}
    var onRestate: () -> Void = {}
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ToolbarButton(icon: "trash", label: "Delete") { onDelete() }
                ToolbarButton(icon: "doc.on.doc", label: "Clone") { onClone() }
                ToolbarButton(icon: "arrow.triangle.merge", label: "AllKey") { onAllKeyframe() }
                ToolbarButton(icon: "arrow.counterclockwise", label: "Restate") { onRestate() }
                ToolbarButton(icon: "checkmark.circle", label: "Done") { onMultiToggle() }
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
    ), isPreview: false)
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// PreferenceKey for tracking the horizontal scroll offset of the timeline track area.
/// Reported as a positive offset (pixels scrolled from leading edge).
/// Used to derive currentTime = scrollOffset / pixelsPerSecond — matching the Android formula.
private struct TimelineScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
