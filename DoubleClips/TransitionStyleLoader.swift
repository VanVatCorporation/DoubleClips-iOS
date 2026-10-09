import Foundation

// MARK: - Transition styles as JSON (iOS only)
//
// A transition style is a DATA file in `animations/transitions/<id>.json`, built from the same channels and the
// same three curve kinds as a clip animation (ClipAnimationLoader), so nothing in it can execute anything:
//
//   {
//     "schema": 1,
//     "id": "glitchblur",              // [a-z0-9_-]{1,64}: the transition's style key (what the knot stores)
//     "name": "Glitch Blur",
//     "description": "...",            // optional, 256 characters at most
//     "defaultDuration": 1.1,          // optional, seconds, (0, 30]; default 0.5
//     "cut": 0.76,                     // where A is replaced by B, 0.05 ... 0.95 of the window (default 0.5)
//     "referenceFrames": 100,          // only needed by "frames" knots
//     "from": { "channels": { ... } }, // the look of A, curves over the WHOLE window (p = 0 ... 1); A is drawn for p < cut
//     "to":   { "channels": { ... } }  // the look of B, same p; B is drawn for p >= cut
//   }
//
// There is no cross dissolve: one of the two pictures is drawn at any moment, each through the normal clip
// pipeline with its side's channels applied on top of the clip's own properties AND its In / Out animation
// (additive channels add, multiplicative ones multiply: ClipAnimationFrame.merged). So a style is just "what
// happens to A before the cut, what happens to B after it".
//
// Validation is the clip-animation one (strict JSON, bounded size, unknown keys / channels rejected, values inside
// the channel's range). A bad file throws `ClipAnimationFormatError` and registers nothing.

final class TransitionStyle {
    let id: String
    let name: String
    let defaultDuration: Float
    /// Window progress at which the picture switches from A to B.
    let cut: Double
    /// The look of A (evaluated over the whole window).
    let from: ClipAnimation
    /// The look of B (evaluated over the whole window).
    let to: ClipAnimation
    
    init(id: String, name: String, defaultDuration: Float, cut: Double, from: ClipAnimation, to: ClipAnimation) {
        self.id = id
        self.name = name
        self.defaultDuration = defaultDuration
        self.cut = cut
        self.from = from
        self.to = to
    }
}

enum TransitionStyleLoader {
    
    /// Folder inside the bundled `animations` folder.
    static let assetFolder = "transitions"
    
    private static let lock = NSLock()
    private static var styles: [String: TransitionStyle] = [:]
    private static var builtInsLoaded = false
    
    // MARK: Lookup (thread-safe: the compositor reads it on its render queue)
    
    /// The data-driven style stored under this (normalized) key, or nil when the key is a hard-coded style.
    static func get(_ id: String?) -> TransitionStyle? {
        guard let id, !id.isEmpty else { return nil }
        lock.lock()
        let loaded = builtInsLoaded
        lock.unlock()
        if !loaded { ClipAnimationStore.loadAll() }       // idempotent; ends up in `loadBuiltIns()` below
        lock.lock(); defer { lock.unlock() }
        return styles[id]
    }
    
    static func list() -> [TransitionStyle] {
        lock.lock(); defer { lock.unlock() }
        return styles.values.sorted { $0.id < $1.id }
    }
    
    // MARK: Loading the bundled files
    
    /// Reads `animations/transitions/*.json` from the app bundle. Idempotent. Returns one message per bad file.
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
            let wanted = Set(TransitionStyleDefaults.json.keys.map { $0 + ".json" })
            files = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .filter { wanted.contains($0.lastPathComponent) }
        }
        var fromBundle: [String] = []
        for url in files {
            let label = "transitions/\(url.lastPathComponent)"
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                try register(text, source: label)
                fromBundle.append(url.lastPathComponent)
            } catch let error as ClipAnimationFormatError {
                errors.append(error.message)               // a bad bundle file: the embedded copy below takes over
            } catch {
                errors.append("\(label): can't read file: \(error.localizedDescription)")
            }
        }
        // Embedded copies for every style the bundle didn't provide (or provided broken).
        var fromDefaults: [String] = []
        for (id, text) in TransitionStyleDefaults.json.sorted(by: { $0.key < $1.key }) {
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
        print("[TransitionStyles] from bundle files: \(fromBundle); from embedded copies: \(fromDefaults); problems: \(errors)")
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
        "schema", "id", "name", "description", "author", "defaultDuration", "cut", "referenceFrames", "from", "to"
    ]
    
    static func parse(_ json: String, source: String) throws -> TransitionStyle {
        do {
            return try parseInternal(json)
        } catch let error as ClipAnimationFormatError {
            throw ClipAnimationFormatError(source.isEmpty ? error.message : source + ": " + error.message)
        }
    }
    
    private static func parseInternal(_ json: String) throws -> TransitionStyle {
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
        _ = try L.optString(top, "author", "$", 256)
        
        var duration = L.defaultDurationFallback
        if top["defaultDuration"] != nil {
            duration = try L.reqNumber(top, "defaultDuration", "$")
            guard duration > 0 && duration <= L.maxDefaultDuration else {
                throw ClipAnimationFormatError("$.defaultDuration: must be > 0 and <= \(Int(L.maxDefaultDuration)) seconds")
            }
        }
        var cut = 0.5
        if top["cut"] != nil {
            cut = try L.reqNumber(top, "cut", "$")
            guard cut >= 0.05 && cut <= 0.95 else {
                throw ClipAnimationFormatError("$.cut: must be between 0.05 and 0.95")
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
        
        func side(_ key: String, direction: ClipAnimation.Direction) throws -> ClipAnimation {
            let path = "$.\(key)"
            let object = try L.asObject(top[key], path)
            try L.allowKeys(object, path, ["channels"])
            let channelObjects = try L.asObject(object["channels"], "\(path).channels")
            guard !channelObjects.isEmpty else {
                throw ClipAnimationFormatError("\(path).channels: at least one channel is required")
            }
            var curves: [ClipAnimation.Channel: ClipAnimation.Curve] = [:]
            for (channelKey, value) in channelObjects {
                let channelPath = "\(path).channels.\(channelKey)"
                guard let channel = ClipAnimation.Channel.fromJSON(channelKey) else {
                    throw ClipAnimationFormatError("\(channelPath): unknown channel")
                }
                curves[channel] = try L.parseCurve(try L.asObject(value, channelPath), channel, referenceFrames, channelPath)
            }
            return ClipAnimation(id: "\(id).\(key)", name: name!, direction: direction, defaultDuration: Float(duration),
                                 curves: curves, reversed: false, referenceFrames: referenceFrames)
        }
        
        return TransitionStyle(id: id, name: name!, defaultDuration: Float(duration), cut: cut,
                               from: try side("from", direction: .out), to: try side("to", direction: .in))
    }
}
