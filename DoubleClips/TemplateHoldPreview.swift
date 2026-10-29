import SwiftUI
import AVFoundation
import Combine

// MARK: - Long-press preview of a template card (Templates / Search / Profile lists)
//
// The same idea as the Home tab's project card: hold a template and a card floats up with
//   - the template's video, playing muted on a loop (the snapshot shows until the first frame is ready),
//   - its title and author,
//   - how many people liked it, bookmarked it and used it.
// It never touches the audio session (a muted preview must not interrupt the music the person is playing)
// and it only holds a video while the card is on screen.

final class TemplateHoldPlayer: ObservableObject {
    @Published private(set) var isReady = false
    let player = AVPlayer()
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    
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
        player.replaceCurrentItem(with: item)
        player.play()
    }
    
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isReady = false
    }
}

struct TemplateHoldPreview: View {
    let template: TemplateData
    @StateObject private var hold = TemplateHoldPlayer()
    
    private let cardWidth: CGFloat = 320
    private let videoHeight: CGFloat = 400
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
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
            }
            .frame(width: cardWidth, height: videoHeight)
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: hold.isReady)
            
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
