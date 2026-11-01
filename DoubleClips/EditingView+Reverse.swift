import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import Combine

// MARK: - Reverse (CapCut style)
//
// `Clip.isReverse` is THE mark, the same flag the desktop's Reverse toggle sets and the future Template pipeline reads: the clip keeps its
// original `clipName` and trims. What is new is a CACHE: pressing Reverse pre-processes a reversed copy of the WHOLE source file (video and
// audio, like CapCut: cutting the clip short doesn't make it quicker), saved in the project's Clips folder as
//
//      <clipName>.reversed.mp4          e.g.  IMG_6880.MOV.reversed.mp4
//
// so it shows in Project Files, travels with the project and is shared by every clip (split, duplicate) that uses the same file. The
// builder plays the cache instead of the original when `isReverse` is on and the copy exists (time t of the original is time F - t of
// the copy), so trims, splits and speed ramps all keep working on the original's timeline. `reversedCopy` remembers the copy's name.
//
// Pressing Reverse again is instant: the flag goes off and the copy is deleted unless another flagged clip still needs it. A third press
// processes again. A clip that arrives flagged (from desktop, Android or a template) with no copy is processed when the editor opens.
// Desktop and Android can use the same name for the same cache.
//
// While it works the progress shows in three places, like CapCut: a badge on the preview canvas ("Applying 1 feature(s)..." with a list,
// then a green "applied" for a moment), "Processing 52.6%" in the clip's properties, and "Applying Reverse... 52.6%" on the clip.

extension EditingView {

    /// LEGACY (first version of Reverse swapped the clip onto a reversed copy of its used part): read only, to bring those clips back to the
    /// original footage with `isReverse` on (see ReverseManager.migrateLegacy). Never written any more.
    struct ReverseSource: Codable, Equatable {
        var clipName: String
        var startClipTrim: Float
        var endClipTrim: Float
        var originalDuration: Float
    }
}

// MARK: - The progress tracker (CapCut's "Applying ... 52.6%")

/// Which clip features are being processed right now and how far along each is. Used from the main thread only.
final class ProcessingTracker: ObservableObject {
    static let shared = ProcessingTracker()

    /// A flag a background worker can read at any time.
    final class CancelFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    final class Job: Identifiable {
        let id = UUID()
        /// The source file being processed (every clip that uses it shows the progress).
        let source: String
        let feature: String
        var clipName: String { source }
        fileprivate(set) var progress: Double = 0
        let cancelFlag = CancelFlag()
        var isCancelled: Bool { cancelFlag.isSet }
        fileprivate init(source: String, feature: String) {
            self.source = source; self.feature = feature
        }
        var percentText: String { String(format: "%.1f%%", progress * 100) }
    }

    static let doneVisible: TimeInterval = 2.5
    static let failedVisible: TimeInterval = 5

    @Published private(set) var running: [Job] = []
    private var lastDone: (feature: String, at: Date)?
    private var lastFailed: (text: String, at: Date)?

    func begin(source: String, feature: String) -> Job {
        let job = Job(source: source, feature: feature)
        running.removeAll { $0.source == source && $0.feature == feature }
        running.append(job)
        return job
    }

    func job(source: String, feature: String? = nil) -> Job? {
        running.first { $0.source == source && (feature == nil || $0.feature == feature) }
    }

    func update(_ job: Job, progress: Double) {
        let clamped = min(max(progress.isNaN ? 0 : progress, 0), 1)
        guard clamped - job.progress >= 0.002 || clamped >= 1 else { return }    // not a redraw per frame
        job.progress = clamped
        objectWillChange.send()
    }

    func finish(_ job: Job) {
        running.removeAll { $0 === job }
        lastDone = (job.feature, Date())
        expireLater(Self.doneVisible)
    }

    func fail(_ job: Job, _ reason: String) {
        running.removeAll { $0 === job }
        lastFailed = ("\(job.feature): \(reason)", Date())
        expireLater(Self.failedVisible)
    }

    /// The user cancelled (or nothing needs the result any more): the worker is told to stop and the job is forgotten.
    func cancel(_ job: Job) {
        job.cancelFlag.set()
        running.removeAll { $0 === job }
    }

    /// What the preview badge shows when nothing is running: the last result for a moment.
    var recentResult: (text: String, ok: Bool)? {
        guard running.isEmpty else { return nil }
        if let d = lastDone, Date().timeIntervalSince(d.at) < Self.doneVisible { return (Lf("%@ applied", L(d.feature)), true) }
        if let f = lastFailed, Date().timeIntervalSince(f.at) < Self.failedVisible { return (f.text, false) }
        return nil
    }

    private func expireLater(_ seconds: TimeInterval) {
        objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.objectWillChange.send() }
    }
}

// MARK: - Making the reversed copy

enum ReverseProcessor {

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class Box<T> {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    }

    /// Writes `output` (an MP4, so desktop and Android can play it too): the source from second `start` for `length` seconds, played backwards. Blocking: run it
    /// off the main thread. `progress` is 0 ... 1; `isCancelled` is asked often.
    static func run(source: URL, start: Double, length: Double, withAudio: Bool, output: URL,
                    progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) throws {
        let asset = AVURLAsset(url: source)
        guard let video = asset.tracks(withMediaType: .video).first else { throw Failure("This file has no video.") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                duration: CMTime(seconds: length, preferredTimescale: 60000))

        // 1. When every frame of the used part is shown (compressed samples only: quick).
        let times = try frameTimes(asset: asset, track: video, range: range, start: start, length: length)
        guard let last = times.last, let first = times.first else { throw Failure("No frames to reverse.") }
        progress(0.03)
        if isCancelled() { throw Failure("Cancelled") }

        // 2. The audio, decoded to a temporary file (read back to front below).
        var audio: AudioBlocks?
        defer { audio?.close() }
        if withAudio, let track = asset.tracks(withMediaType: .audio).first {
            audio = try? AudioBlocks.decode(asset: asset, track: track, range: range, isCancelled: isCancelled)
        }
        progress(audio == nil ? 0.03 : 0.12)
        if isCancelled() { throw Failure("Cancelled") }

        // 3. The writer.
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let size = video.naturalSize
        let width = max(2, Int(size.width.rounded()) & ~1), height = max(2, Int(size.height.rounded()) & ~1)
        let big = width > 4096 || height > 4096
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(max(2_000_000, min(80_000_000, Double(video.estimatedDataRate) * 1.3))),
            AVVideoAllowFrameReorderingKey: false
        ]
        if video.nominalFrameRate > 0 { compression[AVVideoExpectedSourceFrameRateKey] = Int(video.nominalFrameRate.rounded()) }
        if !big { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: big ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = video.preferredTransform          // portrait stays portrait
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw Failure("The video can't be written.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: 96_000 * audio.channels
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard writer.startWriting() else { throw writer.error ?? Failure("The video can't be written.") }
        writer.startSession(atSourceTime: .zero)

        // 4. Frames back to front, in windows that fit in memory; audio blocks back to front. Both inputs are fed at once (the
        //    writer interleaves them and stops accepting one until the other keeps up).
        let frames = ReversedFrames(asset: asset, track: video, times: times, width: width, height: height)
        let failure = Box<Error?>(nil)
        let group = DispatchGroup()
        let written = Box(0)
        let total = max(1, times.count)
        let base = audio == nil ? 0.03 : 0.12

        func pump(_ input: AVAssetWriterInput, queue: String, step: @escaping () throws -> Bool) {
            group.enter()
            let finished = Box(false)
            func end() {
                if finished.get() { return }
                finished.set(true)
                input.markAsFinished()
                group.leave()
            }
            input.requestMediaDataWhenReady(on: DispatchQueue(label: queue, qos: .default)) {
                while input.isReadyForMoreMediaData && !finished.get() {
                    if isCancelled() || failure.get() != nil { end(); return }
                    do {
                        if try !step() { end(); return }
                    } catch {
                        failure.set(error)
                        end()
                        return
                    }
                }
            }
        }

        pump(videoInput, queue: "reverse.video") {
            guard let (buffer, time) = try frames.next() else { return false }
            if !adaptor.append(buffer, withPresentationTime: time) { throw writer.error ?? Failure("The video can't be written.") }
            let done = written.get() + 1
            written.set(done)
            progress(base + (1 - base) * min(1, Double(done) / Double(total)))
            return true
        }
        if let audio, let audioInput {
            pump(audioInput, queue: "reverse.audio") {
                guard let buffer = try audio.next() else { return false }
                if !audioInput.append(buffer) { throw writer.error ?? Failure("The audio can't be written.") }
                return true
            }
        }
        group.wait()

        if isCancelled() { writer.cancelWriting(); throw Failure("Cancelled") }
        if let error = failure.get() { writer.cancelWriting(); throw error }

        // the last frame lasts as long as a typical one
        let typical = typicalStep(times)
        writer.endSession(atSourceTime: CMTime(seconds: last - first + typical, preferredTimescale: 60000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? Failure("The reversed copy can't be saved.") }
        progress(1)
    }

    private static func typicalStep(_ times: [Double]) -> Double {
        guard times.count > 1 else { return 1.0 / 30 }
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return steps.isEmpty ? 1.0 / 30 : steps[steps.count / 2]
    }

    /// Presentation times of the frames inside [start, start + length), sorted.
    private static func frameTimes(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, start: Double, length: Double) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)     // compressed: no decoding
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure("This video can't be read.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("This video can't be read.") }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if t.isFinite, t >= start - 0.0005, t < start + length - 0.0005 { times.append(t) }
        }
        if reader.status == .failed { throw reader.error ?? Failure("This video can't be read.") }
        return Array(Set(times)).sorted()
    }

    // MARK: frames, last to first

    private final class ReversedFrames {
        let asset: AVAsset, track: AVAssetTrack, times: [Double]
        let window: Int
        let lastTime: Double
        var nextIndex: Int                         // the next original frame to load (counting down)
        var pending: [(CVPixelBuffer, Double)] = []     // already decoded, in output order
        var lastOut = -1.0

        init(asset: AVAsset, track: AVAssetTrack, times: [Double], width: Int, height: Int) {
            self.asset = asset; self.track = track; self.times = times
            lastTime = times.last ?? 0
            nextIndex = times.count - 1
            // about 160 MB of decoded frames at a time (4:2:0 = 1.5 bytes a pixel)
            window = min(90, max(6, Int(160_000_000.0 / (Double(width * height) * 1.5))))
        }

        func next() throws -> (CVPixelBuffer, CMTime)? {
            while pending.isEmpty {
                if nextIndex < 0 { return nil }
                try load()
            }
            let (buffer, t) = pending.removeFirst()
            var out = lastTime - t
            if out <= lastOut { out = lastOut + 0.0001 }          // always moving forward
            lastOut = out
            return (buffer, CMTime(seconds: out, preferredTimescale: 60000))
        }

        private func load() throws {
            let hi = nextIndex
            let lo = max(0, hi - window + 1)
            nextIndex = lo - 1
            let from = times[lo] - 0.0004, to = times[hi] + 0.0004
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60000),
                                           end: CMTime(seconds: to, preferredTimescale: 60000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure("This video can't be read.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure("This video can't be read.") }
            var decoded: [(CVPixelBuffer, Double)] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if t >= from, t <= to { decoded.append((buffer, t)) }
            }
            if reader.status == .failed { throw reader.error ?? Failure("This video can't be read.") }
            pending = decoded.sorted { $0.1 > $1.1 }              // newest first = the reversed order
        }
    }

    // MARK: audio, last block to first

    private final class AudioBlocks {
        let sampleRate: Double
        let channels: Int
        private let url: URL
        private let handle: FileHandle
        private let format: CMAudioFormatDescription
        private let frameBytes: Int
        private var remaining: Int              // frames not written yet
        private var outFrames = 0
        private let blockFrames = 4096

        private init(url: URL, handle: FileHandle, sampleRate: Double, channels: Int, frames: Int, format: CMAudioFormatDescription) {
            self.url = url; self.handle = handle; self.sampleRate = sampleRate; self.channels = channels
            self.format = format; frameBytes = 2 * channels; remaining = frames
        }

        /// Decodes the used part of the track to 16 bit PCM in a temporary file.
        static func decode(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, isCancelled: () -> Bool) throws -> AudioBlocks {
            var rate = 44100.0, channels = 2
            if let description = track.formatDescriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription)?.pointee {
                if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
                channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: channels
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure("The audio can't be read.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure("The audio can't be read.") }

            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reverse-\(UUID().uuidString).pcm")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writeHandle = try FileHandle(forWritingTo: url)
            var bytes = 0
            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() { try? writeHandle.close(); try? FileManager.default.removeItem(at: url); throw Failure("Cancelled") }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { continue }
                writeHandle.write(data)
                bytes += length
            }
            try? writeHandle.close()
            if reader.status == .failed || bytes < 2 * channels {
                try? FileManager.default.removeItem(at: url)
                throw reader.error ?? Failure("No audio.")
            }

            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
                                                   mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                                   mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                 formatDescriptionOut: &format) == noErr, let format else {
                try? FileManager.default.removeItem(at: url)
                throw Failure("The audio can't be written.")
            }
            let readHandle = try FileHandle(forReadingFrom: url)
            return AudioBlocks(url: url, handle: readHandle, sampleRate: rate, channels: channels,
                               frames: bytes / (2 * channels), format: format)
        }

        func close() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        /// The next block, taken from the END of what is left and turned around frame by frame.
        func next() throws -> CMSampleBuffer? {
            guard remaining > 0 else { return nil }
            let take = min(blockFrames, remaining)
            let startFrame = remaining - take
            try handle.seek(toOffset: UInt64(startFrame * frameBytes))
            guard let data = try handle.read(upToCount: take * frameBytes), data.count == take * frameBytes else {
                throw Failure("The audio can't be read.")
            }
            remaining = startFrame
            var turned = [UInt8](repeating: 0, count: data.count)
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for i in 0..<take {
                    let from = (take - 1 - i) * frameBytes
                    for b in 0..<frameBytes { turned[i * frameBytes + b] = source[from + b] }
                }
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: turned.count,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: turned.count, flags: 0, blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferReplaceDataBytes(with: turned, blockBuffer: block, offsetIntoDestination: 0,
                                                dataLength: turned.count) == noErr else { throw Failure("The audio can't be written.") }
            var sample: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: take,
                presentationTimeStamp: CMTime(value: CMTimeValue(outFrames), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw Failure("The audio can't be written.") }
            outFrames += take
            return sample
        }
    }
}

// MARK: - The reverse button's logic

extension EditingView {

    final class ReverseManager {
        static let shared = ReverseManager()
        static let feature = "Reverse"

        /// The reversed copy of a source file: the whole file backwards, in the Clips folder. Same name on every platform.
        static func cacheName(for source: String) -> String { source + ".reversed.mp4" }

        struct Context {
            let projectPath: String
            let timeline: Timeline
            let commandManager: CommandManager
            let onChanged: () -> Void
        }

        private var context: Context?

        /// The editor tells where the project is and how to refresh itself (every time it appears).
        func configure(projectPath: String, timeline: Timeline, commandManager: CommandManager, onChanged: @escaping () -> Void) {
            context = Context(projectPath: projectPath, timeline: timeline, commandManager: commandManager, onChanged: onChanged)
        }

        private var folder: URL? {
            context.map { URL(fileURLWithPath: $0.projectPath).appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY) }
        }

        private func videoClips() -> [Clip] {
            context?.timeline.tracks.flatMap { $0.clips }.filter { $0.type == .video } ?? []
        }

        // MARK: opening the editor

        /// Brings the project up to date: clips made by the first version of Reverse go back to their original footage with the flag on,
        /// and every flagged clip gets its copy (found by its name, or processed when it is missing).
        func syncAll() {
            guard context != nil else { return }
            for clip in videoClips() where clip.reverseSource != nil { migrateLegacy(clip) }
            for clip in videoClips() where clip.isReverse { ensureCache(for: clip, userInitiated: false) }
        }

        private func migrateLegacy(_ clip: Clip) {
            guard let source = clip.reverseSource else { return }
            let oldCopy = clip.clipName
            // a trim made on that reversed clip comes back mirrored: its start is the original's end
            let start = source.startClipTrim + clip.endClipTrim
            let end = source.endClipTrim + clip.startClipTrim
            clip.clipName = source.clipName
            clip.startClipTrim = start
            clip.endClipTrim = end
            clip.originalDuration = source.originalDuration
            clip.reverseSource = nil
            clip.isReverse = true
            clip.reversedCopy = nil
            if let folder, !videoClips().contains(where: { $0.clipName == oldCopy }) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(oldCopy))
            }
        }

        // MARK: the button

        /// The Reverse button / switch: one undo step that flips the flag (and makes or deletes the copy).
        func toggle(_ clip: Clip) {
            guard let context, clip.type == .video else { return }
            let turnOn = !clip.isReverse
            context.commandManager.execute(GenericCommand(
                description: "\(turnOn ? "Reverse" : "Un-reverse"): \(clip.clipName)",
                undo: { [weak self] in self?.setReversed(clip, !turnOn) },
                redo: { [weak self] in self?.setReversed(clip, turnOn) }))
        }

        private func setReversed(_ clip: Clip, _ on: Bool) {
            guard let context, clip.type == .video, clip.isReverse != on else { return }
            if on {
                clip.isReverse = true
                ensureCache(for: clip, userInitiated: true)
            } else {
                let source = clip.clipName
                clip.isReverse = false
                clip.reversedCopy = nil
                releaseCache(source: source)       // instant: the copy goes unless another flagged clip needs it
            }
            context.onChanged()
        }

        // MARK: the copy

        private func ensureCache(for clip: Clip, userInitiated: Bool) {
            guard let folder else { return }
            let source = clip.clipName
            let name = Self.cacheName(for: source)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                for c in videoClips() where c.isReverse && c.clipName == source && c.reversedCopy != name { c.reversedCopy = name }
                return
            }
            if clip.reversedCopy != nil { clip.reversedCopy = nil }          // it was deleted from Project Files
            if ProcessingTracker.shared.job(source: source, feature: Self.feature) != nil { return }   // running: attached when it finishes
            startJob(source: source, name: name, userInitiated: userInitiated)
        }

        private func startJob(source: String, name: String, userInitiated: Bool) {
            guard let context, let folder else { return }
            let tracker = ProcessingTracker.shared
            let sourceURL = folder.appendingPathComponent(source)
            let finalURL = folder.appendingPathComponent(name)
            let partialURL = folder.appendingPathComponent(name + ".partial")
            let job = tracker.begin(source: source, feature: Self.feature)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                failed(job, source: source, reason: L("The clip's file is missing."), userInitiated: userInitiated)
                return
            }
            _ = context
            DispatchQueue.global(qos: .default).async { [weak self] in      // same class as the writer's own queues (no priority inversion)
                do {
                    let length = AVURLAsset(url: sourceURL).duration.seconds
                    guard length.isFinite, length > 0.1 else { throw ReverseProcessor.Failure(L("This clip is too short to reverse.")) }
                    try ReverseProcessor.run(source: sourceURL, start: 0, length: length, withAudio: true, output: partialURL,
                                             progress: { p in DispatchQueue.main.async { tracker.update(job, progress: p) } },
                                             isCancelled: { job.isCancelled })
                    if job.isCancelled { throw ReverseProcessor.Failure("Cancelled") }
                    // The copy must hold a video as long as the source: a copy that can't be used is reported, never kept (a clip
                    // pointing at it would draw nothing).
                    let made = AVURLAsset(url: partialURL)
                    let madeLength = made.duration.seconds
                    print("[Reverse] \(source): source \(length)s, copy \(madeLength)s, video track: \(made.tracks(withMediaType: .video).first != nil)")
                    guard made.tracks(withMediaType: .video).first != nil, madeLength.isFinite,
                          abs(madeLength - length) <= max(1.0, length * 0.05) else {
                        throw ReverseProcessor.Failure(L("The reversed copy came out wrong."))
                    }
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: partialURL, to: finalURL)
                    DispatchQueue.main.async { self?.finished(job, source: source, name: name) }
                } catch {
                    try? FileManager.default.removeItem(at: partialURL)
                    let reason = (error as? ReverseProcessor.Failure)?.message ?? error.localizedDescription
                    DispatchQueue.main.async {
                        if !job.isCancelled { self?.failed(job, source: source, reason: reason, userInitiated: userInitiated) }
                    }
                }
            }
        }

        private func finished(_ job: ProcessingTracker.Job, source: String, name: String) {
            guard let context, let folder else { return }
            let tracker = ProcessingTracker.shared
            let flagged = videoClips().filter { $0.isReverse && $0.clipName == source }
            // nobody needs it any more (un-reversed while it was made, or the clips are gone): not kept
            guard !job.isCancelled, !flagged.isEmpty else {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                tracker.cancel(job)
                return
            }
            for clip in flagged { clip.reversedCopy = name }
            tracker.finish(job)
            context.onChanged()
        }

        private func failed(_ job: ProcessingTracker.Job, source: String, reason: String, userInitiated: Bool) {
            ProcessingTracker.shared.fail(job, reason)
            guard userInitiated, let context else { return }
            // pressed Reverse and it can't be done: the switch goes back off (a clip that CAME flagged keeps its flag)
            for clip in videoClips() where clip.isReverse && clip.clipName == source { clip.isReverse = false; clip.reversedCopy = nil }
            context.onChanged()
        }

        /// The copy of `source` is not needed by any flagged clip (any more): stop making it, or delete it.
        private func releaseCache(source: String) {
            guard let folder else { return }
            if videoClips().contains(where: { $0.isReverse && $0.clipName == source }) { return }
            if let job = ProcessingTracker.shared.job(source: source, feature: Self.feature) { ProcessingTracker.shared.cancel(job) }
            let name = Self.cacheName(for: source)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".partial"))
        }
    }
}

// MARK: - Where the progress shows

extension EditingView {

    /// The preview canvas badge: "Applying 1 feature(s)..." with a list of what is running, then a green message for a moment.
    struct ProcessingBadge: View {
        @ObservedObject private var tracker = ProcessingTracker.shared
        @State private var open = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if !tracker.running.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.65).tint(.white).frame(width: 14, height: 14)
                            Text(Lf("Applying %d feature(s)…", Int32(tracker.running.count)))
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.65)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if open {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(tracker.running) { job in
                                Text("\(L(job.feature)) · \(job.clipName)  \(job.percentText)")
                                    .font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                            }
                        }
                        .padding(8).background(Color.black.opacity(0.65)).cornerRadius(8)
                    }
                } else if let result = tracker.recentResult {
                    HStack(spacing: 6) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(result.text).lineLimit(2)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(result.ok ? Color.green : Color.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.black.opacity(0.65)).clipShape(Capsule())
                    .transition(.opacity)
                }
            }
            .allowsHitTesting(!tracker.running.isEmpty)
        }
    }

    /// The Reverse switch in the clip's properties, with "Processing 52.6%" next to it while the copy is made.
    struct ReverseRow: View {
        @ObservedObject var clip: Clip
        @ObservedObject private var tracker = ProcessingTracker.shared

        var body: some View {
            let job = clip.isReverse ? tracker.job(source: clip.clipName, feature: ReverseManager.feature) : nil
            HStack {
                Toggle(L("Reverse"), isOn: Binding(
                    get: { clip.isReverse },
                    set: { _ in ReverseManager.shared.toggle(clip) }))
                    .font(.system(size: 13)).foregroundColor(.white).tint(Color.mdPrimary)
                if let job {
                    Text(Lf("Processing %@", job.percentText))
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.orange)
                }
            }
        }
    }
}

extension EditingView.Clip {
    /// The label a timeline clip shows: its name, or "Applying Reverse... 52.6%" while a feature is being processed.
    var timelineLabel: String {
        if isReverse, let job = ProcessingTracker.shared.job(source: clipName) { return "\(L("Applying")) \(L(job.feature))… \(job.percentText)" }
        return clipName
    }
}
