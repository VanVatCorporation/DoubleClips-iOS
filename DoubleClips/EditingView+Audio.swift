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
    
    /// Scrub audio as a small granular engine.
    ///
    /// Desktop/Android get their "adapts to the scrub speed" sound from short overlapping bursts:
    /// each burst is cut by the next one, so the result is a stream of ~20-50 ms grains read from
    /// wherever the playhead currently is. Slow drag = the same area over and over (slow motion),
    /// fast drag = grains far apart (fast forward), 1x = contiguous = natural audio.
    ///
    /// The previous iOS version triggered one burst per touch event and restarted the player node
    /// each time (stop -> schedule -> play). A node needs an audio-hardware cycle to start rendering
    /// and touch events come every 8-16 ms, so bursts were cut before they made a sound, and the
    /// few that did were ~10 ms long. It only sounded right near 1x, where those fragments line up.
    ///
    /// Now the output is decoupled from the touch rate: while the playhead is being moved, a steady
    /// 20 ms timer reads a 40 ms grain at the CURRENT position, shapes it with a Hann window and
    /// overlap-adds it with the previous grain's tail (50 % overlap, windows sum to exactly 1, so
    /// 1x scrubbing reproduces the source untouched). The player node is never stopped between
    /// grains; it just keeps getting 20 ms blocks.
    final class ScrubAudio {
        
        private let queue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.scrub-audio", qos: .userInitiated)
        private let lock = NSLock()
        private var pendingTime: Double?                  // latest playhead position (guarded by `lock`)
        private var lastRequest: UInt64 = 0               // when it was set, uptime ns (guarded by `lock`)
        
        // Everything below is touched on `queue` only.
        private var sources: [ScrubSource] = []
        private var files: [URL: AVAudioFile] = [:]
        private var converters: [URL: AVAudioConverter] = [:]
        private var unreadable = Set<URL>()
        /// original media URL -> decoded PCM copy (CAF) with instant random access.
        private var prepared: [URL: URL] = [:]
        private var preparing = Set<URL>()
        private var withoutAudio = Set<URL>()
        private let prepareQueue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.scrub-prepare", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var idleStop: DispatchWorkItem?
        private var inFlight = 0                          // blocks scheduled but not yet played
        private var generation = 0                        // invalidates completions after a stop()
        
        private let engine = AVAudioEngine()
        private let node = AVAudioPlayerNode()
        private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        private var isGraphBuilt = false
        
        /// 20 ms hop, 40 ms grain.
        private let hopFrames = 882
        private var grainFrames: Int { hopFrames * 2 }
        private lazy var window: [Float] = (0..<(hopFrames * 2)).map {
            // Periodic Hann: window[i] + window[i + hop] == 1.
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(hopFrames * 2)))
        }
        private var tail: [[Float]] = [[], []]             // second half of the previous grain
        private var tailPending = false
        
        /// No new playhead position for this long = the finger stopped = stop producing sound.
        private let idleNanos: UInt64 = 120_000_000
        
        func setSources(_ list: [ScrubSource]) {
            queue.async {
                self.sources = list
                let keep = Set(list.map { $0.url })
                self.files = self.files.filter { keep.contains($0.key) }
                self.converters = self.converters.filter { keep.contains($0.key) }
                self.unreadable.formIntersection(keep)
                keep.forEach { self.ensurePrepared($0) }
            }
        }
        
        /// Call on every scrub update. Cheap on purpose (runs on the touch path): it only records
        /// the latest position; the timer decides what to play.
        func burst(at seconds: Double) {
            lock.lock()
            pendingTime = seconds
            lastRequest = DispatchTime.now().uptimeNanoseconds
            lock.unlock()
            queue.async { [weak self] in self?.ensureRunning() }
        }
        
        func stop() {
            lock.lock(); pendingTime = nil; lock.unlock()
            queue.async { [weak self] in self?.reset() }
        }
        
        /// Blocks until the engine is stopped — the audio session can't be deactivated while it runs.
        func shutdown() {
            lock.lock(); pendingTime = nil; lock.unlock()
            queue.sync {
                reset()
                idleStop?.cancel()
                if engine.isRunning { engine.stop() }
                files.removeAll()
                converters.removeAll()
            }
        }
        
        // MARK: Run loop (on `queue`)
        
        private func ensureRunning() {
            guard timer == nil else { return }
            idleStop?.cancel()
            tail = [[Float](repeating: 0, count: hopFrames), [Float](repeating: 0, count: hopFrames)]
            tailPending = false
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
        
        private func endRun() {
            timer?.cancel()
            timer = nil
            scheduleIdleStop()
        }
        
        private func reset() {
            timer?.cancel()
            timer = nil
            generation += 1
            inFlight = 0
            tailPending = false
            if isGraphBuilt { node.stop() }
        }
        
        private func tick() {
            lock.lock(); let target = pendingTime; let stamp = lastRequest; lock.unlock()
            guard inFlight < 3 else { return }            // never build a backlog = never add latency
            
            let moving = DispatchTime.now().uptimeNanoseconds &- stamp < idleNanos
            let grain: [[Float]]? = (moving ? target : nil).flatMap { mixGrain(at: $0) }
            
            if grain == nil && !tailPending {
                if moving { return }                      // gap between clips: stay silent, keep listening
                endRun()                                  // finger stopped and the tail has faded out
                return
            }
            if let block = makeBlock(grain: grain) { schedule(block) }
        }
        
        /// out = previous tail + first half of the new grain; new tail = second half of the new grain.
        private func makeBlock(grain: [[Float]]?) -> AVAudioPCMBuffer? {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hopFrames)),
                  let out = buffer.floatChannelData else { return nil }
            buffer.frameLength = AVAudioFrameCount(hopFrames)
            for channel in 0..<2 {
                for i in 0..<hopFrames {
                    var value = tail[channel][i]
                    if let grain {
                        value += grain[channel][i] * window[i]
                        tail[channel][i] = grain[channel][hopFrames + i] * window[hopFrames + i]
                    } else {
                        tail[channel][i] = 0
                    }
                    out[channel][i] = max(-1, min(1, value))
                }
            }
            tailPending = grain != nil
            return buffer
        }
        
        private func schedule(_ block: AVAudioPCMBuffer) {
            startEngineIfNeeded()
            if !node.isPlaying { node.play() }            // started once; never restarted between grains
            inFlight += 1
            let generationAtSchedule = generation
            node.scheduleBuffer(block) { [weak self] in
                self?.queue.async {
                    guard let self, self.generation == generationAtSchedule else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                }
            }
        }
        
        // MARK: Reading + mixing
        
        /// 40 ms of every clip active at `seconds`, summed. nil = nothing audible there.
        private func mixGrain(at seconds: Double) -> [[Float]]? {
            guard seconds >= 0 else { return nil }
            let active = sources.filter { seconds >= $0.startTime && seconds < $0.startTime + $0.duration }
            guard !active.isEmpty else { return nil }
            
            var mix = [[Float]](repeating: [Float](repeating: 0, count: grainFrames), count: 2)
            var any = false
            for source in active {
                let clipTime = seconds - source.startTime + source.startTrim
                guard let chunk = read(source.url, at: clipTime), let data = chunk.floatChannelData else { continue }
                let frames = min(Int(chunk.frameLength), grainFrames)
                let channels = Int(chunk.format.channelCount)
                for channel in 0..<2 {
                    let from = data[min(channel, channels - 1)]
                    for i in 0..<frames { mix[channel][i] += from[i] }
                }
                any = true
            }
            return any ? mix : nil
        }
        
        /// One grain of one clip's audio at `clipTime`, in the common 44.1 kHz stereo float format.
        private func read(_ url: URL, at clipTime: Double) -> AVAudioPCMBuffer? {
            guard clipTime >= 0, let file = openFile(url) else { return nil }
            let inputRate = file.processingFormat.sampleRate
            let position = AVAudioFramePosition(clipTime * inputRate)
            guard position < file.length else { return nil }
            
            let wanted = AVAudioFrameCount(grainFrames)
            let inFrames = AVAudioFrameCount(Double(wanted) * inputRate / format.sampleRate) + 32
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inFrames) else { return nil }
            file.framePosition = position
            do { try file.read(into: input, frameCount: inFrames) } catch { return nil }
            guard input.frameLength > 0 else { return nil }
            
            if file.processingFormat == format { return input }
            
            // Different rate / channel count (48 kHz, mono ...): convert. `reset()` so the
            // resampler's history from the previous grain never bleeds into this one.
            let converter: AVAudioConverter
            if let cached = converters[url] { converter = cached }
            else if let made = AVAudioConverter(from: file.processingFormat, to: format) {
                converters[url] = made
                converter = made
            } else { return nil }
            converter.reset()
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else { return nil }
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
        
        // MARK: Decoded PCM copies
        //
        // The desktop scrubs from per-clip preview .wav files and Android from a preview clip: random
        // access into already-decoded audio. AVAudioFile can read audio-only files directly, but
        // often can NOT open an .mp4/.mov that also carries video — scrubbing a video clip was
        // silent. So every clip's audio is decoded ONCE to a CAF in Caches (in the background);
        // until that exists, the original file is tried as a fallback.
        
        private func ensurePrepared(_ url: URL) {
            guard prepared[url] == nil, !preparing.contains(url), !withoutAudio.contains(url) else { return }
            let destination = ClipMediaCache.shared.scrubCacheURL(for: url)
            if FileManager.default.fileExists(atPath: destination.path) {
                adopt(destination, for: url)
                return
            }
            preparing.insert(url)
            prepareQueue.async { [weak self] in
                let result = ScrubAudio.extractAudio(from: url, to: destination)
                self?.queue.async {
                    guard let self else { return }
                    self.preparing.remove(url)
                    switch result {
                    case .done: self.adopt(destination, for: url)
                    case .noAudio: self.withoutAudio.insert(url)
                    case .failed: break           // retried the next time the sources are set
                    }
                }
            }
        }
        
        private func adopt(_ cache: URL, for url: URL) {
            prepared[url] = cache
            files[url] = nil                      // reopen from the fast copy
            converters[url] = nil
            unreadable.remove(url)
        }
        
        private enum Extraction { case done, noAudio, failed }
        
        /// Decodes the audio track to a CAF (16-bit PCM, the source's own rate and channel layout;
        /// reads convert to 44.1 kHz stereo). Written to a temp name and renamed, so a crash or a
        /// cancelled launch never leaves a half-written file that would later be used.
        private static func extractAudio(from url: URL, to destination: URL) -> Extraction {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else { return .noAudio }
            guard let reader = try? AVAssetReader(asset: asset) else { return .failed }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ])
            guard reader.canAdd(output) else { return .failed }
            reader.add(output)
            guard reader.startReading() else { return .failed }
            
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // AVAudioFile picks the container from the extension, so the temp file must stay ".caf".
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(destination.deletingPathExtension().lastPathComponent + ".part.caf")
            try? fm.removeItem(at: temporary)
            
            var file: AVAudioFile?
            var wroteAnything = false
            while let sample = output.copyNextSampleBuffer() {
                guard let description = CMSampleBufferGetFormatDescription(sample) else { continue }
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
                buffer.frameLength = frames
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { continue }
                
                if file == nil {
                    file = try? AVAudioFile(forWriting: temporary, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: Int(format.channelCount),
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                    if file == nil { reader.cancelReading(); return .failed }
                }
                do {
                    try file?.write(from: buffer)
                    wroteAnything = true
                } catch {
                    reader.cancelReading()
                    file = nil
                    try? fm.removeItem(at: temporary)
                    return .failed
                }
            }
            file = nil                            // closes the file (flushes the header)
            
            guard reader.status == .completed, wroteAnything else {
                try? fm.removeItem(at: temporary)
                return wroteAnything ? .failed : .noAudio
            }
            try? fm.removeItem(at: destination)
            do { try fm.moveItem(at: temporary, to: destination) } catch { return .failed }
            return .done
        }
        
        private func openFile(_ url: URL) -> AVAudioFile? {
            if let file = files[url] { return file }
            if unreadable.contains(url) { return nil }
            do {
                let file = try AVAudioFile(forReading: prepared[url] ?? url)
                files[url] = file
                return file
            } catch {
                unreadable.insert(url)
                print("[ScrubAudio] Can't read audio from \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        
        // MARK: Engine
        
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
                guard let self, self.timer == nil else { return }
                if self.isGraphBuilt { self.node.stop() }
                if self.engine.isRunning { self.engine.stop() }
            }
            idleStop = work
            queue.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }
}
