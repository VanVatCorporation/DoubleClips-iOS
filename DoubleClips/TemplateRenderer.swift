import SwiftUI
import AVFoundation

// MARK: - Rendering a template
//
// "Use template": the template's timeline with the user's media dropped into its replaceable clips, built
// in a temporary project folder and handed to the normal export screen (same engine as the editor).
//
//   1. Fetch a FRESH copy of the template's timeline (each parse makes new clip objects).
//   2. Download the template's resources (locked media, audio, fonts) from `templateContentLink`, cached on
//      the device per template + timestamp, and copy them into the folder's Clips/ and Fonts/.
//   3. Slot i (white stripe i) gets the i-th picked file:
//        - the clip keeps everything about it (position, scale, rotation, keyframes, animations, effects),
//        - the new media is scaled to COVER the template clip's box and centred on it (the position, also
//          in each keyframe, is shifted by the change in the box's centre),
//        - a video keeps the trim the user chose, capped at the slot's length; a shorter one simply ends
//          early (nothing after it moves); a still lasts the slot's whole length.
//   4. project.settings = the screen's export settings (which start as the template's own canvas).

/// A template ready to render.
struct PreparedTemplateRender: Identifiable {
    let id = UUID()
    let project: ProjectData
    let timeline: EditingView.Timeline
    let directory: URL
}

enum TemplateRenderer {
    
    struct RenderError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    
    @MainActor
    static func prepare(template: TemplateData, slots: [TemplateClipSlot], settings: EditingView.VideoSettings,
                        log: @escaping (String) -> Void) async throws -> PreparedTemplateRender {
        let fm = FileManager.default
        
        // 1. A fresh timeline (never the one the screen shows: this one gets edited).
        log("Loading the template's timeline…")
        let info = try await TemplateTimelineLoader.load(for: template)
        guard let timeline = info.timeline else { throw RenderError("This template has no timeline.") }
        guard info.slots.count == slots.count else {
            throw RenderError("The template changed: it now has \(info.slots.count) replaceable clips, not \(slots.count). Reopen it.")
        }
        
        let directory = fm.temporaryDirectory.appendingPathComponent(Constants.TEMPLATE_RENDER_FOLDER_PREFIX + UUID().uuidString,
                                                                      isDirectory: true)
        let clipsDirectory = directory.appendingPathComponent(Constants.DEFAULT_CLIP_DIRECTORY, isDirectory: true)
        let fontsDirectory = directory.appendingPathComponent(Constants.PROJECT_FONTS_DIRECTORY, isDirectory: true)
        try fm.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        
        do {
            // 2. Resources.
            let clips = timeline.tracks.flatMap { $0.clips }
            var needed: [String] = (template.additionalResourceName ?? [])
            for clip in clips {
                switch TemplateClipRole.role(of: clip) {
                case .locked, .audio: needed.append(clip.clipName)
                case .text:
                    if let font = clip.textStyle?.fontFile, !font.isEmpty { needed.append((font as NSString).lastPathComponent) }
                default: break
                }
            }
            var seen = Set<String>()
            let names = needed
                .map { ($0 as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != ".." && $0 != "." && seen.insert($0).inserted }
            try await fetchResources(names, template: template,
                                     clipsDirectory: clipsDirectory, fontsDirectory: fontsDirectory, log: log)
            
            // 3. The user's media into the replaceable clips.
            let canvas = CGSize(width: settings.videoWidth, height: settings.videoHeight)
            for (i, slotInfo) in info.slots.enumerated() {
                let slot = slots[i]
                guard slot.isFilled, let clip = clips.first(where: { $0.id == slotInfo.id }) else {
                    throw RenderError("Clip \(i + 1) is empty.")
                }
                let source = URL(fileURLWithPath: slot.path)
                let ext = source.pathExtension.isEmpty ? (slot.kind == .video ? "mov" : "png") : source.pathExtension.lowercased()
                let name = "template-slot-\(i + 1).\(ext)"
                let destination = clipsDirectory.appendingPathComponent(name)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
                
                let media = await MediaProbe.probe(destination)
                let isVideo = slot.kind == .video
                clip.type = isVideo ? .video : .image
                clip.clipName = name
                retarget(clip, mediaWidth: media.width, mediaHeight: media.height,
                         canvas: canvas, stretchToFull: settings.isStretchToFull)
                
                let target = Float(slotInfo.duration)
                if isVideo {
                    let total = max(0.05, media.duration)
                    let start = min(Float(max(0, slot.startTrim)), max(0, total - 0.05))
                    let wanted = Float(slot.endTrim) > Float(slot.startTrim) ? Float(slot.endTrim) - Float(slot.startTrim) : total - start
                    let length = max(0.05, min(target, min(wanted, total - start)))
                    clip.originalDuration = total
                    clip.startClipTrim = start
                    clip.duration = length
                    clip.endClipTrim = max(0, total - start - length)
                    clip.isClipHasAudio = media.hasAudio
                    clip.audioVolume = media.hasAudio ? 1 : 0
                } else {
                    clip.originalDuration = target
                    clip.startClipTrim = 0
                    clip.endClipTrim = 0
                    clip.duration = target
                    clip.isClipHasAudio = false
                    clip.audioVolume = 0
                }
                log(String(format: "Clip %d placed: %@, %.1fs of %.1fs", i + 1, isVideo ? "video" : "image",
                           clip.duration, target))
            }
            
            // 4. Settings, fonts, the project record.
            let settingsURL = directory.appendingPathComponent(Constants.DEFAULT_VIDEO_SETTINGS_FILENAME)
            try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
            ProjectFonts.registerAll(projectPath: directory.path)
            
            let title = template.templateTitle.isEmpty ? "Template" : template.templateTitle
            let project = ProjectData(projectPath: directory.path, projectTitle: title,
                                      projectTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                      projectSize: 0, projectDuration: Int64(timeline.duration * 1000))
            log("Ready to render.")
            return PreparedTemplateRender(project: project, timeline: timeline, directory: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
    
    static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
    
    // MARK: Resources
    
    private static func resourceCache(for template: TemplateData) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safeID = String(template.templateId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent(Constants.TEMPLATE_RESOURCES_CACHE_FOLDER, isDirectory: true)
            .appendingPathComponent("\(safeID)-\(template.templateTimestamp)", isDirectory: true)
    }
    
    /// Downloads what is not cached yet and copies every resource into the working folder.
    private static func fetchResources(_ names: [String], template: TemplateData,
                                       clipsDirectory: URL, fontsDirectory: URL,
                                       log: @escaping (String) -> Void) async throws {
        guard !names.isEmpty else { return }
        let fm = FileManager.default
        let cache = resourceCache(for: template)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let base = template.resolvedContentLink
        var failed: [String] = []
        
        for (i, name) in names.enumerated() {
            let cached = cache.appendingPathComponent(name)
            if !fm.fileExists(atPath: cached.path) {
                log("Downloading \(name) (\(i + 1)/\(names.count))…")
                guard !base.isEmpty,
                      let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: base + encoded) else { failed.append(name); continue }
                do {
                    let (temp, response) = try await URLSession.shared.download(from: url)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        failed.append("\(name) (\(http.statusCode))")
                        continue
                    }
                    try? fm.removeItem(at: cached)
                    try fm.moveItem(at: temp, to: cached)
                } catch {
                    failed.append("\(name) (\(error.localizedDescription))")
                    continue
                }
            }
            let folder = fontExtensions.contains((name as NSString).pathExtension.lowercased()) ? fontsDirectory : clipsDirectory
            let destination = folder.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: cached, to: destination)
        }
        if !failed.isEmpty {
            throw RenderError("The template's files couldn't be downloaded: " + failed.joined(separator: ", "))
        }
    }
    
    // MARK: Fitting the new media into the template clip's box
    
    /// Gives the clip the new media's shape: scaled to COVER the old box, centred on it. Everything else about
    /// the clip (scale, rotation, pivot, keyframes) is kept; PosX / PosY, in the clip and in each of its
    /// keyframes, move by however much the box's centre moved, so the new picture sits where the old one did.
    private static func retarget(_ clip: EditingView.Clip, mediaWidth: Int, mediaHeight: Int,
                                 canvas: CGSize, stretchToFull: Bool) {
        guard mediaWidth > 0, mediaHeight > 0 else { return }
        let oldW = clip.width, oldH = clip.height
        // Stretch-to-fit draws every clip across the canvas: only the size changes.
        guard !stretchToFull, oldW > 0, oldH > 0 else {
            clip.width = mediaWidth
            clip.height = mediaHeight
            return
        }
        let cover = max(CGFloat(oldW) / CGFloat(mediaWidth), CGFloat(oldH) / CGFloat(mediaHeight))
        let newW = max(1, Int((CGFloat(mediaWidth) * cover).rounded()))
        let newH = max(1, Int((CGFloat(mediaHeight) * cover).rounded()))
        
        func centre(_ properties: EditingView.VideoProperties) -> CGPoint? {
            guard let q = clip.quad(for: properties, canvas: canvas, stretchToFull: stretchToFull), q.count == 4 else { return nil }
            return CGPoint(x: (q[0].x + q[2].x) / 2, y: (q[0].y + q[2].y) / 2)
        }
        let staticBefore = centre(clip.videoProperties)
        let keysBefore = clip.keyframes.keyframes.map { centre($0.value) }
        
        clip.width = newW
        clip.height = newH
        
        if let before = staticBefore, let after = centre(clip.videoProperties) {
            clip.videoProperties.valuePosX += Float(before.x - after.x)
            clip.videoProperties.valuePosY += Float(before.y - after.y)
        }
        for i in clip.keyframes.keyframes.indices {
            guard let before = keysBefore[i], let after = centre(clip.keyframes.keyframes[i].value) else { continue }
            clip.keyframes.keyframes[i].value.valuePosX += Float(before.x - after.x)
            clip.keyframes.keyframes[i].value.valuePosY += Float(before.y - after.y)
        }
    }
}

// MARK: - Use count

enum TemplateUseCounter {
    /// Android / the v1 server: POST /api/increment-use { templateId }. Best effort.
    static func increment(_ templateId: String) {
        guard let url = URL(string: Constants.TEMPLATE_INCREMENT_USE_URL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["templateId": templateId])
        URLSession.shared.dataTask(with: request).resume()
    }
}
