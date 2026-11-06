import Foundation

// MARK: - Making the playable copy of a format iOS can't open
//
// `syncAll()` runs when the editor opens: every clip whose file needs a converted copy (MediaCompat) and doesn't have it yet gets one
// (the black clips of a project made on the desktop). The Project Files import starts one for each file it imports, and importing
// straight onto the timeline waits for it (`convertAndWait`). Progress shows where Reverse's does: preview badge, "Converting... 52.6%"
// on the clip. When a copy is ready the preview is rebuilt and the clip plays.
//
// What FFmpeg does, in order of preference (fast and lossless first):
//   video  H.264 / HEVC that AVFoundation can decode -> copied into an MP4 (seconds, no quality loss); anything else -> re-encoded with
//          the hardware H.264 encoder (h264_videotoolbox), pixels squared and 4:2:0
//   audio  AAC / MP3 / AC3 / E-AC3 / ALAC -> copied; anything else (Opus, Vorbis, FLAC, WMA, DTS, PCM ...) -> AAC 192 kbps
// Only the first video and the first audio stream are kept (no subtitles or extra tracks).

final class ConvertManager {
    static let shared = ConvertManager()
    static let feature = "Convert"

    struct Context {
        let projectPath: String
        let timeline: EditingView.Timeline
        let onChanged: () -> Void
    }

    private var context: Context?
    private var waiters: [String: [CheckedContinuation<Bool, Never>]] = [:]

    func configure(projectPath: String, timeline: EditingView.Timeline, onChanged: @escaping () -> Void) {
        context = Context(projectPath: projectPath, timeline: timeline, onChanged: onChanged)
    }

    private var folder: URL? {
        context.map { URL(fileURLWithPath: $0.projectPath).appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY) }
    }

    /// Every clip of this project that needs a copy and doesn't have one yet.
    func syncAll() {
        guard let context else { return }
        var seen = Set<String>()
        for track in context.timeline.tracks {
            for clip in track.clips where clip.type == .video || clip.type == .audio {
                if MediaCompat.needsConversion(clip.clipName), seen.insert(clip.clipName).inserted { _ = ensure(source: clip.clipName) }
            }
        }
    }

    /// Makes sure the converted copy of `source` exists or is being made. True: it exists or the job runs; false: it can't be started.
    @discardableResult
    func ensure(source: String) -> Bool {
        guard let folder, let copyName = MediaCompat.convertedName(for: source) else { return false }
        let tracker = ProcessingTracker.shared
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(copyName).path) { return true }
        if tracker.job(source: source, feature: Self.feature) != nil { return true }

        let job = tracker.begin(source: source, feature: Self.feature)
        guard FFmpegBackend.isAvailable else {
            tracker.fail(job, L("FFmpeg isn't installed in this build, so this format can't be converted yet."))
            return false
        }
        let sourceURL = folder.appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            tracker.fail(job, L("The clip's file is missing."))
            return false
        }
        let finalURL = folder.appendingPathComponent(copyName)
        let partialURL = folder.appendingPathComponent(copyName + ".partial")
        let audioOnly = copyName.hasSuffix(".m4a")

        DispatchQueue.global(qos: .default).async { [weak self] in
            var failure: String?
            do {
                guard let info = FFmpegBackend.probe(sourceURL) else { throw FFError(message: L("This file can't be read.")) }
                let command = Self.command(input: sourceURL, output: partialURL, info: info, audioOnly: audioOnly)
                try? FileManager.default.removeItem(at: partialURL)
                let result = FFmpegBackend.run(command, duration: info.duration,
                                               progress: { p in DispatchQueue.main.async { tracker.update(job, progress: p) } },
                                               isCancelled: { job.isCancelled })
                if case .failure(let error) = result { throw error }
                if job.isCancelled { throw FFError(message: "Cancelled") }
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                failure = (error as? FFError)?.message ?? error.localizedDescription
            }
            DispatchQueue.main.async { self?.finished(job, source: source, failure: failure) }
        }
        return true
    }

    /// Converts and waits (importing straight onto the timeline needs the copy's duration). False when it could not be made.
    func convertAndWait(source: String) async -> Bool {
        guard let folder, let copyName = MediaCompat.convertedName(for: source) else { return false }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(copyName).path) { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {          // the job table and the waiters live on the main thread
                self.waiters[source, default: []].append(continuation)
                if !self.ensure(source: source) { self.resume(source, false) }
            }
        }
    }

    private func finished(_ job: ProcessingTracker.Job, source: String, failure: String?) {
        let tracker = ProcessingTracker.shared
        if job.isCancelled {
            tracker.cancel(job)
            resume(source, false)
            return
        }
        if let failure {
            tracker.fail(job, failure)
            resume(source, false)
            return
        }
        tracker.finish(job)
        context?.onChanged()           // the preview is rebuilt: the clip plays now
        resume(source, true)
    }

    private func resume(_ source: String, _ ok: Bool) {
        let list = waiters.removeValue(forKey: source) ?? []
        for continuation in list { continuation.resume(returning: ok) }
    }

    // MARK: the ffmpeg command

    private static let copyVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let copyAudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]

    static func command(input: URL, output: URL, info: FFInfo, audioOnly: Bool) -> String {
        let q = FFmpegBackend.quote
        let video = info.streams.first { $0.type == "video" && !$0.attachedPicture }
        let audio = info.streams.first { $0.type == "audio" }
        var args = ["-y", "-fflags", "+genpts", "-i", q(input.path)]

        if audioOnly || (video == nil && audio != nil) {
            // audio file: AAC in an M4A
            args += ["-vn", "-sn", "-dn", "-map", "0:a:0"]
            args += audioArguments(audio, forceReencode: !["aac", "alac"].contains(audio?.codec ?? ""))      // M4A holds AAC / ALAC only
            args += ["-f", "ipod", q(output.path)]
            return args.joined(separator: " ")
        }

        args += ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if let video, canCopy(video) {
            args += ["-c:v", "copy", "-tag:v", video.codec == "hevc" ? "hvc1" : "avc1", "-avoid_negative_ts", "make_zero"]
        } else {
            let width = video?.width ?? 1920, height = video?.height ?? 1080
            let source = video?.bitRate ?? info.bitRate ?? 0
            let bitrate = Int(max(2_000_000, min(40_000_000, source > 0 ? source * 1.3 : Double(width * height) * 4)))
            args += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", String(bitrate), "-pix_fmt", "yuv420p", "-tag:v", "avc1",
                     "-vf", q("scale=trunc(iw*sar/2)*2:trunc(ih/2)*2,setsar=1")]
        }
        args += audioArguments(audio, forceReencode: false)
        args += ["-movflags", "+faststart", "-f", "mp4", q(output.path)]
        return args.joined(separator: " ")
    }

    /// H.264 8-bit 4:2:0 (Baseline ... High) and HEVC 4:2:0 (8 or 10 bit, Main / Main 10) are what the hardware decoders take.
    private static func canCopy(_ v: FFStream) -> Bool {
        let pix = v.pixFmt ?? ""
        let profile = (v.profile ?? "").lowercased()
        switch v.codec {
        case "h264":
            return pix == "yuv420p" && ["baseline", "constrained baseline", "main", "high", "extended"].contains(profile)
        case "hevc":
            return ["yuv420p", "yuv420p10le"].contains(pix) && ["main", "main 10"].contains(profile)
        default:
            return false
        }
    }

    private static func audioArguments(_ audio: FFStream?, forceReencode: Bool) -> [String] {
        guard let audio else { return ["-an"] }
        if !forceReencode, copyAudioCodecs.contains(audio.codec) { return ["-c:a", "copy"] }
        return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
    }
}
