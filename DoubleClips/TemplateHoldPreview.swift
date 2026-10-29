import SwiftUI
import AVFoundation
import Combine

// MARK: - Long-press preview of a template card (Templates / Search / Profile lists)
//
// The same idea as the Home tab's project card: hold a template and a card floats up with
//   - the template's video, playing on a loop with its sound (the snapshot shows until the first frame is ready),
//   - the template's timeline along the bottom of the video: the very same `TemplateTimelineStrip` the full preview
//     page draws (clips by role under a red playhead), fed by the same cached `TemplateTimelineLoader`,
//   - its title and author,
//   - how many people liked it, bookmarked it and used it.
// The player is a plain AVPlayer, like the preview page's: it doesn't set up an audio session of its own,
// and it only holds a video while the card is on screen. The card isn't interactive, so the strip doesn't scrub.

/// A looping player for the hold preview. `currentTime` follows the video so the timeline strip can move with it.
final class TemplateHoldPlayer: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var currentTime: Double = 0
    let player = AVPlayer()
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    
    init() {
        player.actionAtItemEnd = .none
    }
    
    deinit { stop() }
    
    func start(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .readyToPlay { self?.isReady = true }
            }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            let seconds = time.seconds
            if seconds.isFinite { self?.currentTime = seconds }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }
    
    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isReady = false
        currentTime = 0
    }
}

struct TemplateHoldPreview: View {
    let template: TemplateData
    @StateObject private var hold = TemplateHoldPlayer()
    /// The template's timeline (nil until loaded; stays nil for an old template without one, or when it can't be loaded).
    @State private var timelineInfo: TemplateTimelineInfo?
    
    private let cardWidth: CGFloat = 320
    private let videoHeight: CGFloat = 400
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.black
                // The snapshot is what you see until the video has a first frame (or when it never loads).
                AsyncImage(url: URL(string: template.templateSnapshotLink)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                if hold.isReady {
                    TemplatePlayerLayerView(player: hold.player)
                        .transition(.opacity)
                }
                
                // The same strip as the preview page, over the bottom of the video.
                if let info = timelineInfo, !info.clips.isEmpty {
                    TemplateTimelineStrip(info: info, currentTime: hold.currentTime,
                                          onScrub: { _ in }, onScrubEnd: { })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: cardWidth, height: videoHeight)
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: hold.isReady)
            .animation(.easeInOut(duration: 0.2), value: timelineInfo != nil)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: template.templateTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(verbatim: "@" + template.templateAuthor)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 18) {
                    stat("heart.fill", template.heartCount)
                    stat("bookmark.fill", template.bookmarkCount)
                    stat("square.on.square.fill", template.useCount)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(width: cardWidth, alignment: .leading)
            .background(Color.mdSurfaceContainerHigh)
        }
        .frame(width: cardWidth)
        .onAppear {
            if let url = URL(string: template.templateVideoLink), !template.templateVideoLink.isEmpty { hold.start(url) }
        }
        .onDisappear { hold.stop() }
        // From the same on-disk cache the preview page uses: a template opened before shows its timeline at once.
        .task {
            guard !template.templateTimelineLink.isEmpty else { return }
            timelineInfo = try? await TemplateTimelineLoader.load(for: template)
        }
    }
    
    private func stat(_ icon: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(.secondary)
            Text(verbatim: Self.compact(count)).font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
    }
    
    /// 1234 -> 1.2k, 2_500_000 -> 2.5M (the same shortening the card's own counters use).
    private static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
