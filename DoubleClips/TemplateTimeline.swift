import SwiftUI

// MARK: - Template as a timeline
//
// A template is no longer a hard-coded `ffmpegCommand`: it is a TIMELINE (the same JSON as a project's
// project.timeline) in which every clip has a role for whoever uses the template. The server tells the
// app where that JSON is (`templateTimelineLink`); the preview screen draws it as a strip under the
// video, colour-coded by role, and the "Use template" screen turns the replaceable clips into slots.
//
//   white   a clip the user replaces with their own media (numbered 1, 2, 3 ... in time order)
//   gray    a locked clip (video / image the template keeps; "Lock media for template" in the editor)
//   blue    audio
//   green   effect
//   yellow  text
//   purple  anything else (transitions, 3D scenes)
//
// Templates without a timeline link (the old, ffmpeg kind) still get a strip: one white stripe per clip
// slot, spread evenly over the template's duration, so every template looks the same on that screen.

enum TemplateClipRole: CaseIterable {
    case replaceable, locked, audio, effect, text, other
    
    var color: Color {
        switch self {
        case .replaceable: return .white
        case .locked:      return Color(white: 0.5)
        case .audio:       return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .effect:      return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .text:        return Color(red: 1.0, green: 0.84, blue: 0.2)
        case .other:       return Color(red: 0.7, green: 0.45, blue: 1.0)
        }
    }
    
    var title: String {
        switch self {
        case .replaceable: return "Yours"
        case .locked:      return "Locked"
        case .audio:       return "Audio"
        case .effect:      return "Effect"
        case .text:        return "Text"
        case .other:       return "Other"
        }
    }
    
    /// What a clip of this timeline means to the person using the template.
    static func role(of clip: EditingView.Clip) -> TemplateClipRole {
        switch clip.type {
        case .audio:  return .audio
        case .text:   return .text
        case .effect: return .effect
        case .video, .image: return clip.isLockedForTemplate ? .locked : .replaceable
        case .transition, .scene3D: return .other
        }
    }
}

/// One clip as the strip draws it.
struct TemplateStripClip: Identifiable {
    let id: UUID
    let start: Double
    let duration: Double
    /// Row from the top (timeline order: track 1 first).
    let row: Int
    let role: TemplateClipRole
    /// 1-based number of a replaceable clip, nil for every other role.
    let slotNumber: Int?
}

/// One replaceable clip: what "Use template" asks the user to fill.
struct TemplateSlotInfo: Identifiable {
    let id: UUID                // the clip's id in the template timeline
    let number: Int             // 1-based, time order
    let start: Double
    let duration: Double        // how long the template keeps this clip on screen
    let isImage: Bool           // the template's own clip was a still
}

struct TemplateTimelineInfo {
    var clips: [TemplateStripClip]
    var rowCount: Int
    /// Seconds.
    var duration: Double
    var slots: [TemplateSlotInfo]
    /// The parsed timeline (nil for the legacy strip drawn from the clip count).
    var timeline: EditingView.Timeline?
    
    var roles: [TemplateClipRole] {
        TemplateClipRole.allCases.filter { role in clips.contains { $0.role == role } }
    }
    
    /// The old kind of template: no timeline, only a clip count and a duration.
    static func legacy(_ template: TemplateData) -> TemplateTimelineInfo {
        let total = max(0, template.templateTotalClip)
        let duration = Double(max(0, template.templateDuration)) / 1000
        guard total > 0, duration > 0 else {
            return TemplateTimelineInfo(clips: [], rowCount: 1, duration: duration, slots: [], timeline: nil)
        }
        let each = duration / Double(total)
        var clips: [TemplateStripClip] = []
        var slots: [TemplateSlotInfo] = []
        for i in 0..<total {
            let id = UUID()
            clips.append(TemplateStripClip(id: id, start: Double(i) * each, duration: each, row: 0,
                                           role: .replaceable, slotNumber: i + 1))
            slots.append(TemplateSlotInfo(id: id, number: i + 1, start: Double(i) * each, duration: each, isImage: false))
        }
        return TemplateTimelineInfo(clips: clips, rowCount: 1, duration: duration, slots: slots, timeline: nil)
    }
    
    /// Builds the strip (and the slot list) from a template timeline.
    static func make(from timeline: EditingView.Timeline) -> TemplateTimelineInfo {
        let tracks = timeline.tracks
            .sorted { $0.timelineIndex < $1.timelineIndex }
            .filter { !$0.clips.isEmpty }
        
        // Slots first (time order, then top row first) so the strip can number them.
        struct Candidate { let clip: EditingView.Clip; let row: Int }
        var candidates: [Candidate] = []
        for (row, track) in tracks.enumerated() {
            for clip in track.clips where TemplateClipRole.role(of: clip) == .replaceable {
                candidates.append(Candidate(clip: clip, row: row))
            }
        }
        candidates.sort { a, b in
            a.clip.startTime != b.clip.startTime ? a.clip.startTime < b.clip.startTime : a.row < b.row
        }
        var numbers: [UUID: Int] = [:]
        var slots: [TemplateSlotInfo] = []
        for (i, c) in candidates.enumerated() {
            numbers[c.clip.id] = i + 1
            slots.append(TemplateSlotInfo(id: c.clip.id, number: i + 1, start: Double(c.clip.startTime),
                                          duration: Double(c.clip.duration), isImage: c.clip.type == .image))
        }
        
        var clips: [TemplateStripClip] = []
        var end: Double = 0
        for (row, track) in tracks.enumerated() {
            for clip in track.clips {
                let role = TemplateClipRole.role(of: clip)
                clips.append(TemplateStripClip(id: clip.id, start: Double(clip.startTime), duration: Double(clip.duration),
                                               row: row, role: role, slotNumber: numbers[clip.id]))
                end = max(end, Double(clip.startTime + clip.duration))
            }
        }
        return TemplateTimelineInfo(clips: clips, rowCount: max(1, tracks.count),
                                    duration: max(end, Double(timeline.duration)), slots: slots, timeline: timeline)
    }
}

// MARK: - Loading

enum TemplateTimelineLoader {
    
    enum LoadError: LocalizedError {
        case noLink, badLink, http(Int), notATimeline
        var errorDescription: String? {
            switch self {
            case .noLink: return "This template has no timeline."
            case .badLink: return "The template's timeline link isn't valid."
            case .http(let code): return "The template's timeline couldn't be downloaded (\(code))."
            case .notATimeline: return "The template's timeline file isn't readable."
            }
        }
    }
    
    /// The two shapes the server may send: the project's own timeline JSON (`{"tracks": [...]}`), or a
    /// wrapper `{"format": 1, "timeline": {...}}` that leaves room for more keys later.
    private struct Wrapper: Decodable {
        let timeline: EditingView.Timeline?
    }
    
    static func parse(_ data: Data) throws -> TemplateTimelineInfo {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Wrapper.self, from: data), let timeline = wrapped.timeline {
            return TemplateTimelineInfo.make(from: timeline)
        }
        if let timeline = try? decoder.decode(EditingView.Timeline.self, from: data) {
            return TemplateTimelineInfo.make(from: timeline)
        }
        throw LoadError.notATimeline
    }
    
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Constants.TEMPLATE_TIMELINE_CACHE_FOLDER, isDirectory: true)
    }
    
    /// A cached copy is keyed by the template's id AND timestamp, so an updated template downloads again.
    private static func cacheURL(for template: TemplateData) -> URL {
        let safeID = template.templateId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return cacheDirectory.appendingPathComponent("\(String(safeID))-\(template.templateTimestamp).json")
    }
    
    /// The template's timeline: from the cache when present, else downloaded (and cached).
    static func load(for template: TemplateData) async throws -> TemplateTimelineInfo {
        let link = template.templateTimelineLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { throw LoadError.noLink }
        guard let url = URL(string: link) else { throw LoadError.badLink }
        
        let cached = cacheURL(for: template)
        if let data = try? Data(contentsOf: cached), let info = try? parse(data) { return info }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.http(http.statusCode)
        }
        let info = try parse(data)         // only a readable file is kept
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return info
    }
}
