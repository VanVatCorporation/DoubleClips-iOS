import SwiftUI
import AVKit

struct VideoPlayerView: UIViewControllerRepresentable {
    var url: URL
    @Binding var isPlaying: Bool
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // Create Player
        let player = AVPlayer(url: url)
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        
        // Enable Audio (Even in silent mode)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session: \(error)")
        }
        
        // Loop video
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if isPlaying {
            uiViewController.player?.play()
        } else {
            uiViewController.player?.pause()
        }
        
    }
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}
