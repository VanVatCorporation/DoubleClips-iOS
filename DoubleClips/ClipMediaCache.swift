import UIKit
import AVFoundation
import ImageIO
import CryptoKit

// MARK: - Clip thumbnails + audio waveforms (cache + generation)
//
// Android: MediaMetadataRetriever frames (1 per second, stretched FIT_XY) + AudioUtils
//          .generateAudioWaveformBitmap (bitmap regenerated per clip / zoom).
// Desktop: ClipNode — a CapCut-style strip of fixed 16:9 tiles, count follows the width.
// iOS:     the desktop's tiling, and a waveform that is computed ONCE per audio file as a compact
//          RMS envelope and drawn as vectors, so zooming/trimming never decodes anything again.
//
// Everything is cached in memory and on disk (Caches/ClipMedia), keyed by file name + size +
// modification date — never by absolute path, which changes when the app container moves.

/// RMS envelope of one audio file: `binsPerSecond` values (0...65535 = 0...1) over the WHOLE file.
final class WaveformEnvelope {
    let binsPerSecond: Int
    let values: [UInt16]
    
    init(binsPerSecond: Int, values: [UInt16]) {
        self.binsPerSecond = binsPerSecond
        self.values = values
    }
    
    /// RMS (0...1) over [t0, t1] seconds of the source: sqrt(mean(square)), the same measure
    /// AudioUtils.generateAudioWaveformBitmap uses per bar (bins are equal-sized, so the mean of
    /// the bin energies is the energy of the whole span).
    func rms(from t0: Double, to t1: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let scale = Double(binsPerSecond)
        let lo = max(0, Int((t0 * scale).rounded(.down)))
        let hi = min(values.count, max(lo + 1, Int((t1 * scale).rounded(.up))))
        guard lo < hi else { return 0 }
        var energy = 0.0
        for i in lo..<hi {
            let v = Double(values[i]) / 65535
            energy += v * v
        }
        return Float((energy / Double(hi - lo)).squareRoot())
    }
}

private final class CancelFlag {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class ClipMediaCache {
    static let shared = ClipMediaCache()
    
    private let lock = NSLock()
    private var fileKeys: [URL: String] = [:]
    private var inflightWaveforms: [String: Task<WaveformEnvelope?, Never>] = [:]
    
    private let thumbMemory = NSCache<NSString, UIImage>()
    private let waveMemory = NSCache<NSString, WaveformEnvelope>()
    private let thumbQueue = DispatchQueue(label: "com.vanvatcorporation.doubleclips.thumbnails", qos: .utility)
    private var generators: [URL: AVAssetImageGenerator] = [:]   // thumbQueue only
    private var failedThumbs = Set<String>()                      // thumbQueue only
    
    private let root: URL
    private static let binsPerSecond = 200                        // 5 ms per bin
    
    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appendingPathComponent("ClipMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        thumbMemory.totalCostLimit = 96 * 1024 * 1024
        waveMemory.countLimit = 64
    }
    
    // MARK: Keys
    
    private func fileKey(_ url: URL) -> String {
        lock.lock()
        if let known = fileKeys[url] { lock.unlock(); return known }
        lock.unlock()
        
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        let key = SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        
        lock.lock(); fileKeys[url] = key; lock.unlock()
        return key
    }
    
    // MARK: Thumbnails
    
    /// One tile image. `time` is in SOURCE seconds (callers quantise it so zooming reuses frames).
    func thumbnail(url: URL, isVideo: Bool, time: Double) async -> UIImage? {
        let key = fileKey(url)
        let millis = isVideo ? Int((max(time, 0) * 1000).rounded()) : 0
        let memoryKey = "\(key)|\(millis)" as NSString
        if let hit = thumbMemory.object(forKey: memoryKey) { return hit }
        
        let cancel = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                thumbQueue.async {
                    // Scrolled away before we got to it: skip the (slow) frame extraction.
                    if cancel.isCancelled { continuation.resume(returning: nil); return }
                    let image = self.loadThumbnail(url: url, isVideo: isVideo, millis: millis, key: key)
                    if let image {
                        self.thumbMemory.setObject(image, forKey: memoryKey,
                                                   cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
                    }
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }
    
    /// On `thumbQueue`.
    private func loadThumbnail(url: URL, isVideo: Bool, millis: Int, key: String) -> UIImage? {
        let diskDir = root.appendingPathComponent("thumbs", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        let diskURL = diskDir.appendingPathComponent("\(millis).jpg")
        if let data = try? Data(contentsOf: diskURL), let cached = UIImage(data: data) { return cached }
        
        let failKey = "\(key)|\(millis)"
        if failedThumbs.contains(failKey) { return nil }
        
        let cgImage: CGImage?
        if isVideo {
            cgImage = videoFrame(url: url, seconds: Double(millis) / 1000)
        } else {
            // ImageIO decodes straight to thumbnail size: a 48 MP photo never becomes a 190 MB bitmap.
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                ] as CFDictionary)
            } else {
                cgImage = nil
            }
        }
        guard let cgImage else { failedThumbs.insert(failKey); return nil }
        
        let image = UIImage(cgImage: cgImage)
        if let jpeg = image.jpegData(compressionQuality: 0.7) {
            try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
            try? jpeg.write(to: diskURL, options: .atomic)
        }
        return image
    }
    
    private func videoFrame(url: URL, seconds: Double) -> CGImage? {
        let generator: AVAssetImageGenerator
        if let existing = generators[url] {
            generator = existing
        } else {
            if generators.count > 8 { generators.removeAll() }
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true          // portrait clips upright
            // A thumbnail doesn't need the exact frame: letting it snap to a nearby keyframe
            // is several times faster than decoding up to the requested frame.
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            generator.maximumSize = CGSize(width: 480, height: 480)
            generators[url] = generator
        }
        return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }
    
    // MARK: Waveform
    
    /// Shared per file: split clips of one audio file (and every redraw) wait for the same single decode.
    func waveform(for url: URL) async -> WaveformEnvelope? {
        let key = fileKey(url)
        if let hit = waveMemory.object(forKey: key as NSString) { return hit }
        
        lock.lock()
        let task: Task<WaveformEnvelope?, Never>
        if let running = inflightWaveforms[key] {
            task = running
        } else {
            task = Task.detached(priority: .utility) { [self] in
                let envelope = loadOrComputeWaveform(url: url, key: key)
                if let envelope { waveMemory.setObject(envelope, forKey: key as NSString) }
                lock.lock(); inflightWaveforms[key] = nil; lock.unlock()
                return envelope
            }
            inflightWaveforms[key] = task
        }
        lock.unlock()
        return await task.value
    }
    
    private func loadOrComputeWaveform(url: URL, key: String) -> WaveformEnvelope? {
        let cacheURL = root.appendingPathComponent("waveforms", isDirectory: true).appendingPathComponent("\(key).wf")
        if let cached = readEnvelope(at: cacheURL) { return cached }
        guard let computed = computeEnvelope(url: url) else { return nil }
        writeEnvelope(computed, to: cacheURL)
        return computed
    }
    
    /// Decodes the whole audio track once, at 8 kHz mono (plenty for an energy envelope, and a
    /// fraction of the decode cost of full rate), and reduces it to RMS per 5 ms.
    private func computeEnvelope(url: URL) -> WaveformEnvelope? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        
        let sampleRate = 8_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,                       // the decoder mixes channels down for us
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        
        let samplesPerBin = sampleRate / Self.binsPerSecond
        var values: [UInt16] = []
        var energy = 0.0
        var inBin = 0
        
        func closeBin() {
            let rms = (energy / Double(max(inBin, 1))).squareRoot() / 32768
            values.append(UInt16(min(1, rms) * 65535))
            energy = 0
            inBin = 0
        }
        
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            
            data.withUnsafeBytes { raw in
                for sampleValue in raw.bindMemory(to: Int16.self) {
                    let v = Double(sampleValue)
                    energy += v * v
                    inBin += 1
                    if inBin == samplesPerBin { closeBin() }
                }
            }
        }
        if inBin > 0 { closeBin() }
        
        guard reader.status != .failed, !values.isEmpty else { return nil }
        return WaveformEnvelope(binsPerSecond: Self.binsPerSecond, values: values)
    }
    
    // File format: "DCW1" | UInt32 binsPerSecond | UInt32 count | count x UInt16 (little endian).
    private func writeEnvelope(_ envelope: WaveformEnvelope, to url: URL) {
        var data = Data("DCW1".utf8)
        for number in [UInt32(envelope.binsPerSecond), UInt32(envelope.values.count)] {
            withUnsafeBytes(of: number.littleEndian) { data.append(contentsOf: $0) }
        }
        envelope.values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
    
    private func readEnvelope(at url: URL) -> WaveformEnvelope? {
        guard let data = try? Data(contentsOf: url), data.count >= 12,
              data.prefix(4) == Data("DCW1".utf8) else { return nil }
        func le32(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
                | Int(data[data.startIndex + offset + 2]) << 16 | Int(data[data.startIndex + offset + 3]) << 24
        }
        let bins = le32(4), count = le32(8)
        guard bins > 0, count > 0, data.count == 12 + count * 2 else { return nil }
        let payload = Data(data.dropFirst(12))                    // re-based copy: aligned for UInt16
        let values = payload.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return WaveformEnvelope(binsPerSecond: bins, values: values)
    }
}
