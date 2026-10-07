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
        
        /// Project resolution / frame rate, refreshed on every rebuild from `project.settings`.
        @Published var settings: VideoSettings = VideoSettings.androidDefault
        
        /// Project settings panel, "Preview Playback" (Android: previewFpsRuntime / isPlayingInReverse).
        /// Speed is preview fps / project fps; 1 = normal. Applied live, also while playing.
        @Published var previewSpeed: Double = 1.0 { didSet { applyLiveRate() } }
        @Published var playsInReverse: Bool = false { didSet { applyLiveRate() } }
        /// A short message the editor shows in an alert (e.g. reverse is not available).
        @Published var notice: String?
        /// True while the item carries a playback window (selected-clip playback) that must be removed again.
        private var windowActive = false
        
        private var timeObserverToken: Any?
        private var currentComposition: AVMutableComposition?
        private let scrubAudio = ScrubAudio()
        private var interruptionObserver: NSObjectProtocol?
        
        init() {
            // `.playback` category: sound must play with the ring/silent switch on.
            AudioSessionController.activatePlayback()
            setupTimeObserver()
            // After a phone call / Siri the session is deactivated; take it back when it ends.
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended {
                    AudioSessionController.activatePlayback()
                }
            }
        }
        
        deinit {
            if let token = timeObserverToken {
                player.removeTimeObserver(token)
            }
            if let observer = interruptionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            scrubAudio.shutdown()
        }
        
        /// `window`: when a clip is selected Android plays only that clip (unless "Keep Playing with
        /// Chosen Clip" is on): playback starts at the clip's start if the playhead is outside it and
        /// stops at its end. nil = the whole timeline.
        func togglePlayPause(window: ClosedRange<Double>? = nil) {
            if player.timeControlStatus == .playing {
                pause()
            } else {
                startPlayback(window: window)
            }
        }
        
        private var signedRate: Float { Float(previewSpeed) * (playsInReverse ? -1 : 1) }
        
        /// Speed / direction changed from the panel: follow immediately if the player is running.
        private func applyLiveRate() {
            guard player.timeControlStatus != .paused else { return }
            if playsInReverse, player.currentItem?.canPlayReverse != true {
                playsInReverse = false
                notice = "This preview can't be played backwards."
                return
            }
            player.rate = signedRate
        }
        
        private func startPlayback(window: ClosedRange<Double>?) {
            guard let item = player.currentItem else { return }
            let total = item.duration.seconds
            guard total.isFinite, total > 0 else { return }
            if playsInReverse && !item.canPlayReverse {
                playsInReverse = false
                notice = "This preview can't be played backwards."
                return
            }
            scrubAudio.stop()                       // a scrub burst must not overlap playback
            AudioSessionController.activatePlayback()
            
            let reverse = playsInReverse
            let eps = 0.02
            let lower = window?.lowerBound ?? 0
            let upper = min(window?.upperBound ?? total, total)
            // Start inside the window / not stuck on the end we are about to run into.
            var start = currentTime
            if reverse {
                if start <= lower + eps || start > upper + eps { start = upper }
            } else {
                if start >= upper - eps || start < lower - eps { start = lower }
            }
            
            let begin: () -> Void = { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if window != nil {
                    item.forwardPlaybackEndTime = CMTime(seconds: upper, preferredTimescale: 600)
                    item.reversePlaybackEndTime = CMTime(seconds: lower, preferredTimescale: 600)
                    self.windowActive = true
                } else {
                    item.forwardPlaybackEndTime = .invalid
                    item.reversePlaybackEndTime = .invalid
                    self.windowActive = false
                }
                self.player.rate = self.signedRate        // a non-zero rate starts playback
                self.isPlaying = true
            }
            
            if abs(start - currentTime) > 0.001 {
                currentTime = start
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    // A newer seek (the user scrubbed) cancels this start.
                    guard finished else { return }
                    DispatchQueue.main.async { begin() }
                }
            } else {
                begin()
            }
        }
        
        /// Seeks past `forwardPlaybackEndTime` would be clamped, so the window must not outlive playback.
        private func clearWindow() {
            guard windowActive else { return }
            windowActive = false
            player.currentItem?.forwardPlaybackEndTime = .invalid
            player.currentItem?.reversePlaybackEndTime = .invalid
        }
        
        // MARK: Smooth scrubbing (Apple QA1820 "chase time")
        //
        // Every AVPlayer.seek CANCELS the one before it, so firing a seek per touch-move during a
        // fast drag means almost none of them ever completes and the picture only updates when
        // you slow down. Instead: keep at most ONE seek in flight, remember the latest target,
        // and when the seek finishes chase the newest target. Loose tolerance while the finger
        // moves (fast, any nearby frame), then one exact seek when it lifts.
        
        private var chaseTime: CMTime = .invalid
        private var isSeekInProgress = false
        
        func scrub(to seconds: Double) {
            currentTime = seconds                  // ruler / readout follow the finger immediately
            let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            guard !chaseTime.isValid || CMTimeCompare(target, chaseTime) != 0 else { return }
            chaseTime = target
            if !isSeekInProgress { chaseSeek() }
        }
        
        private func chaseSeek() {
            guard chaseTime.isValid, player.currentItem != nil else { isSeekInProgress = false; return }
            isSeekInProgress = true
            let inProgress = chaseTime
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: inProgress, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.chaseTime.isValid, CMTimeCompare(inProgress, self.chaseTime) != 0 {
                        self.chaseSeek()           // the finger moved on while we were seeking
                    } else {
                        self.isSeekInProgress = false
                    }
                }
            }
        }
        
        /// Finger lifted: land on the exact frame under the playhead.
        func endScrub() {
            guard !isPlaying, player.currentItem != nil else { return }
            chaseTime = .invalid
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        /// Called for every scrub update from the timeline (never for programmatic seeks).
        func playScrubBurst(at seconds: Double) {
            guard !isPlaying else { return }
            scrubAudio.burst(at: seconds)
        }
        
        /// Leaving the editor: stop everything and let other apps' audio resume.
        func releaseAudio() {
            pause()
            scrubAudio.shutdown()
            AudioSessionController.deactivate()
        }
        
        /// Explicit stop, distinct from the toggle above — this is what timeline
        /// scrubbing calls. Android's equivalent is `stopPlayback(true)`, invoked
        /// from `handleEditZoneInteraction`'s ACTION_MOVE handler the instant the
        /// user starts dragging the timeline while playing. Idempotent: safe to
        /// call even when already paused.
        func pause() {
            if player.timeControlStatus != .paused {      // also while still starting up
                player.pause()
            }
            isPlaying = false
            clearWindow()
        }
        
        private func setupTimeObserver() {
            let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self else { return }
                
                // Only trust the player's own reported time while actually playing.
                // While paused/scrubbing, `currentTime` is driven manually by seek(to:)
                // from timeline scrolling — letting this observer overwrite it every
                // 50ms fought that, making the ruler/readout appear frozen no matter
                // how far you scrolled.
                let status = self.player.timeControlStatus
                if status == .playing {
                    self.currentTime = time.seconds
                    self.isPlaying = true
                    // Reverse playback reached the start of the timeline: stop (Android does too).
                    if self.player.rate < 0, time.seconds <= 0.02 {
                        self.pause()
                    }
                } else {
                    self.isPlaying = false
                    if status == .paused { self.clearWindow() }     // playback ended by itself
                }
            }
        }
        
        private var isRefreshingFrame = false
        
        /// Re-render the frame under the playhead while paused, so a live gesture (which only
        /// changes `LiveOverrides`) becomes visible. While playing the compositor picks the new
        /// values up on the next frame by itself.
        func refreshFrame() {
            guard !isPlaying, let item = player.currentItem, !isRefreshingFrame else { return }
            isRefreshingFrame = true
            // Re-assigning a copy of the video composition invalidates the displayed frame...
            if let composition = item.videoComposition,
               let copy = composition.mutableCopy() as? AVVideoComposition {
                item.videoComposition = copy
            }
            // ...and a zero-tolerance seek to the same time asks for a fresh one.
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.isRefreshingFrame = false
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
        /// This mimics Android's ClipRenderer pipeline: AVFoundation only supplies the decoded
        /// source frames and audio; every visual layer is composited by `ClipCompositor`.
        func rebuildComposition(from timeline: EditingView.Timeline, projectDir: URL) {
            // Shared with the exporter (EditingView+CompositionBuilder.swift): preview == export.
            let built = CompositionBuilder.build(timeline: timeline, projectDir: projectDir)
            self.settings = built.settings
            
            let composition = built.composition
            let scale: CMTimeScale = 600
            let item = AVPlayerItem(asset: composition)
            item.audioTimePitchAlgorithm = .timeDomain      // keep the pitch when the preview speed != 1
            let end = composition.duration
            if let videoComposition = built.videoComposition {
                item.videoComposition = videoComposition
            }
            
            currentComposition = composition
            scrubAudio.setSources(built.scrubSources)
            player.replaceCurrentItem(with: item)
            
            // Prevent auto-play explicitly
            player.pause()
            isPlaying = false
            
            // replaceCurrentItem resets the player to 0; put it back on the playhead so the
            // frame under the playhead reflects the edit that triggered this rebuild.
            let resumeAt = min(currentTime, max(end.seconds, 0))
            if resumeAt > 0 {
                player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: scale),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
}
