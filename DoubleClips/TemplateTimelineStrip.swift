import SwiftUI
import AVFoundation
import Combine

// MARK: - The preview timeline of a template
//
// A strip of the template's clips (EditingView-style: time runs left to right, tracks are rows)
// that slides under a fixed RED PLAYHEAD as the preview video plays, and can be dragged to scrub it.

struct TemplateTimelineStrip: View {
    let info: TemplateTimelineInfo
    /// Seconds into the preview video.
    let currentTime: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void
    
    @State private var dragStartTime: Double?
    
    private var pps: CGFloat { Constants.TEMPLATE_STRIP_POINTS_PER_SECOND }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Legend: only the roles this template uses.
                ForEach(info.roles, id: \.self) { role in
                    HStack(spacing: 4) {
                        Circle().fill(role.color).frame(width: 8, height: 8)
                        Text(role.title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    }
                }
                Spacer(minLength: 4)
                Text("\(format(currentTime)) / \(format(info.duration))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            .shadow(radius: 1)
            
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let rows = max(info.rowCount, 1)
                let gap: CGFloat = 2
                let rowHeight = min(max((height - 8 - CGFloat(rows - 1) * gap) / CGFloat(rows), 5), 18)
                
                ZStack(alignment: .topLeading) {
                    // The clips, shifted so the current time sits under the playhead.
                    ZStack(alignment: .topLeading) {
                        ForEach(info.clips) { clip in
                            clipView(clip, rowHeight: rowHeight)
                                .offset(x: CGFloat(clip.start) * pps,
                                        y: 4 + CGFloat(clip.row) * (rowHeight + gap))
                        }
                    }
                    .frame(width: max(CGFloat(info.duration) * pps, 1), height: height, alignment: .topLeading)
                    .offset(x: width / 2 - CGFloat(currentTime) * pps)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped()
                .overlay(alignment: .center) { playhead(height: height) }
            }
            .frame(height: Constants.TEMPLATE_STRIP_HEIGHT)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStartTime == nil { dragStartTime = currentTime }
                        let time = (dragStartTime ?? currentTime) - Double(value.translation.width / pps)
                        onScrub(min(max(time, 0), info.duration))
                    }
                    .onEnded { _ in
                        dragStartTime = nil
                        onScrubEnd()
                    }
            )
        }
    }
    
    private func clipView(_ clip: TemplateStripClip, rowHeight: CGFloat) -> some View {
        let w = max(CGFloat(clip.duration) * pps, 3)
        return RoundedRectangle(cornerRadius: 3)
            .fill(clip.role.color.opacity(clip.role == .replaceable ? 0.95 : 0.85))
            .frame(width: max(w - 1, 2), height: rowHeight)
            .overlay {
                if let number = clip.slotNumber, w >= 14, rowHeight >= 9 {
                    Text("\(number)")
                        .font(.system(size: min(rowHeight - 2, 11), weight: .heavy))
                        .foregroundColor(.black.opacity(0.75))
                }
            }
    }
    
    /// The red playhead: a line across the strip with a small head.
    private func playhead(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 2, height: height)
            Circle().fill(Color.red).frame(width: 8, height: 8).offset(y: -2)
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
    
    private func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - The preview video

/// The template's preview video, with the clock the strip follows. One per preview page; it only holds
/// a video while its page is the one on screen.
final class TemplatePreviewPlayer: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var hasVideo = false
    
    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedURL: URL?
    private var scrubbing = false
    private var resumeAfterScrub = false
    
    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self, !self.scrubbing else { return }
            self.currentTime = max(0, time.seconds)
            if let item = self.player.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0, abs(d - self.duration) > 0.01 { self.duration = d }
            }
            self.isPlaying = self.player.timeControlStatus != .paused
        }
    }
    
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
    
    /// This page became the visible one: load the video and start it.
    func activate(_ url: URL) {
        if loadedURL != url {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            loadedURL = url
            hasVideo = true
            currentTime = 0
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.player.seek(to: .zero)
                    self?.player.play()
                }
        }
        // Audio even in silent mode, like the old preview player.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        play()
    }
    
    /// The page was scrolled away: stop and let go of the video.
    func deactivate() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        loadedURL = nil
        hasVideo = false
        isPlaying = false
        currentTime = 0
    }
    
    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    
    // MARK: Scrubbing (dragging the strip)
    
    func scrub(to seconds: Double) {
        if !scrubbing {
            scrubbing = true
            resumeAfterScrub = isPlaying
            player.pause()
        }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func endScrub() {
        scrubbing = false
        if resumeAfterScrub { play() } else { isPlaying = false }
    }
}

/// Shows an AVPlayer, fitted inside its bounds (letterboxed) like the old preview.
struct TemplatePlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    
    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    
    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

// MARK: - iOS 26 scroll edge effect

extension View {
    /// iOS 26 softens (blurs and fades) the edges of every scroll view. The template pages are a rotated
    /// paging TabView, so the effect showed up as a blurred band down the screen's right side. Turn it off.
    @ViewBuilder
    func hidingScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// A zero-size view that, once it is on screen, finds the scroll views it sits in (the paging TabView's) and
/// turns off their iOS 26 edge effects. SwiftUI's `scrollEdgeEffectHidden` doesn't reach the UIKit scroll view
/// behind a paging TabView, so this does it directly.
struct ScrollEdgeEffectProbe: UIViewRepresentable {
    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI has finished putting the pages into the scroll view.
            DispatchQueue.main.async { [weak self] in self?.hideEdgeEffects() }
        }
        
        private func hideEdgeEffects() {
            guard #available(iOS 26.0, *) else { return }
            var view: UIView? = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    scroll.topEdgeEffect.isHidden = true
                    scroll.bottomEdgeEffect.isHidden = true
                    scroll.leftEdgeEffect.isHidden = true
                    scroll.rightEdgeEffect.isHidden = true
                }
                view = current.superview
            }
        }
    }
    
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }
    
    func updateUIView(_ uiView: ProbeView, context: Context) {}
}
