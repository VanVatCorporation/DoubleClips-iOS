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
    /// Id the author's template gave the clips that share one source ("g1", "g2"...); nil = the clip stands alone.
    var group: String? = nil
    /// Where the template's own clip starts inside its source (seconds): where a grouped clip starts by default.
    var sourceTrim: Double = 0
}

struct TemplateTimelineInfo {
    var clips: [TemplateStripClip]
    var rowCount: Int
    /// Seconds.
    var duration: Double
    var slots: [TemplateSlotInfo]
    /// The parsed timeline (nil for the legacy strip drawn from the clip count).
    var timeline: EditingView.Timeline?
    /// The canvas the template was made for (resolution, frame rate, stretch), when the file carries it.
    var canvas: EditingView.VideoSettings?
    
    var roles: [TemplateClipRole] {
        TemplateClipRole.allCases.filter { role in clips.contains { $0.role == role } }
    }
    
    /// The old kind of template: no timeline, only a clip count and a duration.
    /// `duration` (seconds): the preview video's own length, for templates whose `templateDuration` is 0.
    static func legacy(_ template: TemplateData, duration override: Double? = nil) -> TemplateTimelineInfo {
        let total = max(0, template.templateTotalClip)
        let stored = Double(max(0, template.templateDuration)) / 1000
        let duration = stored > 0 ? stored : max(0, override ?? 0)
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
                                          duration: Double(c.clip.duration), isImage: c.clip.type == .image,
                                          group: c.clip.templateGroup, sourceTrim: Double(c.clip.startClipTrim)))
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
        case noLink, badLink, http(Int), notATimeline, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noLink: return "This template has no timeline."
            case .badLink: return "The template's timeline link isn't valid."
            case .http(let code): return "The template's timeline couldn't be downloaded (\(code))."
            case .notATimeline: return "The template's timeline file isn't readable."
            case .unreadable(let start): return "The server's answer isn't a timeline: \(start)"
            }
        }
    }
    
    /// The two shapes the server may send: the project's own timeline JSON (`{"tracks": [...]}`), or a
    /// wrapper `{"format": 1, "timeline": {...}}` that leaves room for more keys later.
    private struct Wrapper: Decodable {
        struct Canvas: Decodable {
            let videoWidth: Int?
            let videoHeight: Int?
            let frameRate: Int?
            let isStretchToFull: Bool?
        }
        let timeline: EditingView.Timeline?
        let settings: Canvas?
    }
    
    /// A timeline stored in a JSON column often comes back wrapped: as a JSON string that holds the JSON
    /// (`"{\"tracks\":[...]}"`), or as an array holding that string. Unwrap down to the timeline itself.
    static func unwrap(_ data: Data, depth: Int = 0) -> Data {
        guard depth < 3,
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        if let text = json as? String, let inner = text.data(using: .utf8) { return unwrap(inner, depth: depth + 1) }
        if let array = json as? [Any], let first = array.first {
            if let text = first as? String, let inner = text.data(using: .utf8) { return unwrap(inner, depth: depth + 1) }
            if JSONSerialization.isValidJSONObject(first), let inner = try? JSONSerialization.data(withJSONObject: first) {
                return inner
            }
        }
        return data
    }
    
    static func parse(_ rawData: Data) throws -> TemplateTimelineInfo {
        let data = unwrap(rawData)
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Wrapper.self, from: data), let timeline = wrapped.timeline {
            var info = TemplateTimelineInfo.make(from: timeline)
            if let c = wrapped.settings {
                var canvas = EditingView.VideoSettings.androidDefault
                if let w = c.videoWidth, w > 0 { canvas.videoWidth = w }
                if let h = c.videoHeight, h > 0 { canvas.videoHeight = h }
                if let f = c.frameRate, f > 0 { canvas.frameRate = f }
                if let s = c.isStretchToFull { canvas.isStretchToFull = s }
                info.canvas = canvas
            }
            return info
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
        let info: TemplateTimelineInfo
        do {
            info = try parse(data)         // only a readable file is kept
        } catch {
            // Say what came back (an error page, `null`, a route that doesn't exist...).
            let start = String(decoding: data.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            throw LoadError.unreadable(start.isEmpty ? "(empty)" : start)
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return info
    }
}

// MARK: - Grouping the same clip (CapCut's "same media" dots)

enum TemplateGrouping {
    
    /// The replaceable clips of a timeline in slot order: time first, then the top row first (the order people see them numbered).
    static func ordered(_ timeline: EditingView.Timeline) -> [(clip: EditingView.Clip, row: Int)] {
        let tracks = timeline.tracks
            .sorted { $0.timelineIndex < $1.timelineIndex }
            .filter { !$0.clips.isEmpty }
        var list: [(clip: EditingView.Clip, row: Int)] = []
        for (row, track) in tracks.enumerated() {
            for clip in track.clips where TemplateClipRole.role(of: clip) == .replaceable {
                list.append((clip, row))
            }
        }
        list.sort { a, b in
            a.clip.startTime != b.clip.startTime ? a.clip.startTime < b.clip.startTime : a.row < b.row
        }
        return list
    }
    
    /// The automatic grouping: clips that share one source (the same file, so the pieces of one split video, or one photo used
    /// many times) get the same key. A clip whose source is used once is left out. Keys are only labels: `apply` makes the ids.
    static func autoAssignment(for timeline: EditingView.Timeline) -> [UUID: String] {
        func key(_ clip: EditingView.Clip) -> String {
            (clip.type == .image ? "image|" : "video|") + clip.clipName
        }
        let list = ordered(timeline)
        var counts: [String: Int] = [:]
        for item in list { counts[key(item.clip), default: 0] += 1 }
        var result: [UUID: String] = [:]
        for item in list where counts[key(item.clip), default: 0] > 1 { result[item.clip.id] = key(item.clip) }
        return result
    }
    
    /// Writes `templateGroup` ids on the replaceable clips of `timeline` from `assignment` (clip id -> any label; clips with the same label
    /// are one group, a clip that isn't in it stands alone). A label used by a single clip makes no group. The ids are "g1", "g2"...
    /// in order of first appearance. Run on a COPY of the timeline: the project is left untouched.
    /// Returns how many groups there are and how many clips are in one.
    @discardableResult
    static func apply(_ assignment: [UUID: String], to timeline: EditingView.Timeline) -> (groups: Int, clips: Int) {
        let list = ordered(timeline)
        var counts: [String: Int] = [:]
        for item in list { if let k = assignment[item.clip.id] { counts[k, default: 0] += 1 } }
        var ids: [String: String] = [:]
        var next = 1
        var grouped = 0
        for item in list {
            guard let k = assignment[item.clip.id], counts[k, default: 0] > 1 else { item.clip.templateGroup = nil; continue }
            if ids[k] == nil { ids[k] = "g\(next)"; next += 1 }
            item.clip.templateGroup = ids[k]
            grouped += 1
        }
        return (ids.count, grouped)
    }
    
    /// The automatic grouping applied to `timeline`. Returns how many groups were made.
    @discardableResult
    static func assign(to timeline: EditingView.Timeline) -> Int {
        apply(autoAssignment(for: timeline), to: timeline).groups
    }
}
