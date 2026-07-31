import Foundation
import AVFoundation
import CoreMedia
import SwiftUI
import AVKit
import Combine

extension EditingView {
    
    // MARK: - Playback Engine (Android ClipRenderer equivalent)
    
    class EditingPlayer: ObservableObject {
        @Published var player: AVPlayer = AVPlayer()
        @Published var isPlaying: Bool = false
        @Published var currentTime: Double = 0.0
        
        private var timeObserverToken: Any?
        private var currentComposition: AVMutableComposition?
        
        init() {
            setupTimeObserver()
        }
        
        deinit {
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
            }
        }
        
        func togglePlayPause() {
            if player.timeControlStatus == .playing {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
        }
        
        private func setupTimeObserver() {
            let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                
                // Only trust the player's own reported time while actually playing.
                // While paused/scrubbing, `currentTime` is driven manually by seek(to:)
                // from timeline scrolling — letting this observer overwrite it every
                // 50ms fought that, making the ruler/readout appear frozen no matter
                // how far you scrolled.
                if self.player.timeControlStatus == .playing {
                    self.currentTime = time.seconds
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
            }
        }
        
        func seek(to seconds: Double) {
            // Update immediately so the ruler/readout track scrolling in real time,
            // independent of how long the underlying AVPlayer seek takes.
            self.currentTime = seconds
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            // A small tolerance lets AVPlayer coalesce rapid successive seek calls
            // (many per second while scrubbing/scrolling) instead of each one
            // cancelling the last and never letting the player's time settle.
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        
        /// Rebuilds the AVPlayerItem composition when timeline changes.
        /// This mimics Android's ClipRenderer pipeline.
        func rebuildComposition(from timeline: EditingView.Timeline, projectDir: URL) {
            let composition = AVMutableComposition()
            
            // We use simple iteration to build tracks mapping strictly to user's timeline
            for trackModel in timeline.tracks.sorted(by: { $0.timelineIndex < $1.timelineIndex }) {
                
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                
                for clip in trackModel.clips {
                    guard clip.type == .video || clip.type == .image || clip.type == .audio else { continue }
                    
                    let clipURL = projectDir.appendingPathComponent(clip.clipName)
                    let asset = AVAsset(url: clipURL)
                    
                    let targetRange = CMTimeRange(
                        start: CMTime(seconds: Double(clip.startTime), preferredTimescale: 600),
                        duration: CMTime(seconds: Double(clip.duration), preferredTimescale: 600)
                    )
                    
                    let sourceRange = CMTimeRange(
                        start: CMTime(seconds: Double(clip.startClipTrim), preferredTimescale: 600),
                        duration: CMTime(seconds: Double(clip.duration), preferredTimescale: 600)
                    )
                    
                    if let videoTrack = asset.tracks(withMediaType: .video).first, clip.type == .video {
                        try? compositionVideoTrack?.insertTimeRange(sourceRange, of: videoTrack, at: targetRange.start)
                    }
                    
                    if clip.isClipHasAudio && !clip.isMute {
                        if let audioTrack = asset.tracks(withMediaType: .audio).first {
                            try? compositionAudioTrack?.insertTimeRange(sourceRange, of: audioTrack, at: targetRange.start)
                        }
                    }
                }
            }
            
            self.currentComposition = composition
            let playerItem = AVPlayerItem(asset: composition)
            player.replaceCurrentItem(with: playerItem)
            
            // Prevent auto-play explicitly
            player.pause()
            isPlaying = false
        }
    }
}
