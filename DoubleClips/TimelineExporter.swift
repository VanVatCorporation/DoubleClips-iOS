import Foundation
import AVFoundation
import UIKit
import Combine

// MARK: - Timeline export
//
// Android renders with OpenGLEdit / FFmpegEdit, the desktop with an LWJGL compositor or ffmpeg.
// On iOS there is no FFmpeg and OpenGL ES is deprecated, so the one rendering engine here is the
// Core Image `ClipCompositor` that already draws the preview. Export is just that same compositor
// pulled through AVAssetReader and pushed into AVAssetWriter (H.264 + AAC in an .mp4):
//
//   CompositionBuilder (shared with the preview)
//        -> AVAssetReaderVideoCompositionOutput  (frames drawn by ClipCompositor)
//        -> AVAssetWriterInput (H.264)  ┐
//        -> AVAssetReaderAudioMixOutput -> AVAssetWriterInput (AAC) ┴-> .mp4
//
// Because the preview and the exporter share the builder and the compositor, a frame you see in
// the editor is the frame you get in the file.

// MARK: Quality / plan

enum ExportQuality: String, CaseIterable, Identifiable {
    case standard, high, maximum
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high:     return "High"
        case .maximum:  return "Maximum"
        }
    }
    
    /// Lower CRF = better quality. Standard uses the project's own CRF (Android's meaning of it).
    func crf(projectCRF: Int) -> Int {
        switch self {
        case .standard: return projectCRF
        case .high:     return max(0, projectCRF - Constants.EXPORT_CRF_STEP_HIGH)
        case .maximum:  return max(0, projectCRF - Constants.EXPORT_CRF_STEP_MAX)
        }
    }
}

struct ExportPlan {
    let width: Int
    let height: Int
    let frameRate: Int
    let videoBitrate: Int
    let durationSeconds: Double
    
    /// Rough size of the finished file (video + audio), for the pre-export estimate and the
    /// free-space check. VBR output lands close to, but not exactly on, this.
    var estimatedBytes: Int64 {
        Int64(Double(videoBitrate + Constants.EXPORT_AUDIO_BITRATE) / 8.0 * max(durationSeconds, 0))
    }
    
    static func make(settings: EditingView.VideoSettings, quality: ExportQuality, duration: Double) -> ExportPlan {
        // H.264 wants even dimensions; the render size is set to exactly this before export.
        let w = max(2, settings.videoWidth & ~1)
        let h = max(2, settings.videoHeight & ~1)
        let fps = max(1, settings.frameRate)
        let crf = Double(quality.crf(projectCRF: settings.crf))
        let bitsPerPixel = Constants.EXPORT_BPP_AT_CRF23 * pow(2.0, (23.0 - crf) / 6.0)
        let raw = Double(w) * Double(h) * Double(fps) * bitsPerPixel
        let clamped = min(max(Int(raw), Constants.EXPORT_MIN_VIDEO_BITRATE), Constants.EXPORT_MAX_VIDEO_BITRATE)
        return ExportPlan(width: w, height: h, frameRate: fps, videoBitrate: clamped, durationSeconds: duration)
    }
}

struct ExportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: Thread-safe cancel flag

private final class ExportControl {
    private let lock = NSLock()
    private var _cancelled = false
    private var _reason: String?
    
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var reason: String? { lock.lock(); defer { lock.unlock() }; return _reason }
    
    func cancel(reason: String? = nil) {
        lock.lock()
        _cancelled = true
        if _reason == nil { _reason = reason }
        lock.unlock()
    }
}

/// Guards against a pump closure finishing its input twice.
private final class PumpState {
    var done = false
}

// MARK: Exporter

final class TimelineExporter: ObservableObject {
    
    enum State: Equatable {
        case idle
        case exporting
        case finished(URL)
        case failed(String)
        case cancelled
    }
    
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    
    private let workQueue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.export", qos: .userInitiated)
    private var control = ExportControl()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var backgroundObserver: NSObjectProtocol?
    
    deinit {
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }
    
    // MARK: API (main thread)
    
    func start(built: EditingView.BuiltComposition, plan: ExportPlan, fileName: String) {
        guard state != .exporting else { return }
        
        guard let videoComposition = built.videoComposition, built.composition.duration.seconds > 0 else {
            state = .failed("Nothing to export yet. Add a video, image or text clip to the timeline first.")
            return
        }
        
        let url: URL
        do {
            url = try Self.prepareOutputURL(fileName: fileName)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        
        // Free space: the estimate plus a safety margin, so a full disk fails here, not at 90 %.
        if let available = Self.availableBytes(), available < Int64(Double(plan.estimatedBytes) * 1.3) + 50_000_000 {
            state = .failed("Not enough free storage. This export needs about "
                            + Self.formatBytes(plan.estimatedBytes) + " of free space.")
            return
        }
        
        // `built` is private to this export (the builder makes a fresh video composition per call),
        // so it is safe to adjust it here: H.264 needs even dimensions.
        videoComposition.renderSize = CGSize(width: plan.width, height: plan.height)
        
        control = ExportControl()
        progress = 0
        state = .exporting
        
        // Keep the screen on, and stop cleanly if the app is backgrounded: iOS doesn't let apps
        // submit GPU work (Core Image / Metal) from the background, so the render would fail anyway.
        UIApplication.shared.isIdleTimerDisabled = true
        let activeControl = control
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            activeControl.cancel(reason: "Export stopped because DoubleClips went to the background. Keep the app open while exporting and try again.")
            self?.reader?.cancelReading()
        }
        
        let composition = built.composition
        workQueue.async { [weak self] in
            self?.run(composition: composition, videoComposition: videoComposition, plan: plan,
                      url: url, control: activeControl)
        }
    }
    
    func cancel() {
        guard state == .exporting else { return }
        control.cancel()
        reader?.cancelReading()
    }
    
    func reset() {
        guard state != .exporting else { return }
        progress = 0
        state = .idle
    }
    
    // MARK: Pipeline (work queue)
    
    private func run(composition: AVAsset, videoComposition: AVVideoComposition, plan: ExportPlan,
                     url: URL, control: ExportControl) {
        do {
            // ── Reader: frames come out of ClipCompositor, audio out of the composition's mix.
            let reader = try AVAssetReader(asset: composition)
            
            let videoTracks = composition.tracks(withMediaType: .video)
            guard !videoTracks.isEmpty else { throw ExportError("The timeline has no video to render.") }
            
            let videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            videoOutput.videoComposition = videoComposition
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw ExportError("The video track could not be read.") }
            reader.add(videoOutput)
            
            var audioOutput: AVAssetReaderAudioMixOutput?
            let audioTracks = composition.tracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                let pcm: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Constants.EXPORT_AUDIO_SAMPLE_RATE,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                    audioOutput = output
                }
            }
            
            // ── Writer: H.264 + AAC in .mp4
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: plan.frameRate * Constants.EXPORT_KEYFRAME_SECONDS
                ] as [String: Any]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw ExportError("The video encoder rejected these settings.") }
            writer.add(videoInput)
            
            var audioInput: AVAssetWriterInput?
            if audioOutput != nil {
                let aac: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Constants.EXPORT_AUDIO_SAMPLE_RATE,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: Constants.EXPORT_AUDIO_BITRATE
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
            
            guard reader.startReading() else {
                throw reader.error ?? ExportError("The timeline could not be read for export.")
            }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw writer.error ?? ExportError("The output file could not be created.")
            }
            writer.startSession(atSourceTime: .zero)
            
            DispatchQueue.main.async { [weak self] in
                self?.reader = reader
                self?.writer = writer
            }
            
            // ── Pump both streams until they run dry.
            let total = max(composition.duration.seconds, 0.001)
            let group = DispatchGroup()
            
            pump(output: videoOutput, input: videoInput, label: "video", group: group, control: control) { [weak self] pts in
                self?.report(progress: pts / total)
            }
            if let audioOutput, let audioInput {
                pump(output: audioOutput, input: audioInput, label: "audio", group: group, control: control, onSample: nil)
            }
            
            group.notify(queue: workQueue) { [weak self] in
                guard let self else { return }
                
                if control.isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    if let reason = control.reason {
                        self.finish(.failed(reason))
                    } else {
                        self.finish(.cancelled)
                    }
                    return
                }
                if writer.status == .failed {
                    reader.cancelReading()
                    try? FileManager.default.removeItem(at: url)
                    self.finish(.failed(Self.describe(writer.error)))
                    return
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    self.finish(.failed(Self.describe(reader.error)))
                    return
                }
                
                writer.finishWriting {
                    if writer.status == .completed {
                        self.finish(.finished(url))
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        self.finish(.failed(Self.describe(writer.error)))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            finish(.failed(Self.describe(error)))
        }
    }
    
    /// Moves samples from a reader output to a writer input whenever the writer is ready.
    private func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String,
                      group: DispatchGroup, control: ExportControl, onSample: ((Double) -> Void)?) {
        let queue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.export.\(label)")
        let state = PumpState()
        group.enter()
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData && !state.done {
                var keepGoing = true
                autoreleasepool {
                    if control.isCancelled {
                        keepGoing = false
                    } else if let sample = output.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if input.append(sample) {
                            onSample?(pts)
                        } else {
                            keepGoing = false      // writer failed; status is checked afterwards
                        }
                    } else {
                        keepGoing = false          // end of stream (or reader cancelled / failed)
                    }
                }
                if !keepGoing {
                    state.done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }
    
    // MARK: Main-thread updates
    
    private var lastReported: Double = -1
    
    private func report(progress value: Double) {
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .exporting, clamped - self.lastReported >= 0.005 || clamped >= 1 else { return }
            self.lastReported = clamped
            self.progress = clamped
        }
    }
    
    private func finish(_ newState: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if case .finished = newState { self.progress = 1 }
            self.state = newState
            self.lastReported = -1
            self.reader = nil
            self.writer = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if let observer = self.backgroundObserver {
                NotificationCenter.default.removeObserver(observer)
                self.backgroundObserver = nil
            }
        }
    }
    
    // MARK: Files
    
    /// <tmp>/DoubleClips-Export/<name>.mp4 — older exports are removed first so they don't pile up.
    private static func prepareOutputURL(fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Constants.EXPORT_TEMP_DIRECTORY, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
    
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "Export failed for an unknown reason." }
        let ns = error as NSError
        // Surface the underlying AVFoundation reason when there is one: "Cannot Encode" alone helps nobody.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(ns.localizedDescription) (\(underlying.localizedDescription))"
        }
        return ns.localizedDescription
    }
}
