import Foundation
#if canImport(ffmpegkit)
import ffmpegkit
#endif

// MARK: - The only file that talks to FFmpeg
//
// Everything FFmpeg-specific is in here, behind `#if canImport(ffmpegkit)`: without the framework the project builds and runs as before
// (`isAvailable` is false and unsupported formats say so). To switch it on build ffmpeg-kit (tools/ffmpeg-kit/README.md) and add its
// xcframeworks to the app target (Frameworks, Embed & Sign). If a ffmpeg-kit call below doesn't match the version you built, this is the
// one place to adjust.

struct FFStream {
    let type: String            // video | audio | subtitle ...
    let codec: String
    let pixFmt: String?
    let profile: String?
    let bitRate: Double?
    let width: Int?
    let height: Int?
    let attachedPicture: Bool
}

struct FFInfo {
    let duration: Double
    let bitRate: Double?
    let streams: [FFStream]
}

struct FFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FFmpegBackend {

    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    #if canImport(ffmpegkit)

    static var isAvailable: Bool { true }

    /// Codecs, sizes and duration of a file (ffprobe's JSON).
    static func probe(_ url: URL) -> FFInfo? {
        let args = "-v error -show_entries stream=codec_type,codec_name,pix_fmt,profile,bit_rate,width,height:stream_disposition=attached_pic:format=duration,bit_rate -of json \(quote(url.path))"
        guard let session = FFprobeKit.execute(args) else { return nil }
        let output = session.getOutput() ?? ""
        guard let data = output.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let format = root["format"] as? [String: Any]
        func number(_ any: Any?) -> Double? {
            if let s = any as? String { return Double(s) }
            return (any as? NSNumber)?.doubleValue
        }
        let streams = (root["streams"] as? [[String: Any]] ?? []).map { s in
            FFStream(type: s["codec_type"] as? String ?? "", codec: s["codec_name"] as? String ?? "",
                     pixFmt: s["pix_fmt"] as? String, profile: s["profile"] as? String, bitRate: number(s["bit_rate"]),
                     width: (s["width"] as? NSNumber)?.intValue, height: (s["height"] as? NSNumber)?.intValue,
                     attachedPicture: ((s["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.intValue == 1)
        }
        return FFInfo(duration: number(format?["duration"]) ?? 0, bitRate: number(format?["bit_rate"]), streams: streams)
    }

    /// Runs an ffmpeg command line and waits for it. `progress` is 0 ... 1 (from the output time against `duration`); `isCancelled` is
    /// asked 4 times a second and stops ffmpeg. Blocking: call it off the main thread.
    static func run(_ command: String, duration: Double, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) -> Result<Void, FFError> {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var tail = ""
        var code: ReturnCode?
        let session = FFmpegKit.executeAsync(command, withCompleteCallback: { finished in
            code = finished?.getReturnCode()
            done.signal()
        }, withLogCallback: { log in
            guard let message = log?.getMessage() else { return }
            lock.lock(); tail = String((tail + message).suffix(1200)); lock.unlock()
        }, withStatisticsCallback: { stats in
            guard duration > 0, let time = stats?.getTime() else { return }
            progress(min(1, max(0, Double(time) / 1000 / duration)))
        })
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled() { cancel(session) }
        }
        if isCancelled() { return .failure(FFError(message: "Cancelled")) }
        if ReturnCode.isSuccess(code) { return .success(()) }
        lock.lock(); defer { lock.unlock() }
        let lines = tail.split(separator: "\n").suffix(3).joined(separator: " ")
        return .failure(FFError(message: lines.isEmpty ? "ffmpeg failed" : String(lines)))
    }

    /// Stops one ffmpeg session. Looked up by name at run time, because the session API differs between ffmpeg-kit versions (this build has
    /// no `getSessionId()`); when the session has no `cancel`, every running session is cancelled instead (the app runs one at a time).
    private static func cancel(_ session: AnyObject?) {
        let selector = NSSelectorFromString("cancel")
        if let session, session.responds(to: selector) {
            _ = session.perform(selector)
        } else {
            FFmpegKit.cancel()
        }
    }

    #else

    static var isAvailable: Bool { false }
    static func probe(_ url: URL) -> FFInfo? { nil }
    static func run(_ command: String, duration: Double, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) -> Result<Void, FFError> {
        .failure(FFError(message: "FFmpeg isn't installed in this build."))
    }

    #endif
}
