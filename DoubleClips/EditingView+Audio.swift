import AVFoundation

// MARK: - Audio session + scrub audio
//
// 1. Silent switch. iOS only plays audio with the ring/silent switch ON when the app's audio
//    session category is `.playback`. The editor never configured a session (the only call
//    lived in VideoPlayerView, which the editor doesn't use), so it ran with the default
//    `.soloAmbient` category — which obeys the switch.
//
// 2. Scrub audio. Android (pumpDecoderAudioSeek) and desktop (ClipRenderer.requestAudioBurst) do
//    NOT change playback speed while scrubbing: on every scrub update they flush the output and
//    write ~50 ms of audio at the exact scrub position; during normal playback they stream
//    continuously at 1x instead. Fast scrubbing therefore skips ahead and slow scrubbing
//    stutters — which sounds like audio "adapting to the scrub speed". Same thing here.

enum AudioSessionController {
    
    /// `.playback` ignores the silent switch (and keeps playing with the screen locked).
    /// Cheap to call repeatedly; also re-activates after an interruption such as a phone call.
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("[Audio] Couldn't activate the playback session: \(error)")
        }
    }
    
    /// Lets other apps' audio (music, podcasts) resume once the editor is closed.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension EditingView {
    
    /// One audio-carrying clip, as plain values (safe to hand to the audio queue).
    struct ScrubSource {
        let url: URL
        let startTime: Double   // clip start on the timeline
        let startTrim: Double   // Clip.startClipTrim
        let duration: Double
    }
    
    /// Scrub audio in the same shape as the desktop's requestAudioBurst: random access into each
    /// active clip's audio, 50 ms, mixed, flush-and-play.
    ///
    /// The first version built an AVAssetReader over the whole composition for EVERY burst. Opening
    /// files and spinning up a decode pipeline dozens of times per second starved the video seeks
    /// (they share the decoders and disk) and made scrubbing stutter. Here each clip's file is
    /// opened ONCE as an AVAudioFile and kept open: a burst is just `framePosition = x; read()`,
    /// a few milliseconds even for AAC.
    final class ScrubAudio {
        
        private let queue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.scrub-audio", qos: .userInitiated)
        private let lock = NSLock()
        private var pending: Double?                       // latest requested time (guarded by `lock`)
        
        // Everything below is touched on `queue` only.
        private var sources: [ScrubSource] = []
        private var files: [URL: AVAudioFile] = [:]
        private var converters: [URL: AVAudioConverter] = [:]
        private var unreadable = Set<URL>()
        private var idleStop: DispatchWorkItem?
        
        private let engine = AVAudioEngine()
        private let node = AVAudioPlayerNode()
        private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        private var isGraphBuilt = false
        
        /// 50 ms — same as the desktop's burst.
        private let burstFrames: AVAudioFrameCount = 2_205
        /// ~2 ms linear fade at both ends of a burst: bursts are cut at arbitrary sample positions,
        /// which would otherwise click on every scrub step.
        private let fadeFrames = 88
        
        func setSources(_ list: [ScrubSource]) {
            queue.async {
                self.sources = list
                let keep = Set(list.map { $0.url })
                self.files = self.files.filter { keep.contains($0.key) }
                self.converters = self.converters.filter { keep.contains($0.key) }
                self.unreadable.formIntersection(keep)
            }
        }
        
        /// Call on every scrub update. Latest request wins: while one burst is being prepared,
        /// newer requests overwrite `pending`, so no backlog of stale positions can build up.
        func burst(at seconds: Double) {
            lock.lock(); pending = seconds; lock.unlock()
            queue.async { [weak self] in self?.drain() }
        }
        
        func stop() {
            lock.lock(); pending = nil; lock.unlock()
            queue.async { [weak self] in self?.node.stop() }
        }
        
        /// Blocks until the engine is stopped — the audio session can't be deactivated while it runs.
        func shutdown() {
            lock.lock(); pending = nil; lock.unlock()
            queue.sync {
                idleStop?.cancel()
                node.stop()
                if engine.isRunning { engine.stop() }
                files.removeAll()
                converters.removeAll()
            }
        }
        
        // MARK: Private (on `queue`)
        
        private func drain() {
            lock.lock(); let time = pending; pending = nil; lock.unlock()
            guard let time else { return }   // a newer task already consumed it
            render(at: time)
        }
        
        private func render(at seconds: Double) {
            guard seconds >= 0 else { return }
            let active = sources.filter { seconds >= $0.startTime && seconds < $0.startTime + $0.duration }
            guard !active.isEmpty,
                  let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: burstFrames),
                  let out = mix.floatChannelData else {
                node.stop()                       // gap between clips: silence, and drop the stale burst
                return
            }
            
            for channel in 0..<2 { out[channel].initialize(repeating: 0, count: Int(burstFrames)) }
            var longest = 0
            for source in active {
                let clipTime = seconds - source.startTime + source.startTrim
                guard let chunk = read(source.url, at: clipTime), let data = chunk.floatChannelData else { continue }
                let frames = Int(min(chunk.frameLength, burstFrames))
                let channels = Int(chunk.format.channelCount)
                for channel in 0..<2 {
                    let from = data[min(channel, channels - 1)]
                    let to = out[channel]
                    for i in 0..<frames { to[i] += from[i] }
                }
                longest = max(longest, frames)
            }
            guard longest > 0 else { node.stop(); return }
            
            // Overlapping clips add up: clamp, then fade the edges.
            let fade = min(fadeFrames, longest / 2)
            for channel in 0..<2 {
                let samples = out[channel]
                for i in 0..<longest {
                    var v = max(-1, min(1, samples[i]))
                    if fade > 0 {
                        if i < fade { v *= Float(i) / Float(fade) }
                        else if i >= longest - fade { v *= Float(longest - 1 - i) / Float(fade) }
                    }
                    samples[i] = v
                }
            }
            mix.frameLength = AVAudioFrameCount(longest)
            
            startEngineIfNeeded()
            node.stop()                           // flush(): the previous burst is stale now
            node.scheduleBuffer(mix)
            node.play()
            scheduleIdleStop()
        }
        
        /// 50 ms of one clip's audio at `clipTime`, in the common 44.1 kHz stereo float format.
        private func read(_ url: URL, at clipTime: Double) -> AVAudioPCMBuffer? {
            guard clipTime >= 0, let file = openFile(url) else { return nil }
            let inputRate = file.processingFormat.sampleRate
            let position = AVAudioFramePosition(clipTime * inputRate)
            guard position < file.length else { return nil }
            
            let inFrames = AVAudioFrameCount(Double(burstFrames) * inputRate / format.sampleRate) + 32
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrames) else { return nil }
            file.framePosition = position
            do { try file.read(into: input, frameCount: inFrames) } catch { return nil }
            guard input.frameLength > 0 else { return nil }
            
            if file.processingFormat == format { return input }
            
            // Different rate / channel count (48 kHz, mono ...): convert. `reset()` so the
            // resampler's history from the previous burst never bleeds into this one.
            let converter: AVAudioConverter
            if let cached = converters[url] { converter = cached }
            else if let made = AVAudioConverter(from: file.processingFormat, to: format) {
                converters[url] = made
                converter = made
            } else { return nil }
            converter.reset()
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: burstFrames) else { return nil }
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            return error == nil && converted.frameLength > 0 ? converted : nil
        }
        
        private func openFile(_ url: URL) -> AVAudioFile? {
            if let file = files[url] { return file }
            if unreadable.contains(url) { return nil }
            do {
                let file = try AVAudioFile(forReading: url)
                files[url] = file
                return file
            } catch {
                unreadable.insert(url)
                print("[ScrubAudio] Can't read audio from \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        
        private func startEngineIfNeeded() {
            if !isGraphBuilt {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                isGraphBuilt = true
            }
            if !engine.isRunning {
                AudioSessionController.activatePlayback()
                engine.prepare()
                try? engine.start()
            }
        }
        
        /// No point keeping the audio hardware spinning once the user stops scrubbing.
        private func scheduleIdleStop() {
            idleStop?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.node.stop()
                if self.engine.isRunning { self.engine.stop() }
            }
            idleStop = work
            queue.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }
}
