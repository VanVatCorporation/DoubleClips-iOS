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
                self.currentTime = time.seconds
                
                // If the player stopped but we aren't at the end, or if we reached the end
                if self.player.timeControlStatus != .playing {
                    self.isPlaying = false
                } else {
                    self.isPlaying = true
                }
            }
        }
        
        func seek(to seconds: Double) {
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            self.currentTime = seconds
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
