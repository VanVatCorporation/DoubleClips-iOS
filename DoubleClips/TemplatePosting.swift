import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Posting a template: what is posted, packaging it, uploading it
//
// Android's PostTemplateActivity / ExportActivity.uploadTemplateNecessityItems, for a timeline template:
//
//   fields   accountUsername, accountPassword (placeholder), templateTitle, templateDescription,
//            templateTimelineJson, templateTotalClips      (no ffmpegCommand: iOS has no FFmpeg, so it is NULL)
//   files    videoFiles    the template's resources: locked clips' media, audio, fonts (flat names)
//            previewFiles  preview.png, then preview.mp4
//
// The timeline goes up wrapped as {"format":1,"settings":{canvas},"timeline":{...}} (see the contract).

/// One file in the upload: where it is on disk and the name it is posted under.
struct PostFile {
    let url: URL
    let name: String
    var mimeType: String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Everything the 4-step post screen needs.
struct PostTemplateDraft: Identifiable {
    let id = UUID()
    var defaultTitle: String
    var previewVideo: URL
    var previewImage: URL?
    var contentFiles: [PostFile]
    var timelineJSON: String
    var replaceableCount: Int
    var lockedCount: Int
    var duration: Double
    /// Things the author should know (a missing file that was skipped, a file that had to be renamed).
    var warnings: [String]
    
    var contentBytes: Int64 {
        contentFiles.reduce(0) { $0 + (ExportSheetView.fileSize($1.url) ?? 0) }
    }
}

enum TemplatePackager {
    
    struct PackageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    
    /// Wrapper around the timeline: the canvas the template was made for travels with it.
    private struct TemplateDocument: Encodable {
        struct Canvas: Encodable {
            let videoWidth: Int
            let videoHeight: Int
            let frameRate: Int
            let isStretchToFull: Bool
        }
        let format: Int
        let settings: Canvas
        let timeline: EditingView.Timeline
    }
    
    /// A name the server will keep as it is: it strips a leading "123-" (it thinks that's a timestamp) and
    /// busboy mangles non-ASCII names, so both are rewritten (and the timeline is pointed at the new name).
    static func safeName(_ name: String) -> String {
        var base = name.folding(options: .diacriticInsensitive, locale: nil)
        base = base.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._- ()")
        base = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if base.range(of: #"^\d+-"#, options: .regularExpression) != nil { base = "f_" + base }
        return base.isEmpty ? "file" : base
    }
    
    /// Copies the exported video to the project's preview.mp4, makes sure preview.png exists, collects the
    /// files the template needs and the timeline JSON. Throws when there is nothing for a user to replace.
    @MainActor
    static func makeDraft(project: ProjectData, timeline: EditingView.Timeline,
                          settings: EditingView.VideoSettings, exportedVideo: URL) async throws -> PostTemplateDraft {
        let projectURL = URL(fileURLWithPath: project.projectPath)
        let fm = FileManager.default
        
        let info = TemplateTimelineInfo.make(from: timeline)
        guard !info.slots.isEmpty else {
            throw PackageError(message: "Nothing in this project can be replaced. Turn off \"Lock media for template\" on at least one video or image clip.")
        }
        guard timeline.duration > 0 else { throw PackageError(message: "The timeline is empty.") }
        
        // 1. preview.mp4 (Android renames export.mp4 to preview.mp4)
        let previewVideo = projectURL.appendingPathComponent(Constants.DEFAULT_PREVIEW_CLIP_FILENAME)
        try? fm.removeItem(at: previewVideo)
        try fm.copyItem(at: exportedVideo, to: previewVideo)
        
        // 2. preview.png: the one the project list shows, else the video's first moments
        let previewImage = projectURL.appendingPathComponent("preview.png")
        if !fm.fileExists(atPath: previewImage.path) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: previewVideo))
            generator.appliesPreferredTrackTransform = true
            if let cg = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image,
               let data = UIImage(cgImage: cg).pngData() {
                try? data.write(to: previewImage, options: .atomic)
            }
        }
        
        // 3. The resources: locked clips' media, audio, fonts. Replaceable clips' media stays on the device.
        var warnings: [String] = []
        var files: [PostFile] = []
        var usedNames = Set<String>()
        var renamedClips: [String: String] = [:]      // clipName -> posted name
        var renamedFonts: [String: String] = [:]      // "Fonts/X.ttf" -> "Fonts/Y.ttf"
        var seenSources = Set<String>()
        
        func add(source: URL, originalName: String) -> String? {
            guard seenSources.insert(source.path).inserted else {
                return files.first { $0.url.path == source.path }?.name
            }
            guard fm.fileExists(atPath: source.path) else {
                warnings.append("\(originalName) is missing, so it was left out.")
                return nil
            }
            var name = safeName(originalName)
            var counter = 1
            while !usedNames.insert(name.lowercased()).inserted {
                name = "\((safeName(originalName) as NSString).deletingPathExtension) (\(counter)).\((originalName as NSString).pathExtension)"
                counter += 1
            }
            if name != originalName { warnings.append("\(originalName) was renamed to \(name) for the upload.") }
            files.append(PostFile(url: source, name: name))
            return name
        }
        
        let clips = timeline.tracks.flatMap { $0.clips }
        var lockedCount = 0
        for clip in clips {
            switch TemplateClipRole.role(of: clip) {
            case .locked, .audio:
                if TemplateClipRole.role(of: clip) == .locked { lockedCount += 1 }
                let source = projectURL.appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY).appendingPathComponent(clip.clipName)
                if let posted = add(source: source, originalName: clip.clipName), posted != clip.clipName {
                    renamedClips[clip.clipName] = posted
                }
            case .text:
                if let fontFile = clip.textStyle?.fontFile, !fontFile.isEmpty {
                    let source = projectURL.appendingPathComponent(fontFile)
                    if let posted = add(source: source, originalName: (fontFile as NSString).lastPathComponent),
                       posted != (fontFile as NSString).lastPathComponent {
                        renamedFonts[fontFile] = Constants.PROJECT_FONTS_DIRECTORY + "/" + posted
                    }
                }
            default:
                break
            }
        }
        
        // 4. The timeline JSON, pointed at the posted names when any had to change (on a copy: the
        //    project's own timeline is left alone).
        var exported = timeline
        if !renamedClips.isEmpty || !renamedFonts.isEmpty {
            let copy = try JSONDecoder().decode(EditingView.Timeline.self, from: JSONEncoder().encode(timeline))
            for clip in copy.tracks.flatMap({ $0.clips }) {
                if let posted = renamedClips[clip.clipName], clip.type != .text { clip.clipName = posted }
                if let font = clip.textStyle?.fontFile, let posted = renamedFonts[font] { clip.textStyle?.fontFile = posted }
            }
            exported = copy
        }
        let document = TemplateDocument(
            format: Constants.TEMPLATE_DOCUMENT_FORMAT,
            settings: .init(videoWidth: settings.videoWidth, videoHeight: settings.videoHeight,
                            frameRate: settings.frameRate, isStretchToFull: settings.isStretchToFull),
            timeline: exported)
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        
        return PostTemplateDraft(
            defaultTitle: project.projectTitle,
            previewVideo: previewVideo,
            previewImage: fm.fileExists(atPath: previewImage.path) ? previewImage : nil,
            contentFiles: files,
            timelineJSON: json,
            replaceableCount: info.slots.count,
            lockedCount: lockedCount,
            duration: Double(timeline.duration),
            warnings: warnings)
    }
}

// MARK: - Upload

/// multipart/form-data upload with progress. The body is written to a temporary file first (videos are big,
/// they are never held in memory) and sent from that file.
final class TemplateUploader: NSObject, ObservableObject, URLSessionDataDelegate {
    
    enum State: Equatable {
        case idle
        case uploading
        case failed(String)
        /// The template id the server gave (may be "" if the answer couldn't be read).
        case done(String)
    }
    
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    
    private var session: URLSession!
    private var task: URLSessionUploadTask?
    private var bodyURL: URL?
    private var received = Data()
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }
    
    func reset() {
        cancel()
        state = .idle
        progress = 0
    }
    
    func cancel() {
        task?.cancel()
        task = nil
        removeBody()
    }
    
    func upload(to url: URL, fields: [(String, String)], files: [(field: String, file: PostFile)]) {
        cancel()
        state = .uploading
        progress = 0
        received = Data()
        
        let boundary = "DoubleClips-\(UUID().uuidString)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let body = try Self.writeBody(boundary: boundary, fields: fields, files: files)
                DispatchQueue.main.async {
                    guard let self, self.state == .uploading else { try? FileManager.default.removeItem(at: body); return }
                    self.bodyURL = body
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                    let task = self.session.uploadTask(with: request, fromFile: body)
                    self.task = task
                    task.resume()
                }
            } catch {
                DispatchQueue.main.async { self?.state = .failed(error.localizedDescription) }
            }
        }
    }
    
    private func removeBody() {
        if let bodyURL { try? FileManager.default.removeItem(at: bodyURL) }
        bodyURL = nil
    }
    
    /// Streams the whole request body into a temporary file.
    private static func writeBody(boundary: String, fields: [(String, String)],
                                  files: [(field: String, file: PostFile)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("post-template-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        
        func write(_ text: String) { out.write(Data(text.utf8)) }
        for (name, value) in fields {
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for (field, file) in files {
            let safe = file.name.replacingOccurrences(of: "\"", with: "%22")
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safe)\"\r\n")
            write("Content-Type: \(file.mimeType)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: Constants.TEMPLATE_UPLOAD_CHUNK_BYTES), !chunk.isEmpty {
                out.write(chunk)
            }
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        return url
    }
    
    // MARK: URLSession delegate
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { removeBody(); self.task = nil }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            state = .failed(error.localizedDescription)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            state = .failed("Server returned non-OK status: \(status)")
            return
        }
        progress = 1
        let id = ((try? JSONSerialization.jsonObject(with: received)) as? [String: Any])?["templateId"] as? String
        state = .done(id ?? "")
    }
}
