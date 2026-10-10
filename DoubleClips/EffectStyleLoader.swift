import Foundation

// MARK: - Effect styles as JSON (iOS only)
//
// An effect clip is an adjustment layer: it processes everything drawn on the tracks BEFORE it for as long as the clip
// lasts (EditingView+Effects.swift). A data-driven effect is a file in `animations/effects/<id>.json` built from the same
// channels and curve kinds as a clip animation (ClipAnimationLoader) and applied to the whole picture so far:
//
//   {
//     "schema": 1,
//     "id": "heartbeat",                 // [a-z0-9_-]{1,64}: the effect's style key (what the effect clip stores)
//     "name": "Heartbeat",
//     "description": "...",              // optional, 256 characters at most
//     "author": "...",                   // optional (default: the built-in author)
//     "intensity": { "label": "Strength", "min": 0.2, "max": 3 },   // optional; absent = no strength slider
//     "period": 1.0,                     // optional, seconds (0 / absent = the curves run once over the clip, p = 0...1);
//                                        //   with a period the curves loop: p = (seconds into the effect mod period) / period
//     "referenceFrames": 60,             // only needed by "frames" knots
//     "channels": { ... }                // same channels / curves as an animation (scale, rotation, offsetX/Y, blur,
//   }                                    //   motionBlur + blurAngle, edgeSlide(Y), squeezeX, exposure, brightness,
//                                        //   saturation, contrast, hue, temperature, warp.*, opacity, edgeFill)
//
// The strength slider scales every channel's distance from its neutral value (ClipAnimationFrame.scaledDeviation): a push
// of 12% becomes 24% at strength 2. A JSON style with the same id as a hard-coded effect replaces its rendering.
// Validation is the clip-animation one; a bad file throws `ClipAnimationFormatError` and registers nothing.

final class EffectStyleDefinition {
    let id: String
    let name: String
    let author: String
    /// What the strength slider means; nil = nothing to scale (the slider is hidden).
    let intensityLabel: String?
    let intensityRange: ClosedRange<Float>
    /// Seconds per loop; 0 = the curves run once across the clip.
    let period: Double
    let animation: ClipAnimation
    
    init(id: String, name: String, author: String, intensityLabel: String?, intensityRange: ClosedRange<Float>,
         period: Double, animation: ClipAnimation) {
        self.id = id
        self.name = name
        self.author = author
        self.intensityLabel = intensityLabel
        self.intensityRange = intensityRange
        self.period = period
        self.animation = animation
    }
}

enum EffectStyleLoader {
    
    /// Folder inside the bundled `animations` folder.
    static let assetFolder = "effects"
    
    private static let lock = NSLock()
    private static var styles: [String: EffectStyleDefinition] = [:]
    private static var builtInsLoaded = false
    
    // MARK: Lookup (thread-safe: the compositor reads it on its render queue)
    
    /// The data-driven effect stored under this (normalized) key, or nil.
    static func get(_ id: String?) -> EffectStyleDefinition? {
        guard let id, !id.isEmpty else { return nil }
        lock.lock()
        let loaded = builtInsLoaded
        lock.unlock()
        if !loaded { ClipAnimationStore.loadAll() }       // idempotent; ends up in `loadBuiltIns()` below
        lock.lock(); defer { lock.unlock() }
        return styles[id]
    }
    
    static func list() -> [EffectStyleDefinition] {
        lock.lock()
        let loaded = builtInsLoaded
        lock.unlock()
        if !loaded { ClipAnimationStore.loadAll() }
        lock.lock(); defer { lock.unlock() }
        return styles.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    // MARK: Loading the bundled files
    
    /// Reads `animations/effects/*.json` from the app bundle, then registers the embedded copy of every style the bundle
    /// didn't provide (`EffectStyleDefaults`). Idempotent. Returns one message per bad file.
    @discardableResult
    static func loadBuiltIns() -> [String] {
        lock.lock()
        if builtInsLoaded { lock.unlock(); return [] }
        lock.unlock()
        
        var errors: [String] = []
        let fm = FileManager.default
        var files: [URL] = []
        if let root = Bundle.main.url(forResource: ClipAnimationStore.assetDir, withExtension: nil) {
            let folder = root.appendingPathComponent(assetFolder, isDirectory: true)
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            files = names.filter { $0.hasSuffix(".json") }.map { folder.appendingPathComponent($0) }
        }
        // Files that Xcode flattened into the bundle root (added as a group, not a folder reference).
        if files.isEmpty {
            let wanted = Set(EffectStyleDefaults.json.keys.map { $0 + ".json" })
            files = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .filter { wanted.contains($0.lastPathComponent) }
        }
        var fromBundle: [String] = []
        for url in files {
            let label = "effects/\(url.lastPathComponent)"
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                try register(text, source: label)
                fromBundle.append(url.lastPathComponent)
            } catch let error as ClipAnimationFormatError {
                errors.append(error.message)
            } catch {
                errors.append("\(label): can't read file: \(error.localizedDescription)")
            }
        }
        var fromDefaults: [String] = []
        for (id, text) in EffectStyleDefaults.json.sorted(by: { $0.key < $1.key }) {
            lock.lock(); let have = styles[id] != nil; lock.unlock()
            if have { continue }
            do {
                try register(text, source: "built-in \(id)")
                fromDefaults.append(id)
            } catch let error as ClipAnimationFormatError {
                errors.append(error.message)
            } catch {
                errors.append("built-in \(id): \(error.localizedDescription)")
            }
        }
        print("[EffectStyles] from bundle files: \(fromBundle); from embedded copies: \(fromDefaults); problems: \(errors)")
        lock.lock(); builtInsLoaded = true; lock.unlock()
        return errors
    }
    
    /// Parses, validates and registers one file (replacing a style with the same id).
    static func register(_ json: String, source: String) throws {
        let style = try parse(json, source: source)
        lock.lock(); styles[style.id] = style; lock.unlock()
    }
    
    // MARK: Parse + validate
    
    private static let topKeys: Set<String> = [
        "schema", "id", "name", "description", "author", "intensity", "period", "referenceFrames", "channels"
    ]
    
    static func parse(_ json: String, source: String) throws -> EffectStyleDefinition {
        do {
            return try parseInternal(json)
        } catch let error as ClipAnimationFormatError {
            throw ClipAnimationFormatError(source.isEmpty ? error.message : source + ": " + error.message)
        }
    }
    
    private static func parseInternal(_ json: String) throws -> EffectStyleDefinition {
        typealias L = ClipAnimationLoader
        if json.count > L.maxJSONChars {
            throw ClipAnimationFormatError("file is larger than \(L.maxJSONChars) characters")
        }
        let top = try L.parseObject(json)
        try L.allowKeys(top, "$", topKeys)
        
        let schema = try L.reqNumber(top, "schema", "$")
        guard schema == Double(L.supportedSchema) else {
            throw ClipAnimationFormatError("$.schema: unsupported schema \(L.fmt(schema)) (this app reads \(L.supportedSchema))")
        }
        let id = try L.reqString(top, "id", "$", 64)
        guard L.isValidID(id), id != "none" else {
            throw ClipAnimationFormatError("$.id: must be 1-64 characters of a-z 0-9 _ - and not 'none'")
        }
        var name = try L.optString(top, "name", "$", 64)
        if name == nil || name!.isEmpty { name = id }
        _ = try L.optString(top, "description", "$", 256)
        var author = try L.optString(top, "author", "$", 64)
        if author == nil || author!.isEmpty { author = Constants.EFFECT_BUILTIN_AUTHOR }
        
        var label: String? = nil
        var range: ClosedRange<Float> = 0.2...3
        if top["intensity"] != nil {
            let object = try L.asObject(top["intensity"], "$.intensity")
            try L.allowKeys(object, "$.intensity", ["label", "min", "max"])
            label = try L.optString(object, "label", "$.intensity", 32) ?? "Strength"
            var lo = 0.2, hi = 3.0
            if object["min"] != nil { lo = try L.reqNumber(object, "min", "$.intensity") }
            if object["max"] != nil { hi = try L.reqNumber(object, "max", "$.intensity") }
            guard lo > 0, hi > lo, hi <= 10 else {
                throw ClipAnimationFormatError("$.intensity: needs 0 < min < max <= 10")
            }
            range = Float(lo)...Float(hi)
        }
        
        var period = 0.0
        if top["period"] != nil {
            period = try L.reqNumber(top, "period", "$")
            guard period > 0 && period <= 60 else {
                throw ClipAnimationFormatError("$.period: must be > 0 and <= 60 seconds")
            }
        }
        var referenceFrames = 0
        if top["referenceFrames"] != nil {
            let rf = try L.reqNumber(top, "referenceFrames", "$")
            guard rf == rf.rounded(), rf >= 1, rf <= 10000 else {
                throw ClipAnimationFormatError("$.referenceFrames: must be a whole number 1-10000")
            }
            referenceFrames = Int(rf)
        }
        
        let channelObjects = try L.asObject(top["channels"], "$.channels")
        guard !channelObjects.isEmpty else {
            throw ClipAnimationFormatError("$.channels: at least one channel is required")
        }
        var curves: [ClipAnimation.Channel: ClipAnimation.Curve] = [:]
        for (channelKey, value) in channelObjects {
            let path = "$.channels.\(channelKey)"
            guard let channel = ClipAnimation.Channel.fromJSON(channelKey) else {
                throw ClipAnimationFormatError("\(path): unknown channel")
            }
            curves[channel] = try L.parseCurve(try L.asObject(value, path), channel, referenceFrames, path)
        }
        let animation = ClipAnimation(id: id, name: name!, direction: .in, defaultDuration: 1,
                                      curves: curves, reversed: false, referenceFrames: referenceFrames)
        return EffectStyleDefinition(id: id, name: name!, author: author!, intensityLabel: label, intensityRange: range,
                                     period: period, animation: animation)
    }
}
