import Foundation

struct TemplateData: Identifiable, Codable, Hashable {
    var id: String { templateId } // Mapped from templateId
    var templateAuthor: String
    var templateId: String
    var templateTitle: String
    var templateDescription: String
    var ffmpegCommand: String
    var templateSnapshotLink: String
    var templateVideoLink: String
    var templateTimestamp: Int64
    var templateDuration: Int64
    var templateTotalClip: Int
    var additionalResourceName: [String]?
    /// URL of the template's timeline JSON (same format as a project's project.timeline). Empty = the old,
    /// ffmpeg-only kind of template. See DoubleClips-Template-Timeline-Contract.md.
    var templateTimelineLink: String = ""
    /// Folder URL (ends with "/") the template's resource files live in: `additionalResourceName[i]` is
    /// downloaded from `templateContentLink + name`. Used when the user taps "Use template".
    var templateContentLink: String = ""
    var viewCount: Int
    var useCount: Int
    var heartCount: Int
    // var comments: [TemplateComment] // Deferred for now as per "handle later" instruction
    var bookmarkCount: Int
    
    // User Interaction State
    var isLiked: Bool?
    var isBookmarked: Bool?
}

// MARK: - Tolerant decoding
//
// The server list used to be decoded with a strict `[TemplateData]`: a single template with a
// missing key, a null, or a wrong type made the WHOLE decode fail, and `try?` swallowed the error,
// so the Template tab stayed empty. Android's Gson never had that problem (missing fields become
// 0 / null). This mirrors that behavior:
//   • each field falls back to a default when missing or malformed (numbers may arrive as strings),
//   • an element that can't be a template at all (not an object, or no templateId) is skipped,
//   • the rest of the list still loads.

extension TemplateData {

    enum CodingKeys: String, CodingKey {
        case templateAuthor, templateId, templateTitle, templateDescription, ffmpegCommand
        case templateSnapshotLink, templateVideoLink, templateTimestamp, templateDuration
        case templateTotalClip, additionalResourceName, viewCount, useCount, heartCount
        case templateTimelineLink, templateContentLink
        case bookmarkCount, isLiked, isBookmarked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let id = c.lenientString(.templateId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .templateId, in: c,
                                                   debugDescription: "Template has no templateId")
        }

        self.init(templateAuthor: c.lenientString(.templateAuthor),
                  templateId: id,
                  templateTitle: c.lenientString(.templateTitle),
                  templateDescription: c.lenientString(.templateDescription),
                  ffmpegCommand: c.lenientString(.ffmpegCommand),
                  templateSnapshotLink: c.lenientString(.templateSnapshotLink),
                  templateVideoLink: c.lenientString(.templateVideoLink),
                  templateTimestamp: c.lenientInt64(.templateTimestamp),
                  templateDuration: c.lenientInt64(.templateDuration),
                  templateTotalClip: Int(clamping: c.lenientInt64(.templateTotalClip)),
                  additionalResourceName: c.lenientStringArray(.additionalResourceName),
                  templateTimelineLink: c.lenientString(.templateTimelineLink),
                  templateContentLink: c.lenientString(.templateContentLink),
                  viewCount: Int(clamping: c.lenientInt64(.viewCount)),
                  useCount: Int(clamping: c.lenientInt64(.useCount)),
                  heartCount: Int(clamping: c.lenientInt64(.heartCount)),
                  bookmarkCount: Int(clamping: c.lenientInt64(.bookmarkCount)),
                  isLiked: c.lenientBool(.isLiked),
                  isBookmarked: c.lenientBool(.isBookmarked))
    }

    /// Decodes the server's template list, dropping entries that are unusable instead of failing
    /// the whole list. Returns nil only when the payload isn't a JSON array at all.
    static func decodeList(from data: Data) -> (templates: [TemplateData], skipped: Int)? {
        guard let items = try? JSONDecoder().decode([LossyTemplate].self, from: data) else { return nil }
        var seen = Set<String>()
        var result: [TemplateData] = []
        for item in items {
            // Duplicate ids would confuse ForEach / navigation; keep the first occurrence.
            if let template = item.value, seen.insert(template.templateId).inserted {
                result.append(template)
            }
        }
        return (result, items.count - result.count)
    }
}

/// One list element that never throws: a malformed template becomes `nil`.
private struct LossyTemplate: Decodable {
    let value: TemplateData?
    init(from decoder: Decoder) throws {
        value = try? TemplateData(from: decoder)
    }
}

private extension KeyedDecodingContainer {

    func lenientString(_ key: Key) -> String {
        if let v = try? decode(String.self, forKey: key) { return v }
        if let v = try? decode(Int64.self, forKey: key) { return String(v) }
        if let v = try? decode(Double.self, forKey: key) { return String(v) }
        if let v = try? decode(Bool.self, forKey: key) { return String(v) }
        return ""
    }

    func lenientInt64(_ key: Key) -> Int64 {
        if let v = try? decode(Int64.self, forKey: key) { return v }
        if let v = try? decode(Double.self, forKey: key), v.isFinite,
           v > Double(Int64.min), v < Double(Int64.max) { return Int64(v) }
        if let s = try? decode(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Int64(t) { return v }
            if let d = Double(t), d.isFinite, d > Double(Int64.min), d < Double(Int64.max) { return Int64(d) }
        }
        return 0
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let v = try? decode(Bool.self, forKey: key) { return v }
        if let v = try? decode(Int.self, forKey: key) { return v != 0 }
        if let s = try? decode(String.self, forKey: key) {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func lenientStringArray(_ key: Key) -> [String]? {
        if let v = try? decode([String].self, forKey: key) { return v }
        // Mixed array (e.g. ["a", null, 3]): keep the string-like elements.
        if var list = try? nestedUnkeyedContainer(forKey: key) {
            var out: [String] = []
            while !list.isAtEnd {
                if let s = try? list.decode(String.self) { out.append(s) }
                else if let n = try? list.decode(Int64.self) { out.append(String(n)) }
                else { _ = try? list.decode(DiscardedValue.self) }   // advance past null / object
            }
            return out
        }
        if let single = try? decode(String.self, forKey: key) {
            // A MySQL JSON column can arrive as text: '["a.mp4","b.ttf"]'. [""] = no resources.
            if let data = single.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                return parsed.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return single.isEmpty ? [] : [single]
        }
        return nil
    }
}

/// Consumes any JSON value so an unkeyed container can step past an unusable element.
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {}
}
