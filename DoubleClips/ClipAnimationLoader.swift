import Foundation

// MARK: - Clip animation loader (port of Android ClipAnimationLoader)
//
// Parses, validates and registers clip-animation JSON files, and is the lookup the compositor
// uses: `ClipAnimationLoader.get("unfold")`.
//
// File format (schema 1):
//   {
//     "schema": 1,
//     "id": "unfold",                 // [a-z0-9_-]{1,64}, not "none"; what Clip.inAnimation.type stores
//     "name": "Unfold",               // optional, shown in pickers
//     "direction": "in",              // "in" | "out"
//     "defaultDuration": 1.5,         // optional, seconds, (0, 30]; default 0.5
//     "referenceFrames": 45,          // only needed by "frames" knots below
//     "channels": {                   // OR "mirrorOf": "<id of an already-registered animation>"
//       "brightness": { "kind": "gaussian", "base": 0, "peak": 3.97, "tau": 0.467 },
//       "blur":       { "kind": "knots", "points": [[0, 0.025], [0.3, 0.01], [0.5, 0]] },
//       "warp.height":{ "kind": "knots", "frames": [[0, 0.955], [10, 1.017]], "interp": "smooth" },
//       "opacity":    { "kind": "constant", "value": 1 }
//     }
//   }
//
// SAFETY. Files may come from outside the app (animation packs), so this is strict and bounded: a
// hand-written RFC 8259 parser (JSONSerialization would silently merge duplicate keys), 256K
// characters max, nesting depth 12, 512 knots per channel, duplicate keys / unknown keys / unknown
// channels / trailing data / NaN / Infinity all rejected, and every value must lie inside its
// channel's range. Nothing is ever evaluated as an expression. A bad file throws
// `ClipAnimationFormatError` with a path to the problem and registers nothing.

struct ClipAnimationFormatError: LocalizedError {
    let message: String
    /// Lets callers retry once the base animation of a "mirrorOf" file is registered.
    let missingMirrorBase: Bool
    
    init(_ message: String, missingMirrorBase: Bool = false) {
        self.message = message
        self.missingMirrorBase = missingMirrorBase
    }
    
    var errorDescription: String? { message }
}

enum ClipAnimationLoader {
    
    static let supportedSchema = 1
    static let maxJSONChars = 256 * 1024
    static let maxKnotsPerChannel = 512
    static let maxDefaultDuration = 30.0
    static let defaultDurationFallback = 0.5
    
    // MARK: Registry (thread-safe: the compositor reads it on its render queue)
    
    private static let lock = NSLock()
    private static var registry: [String: ClipAnimation] = [:]
    private static var builtInIDs = Set<String>()
    
    /// The animation registered under `id`, or nil (also for nil / "none").
    static func get(_ id: String?) -> ClipAnimation? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return registry[id]
    }
    
    /// The animation registered under `id` only if it has the wanted direction, else nil. This is
    /// how the compositor reads a clip's in / out slot: an unknown id or the wrong direction
    /// animates nothing.
    static func get(_ id: String?, direction wanted: ClipAnimation.Direction) -> ClipAnimation? {
        guard let animation = get(id), animation.direction == wanted else { return nil }
        return animation
    }
    
    /// All registered animations of one direction, sorted by id.
    static func list(_ direction: ClipAnimation.Direction) -> [ClipAnimation] {
        lock.lock(); defer { lock.unlock() }
        return registry.values.filter { $0.direction == direction }.sorted { $0.id < $1.id }
    }
    
    static func isBuiltIn(_ id: String?) -> Bool {
        guard let id else { return false }
        lock.lock(); defer { lock.unlock() }
        return builtInIDs.contains(id)
    }
    
    /// Parses and registers one file. A built-in id can only be replaced by another built-in.
    /// `expectedDirection` is the folder the file was found in; the file must declare exactly it.
    @discardableResult
    static func register(_ json: String, source: String, builtIn: Bool,
                         expectedDirection: ClipAnimation.Direction? = nil) throws -> ClipAnimation {
        let animation = try parse(json, source: source, expectedDirection: expectedDirection)
        try registerParsed(animation, builtIn: builtIn, source: source)
        return animation
    }
    
    /// Registers an already-parsed animation. A built-in id can only be replaced by another built-in.
    static func registerParsed(_ animation: ClipAnimation, builtIn: Bool, source: String) throws {
        lock.lock(); defer { lock.unlock() }
        if !builtIn && builtInIDs.contains(animation.id) {
            throw ClipAnimationFormatError(prefix(source) + "id '\(animation.id)' is a built-in animation and can't be replaced")
        }
        registry[animation.id] = animation
        if builtIn { builtInIDs.insert(animation.id) }
    }
    
    /// Removes an installed (non-built-in) animation. Returns false if it wasn't there or is built-in.
    @discardableResult
    static func unregister(_ id: String?) -> Bool {
        guard let id else { return false }
        lock.lock(); defer { lock.unlock() }
        if builtInIDs.contains(id) { return false }
        return registry.removeValue(forKey: id) != nil
    }
    
    // MARK: Parse + validate
    
    private static func prefix(_ source: String) -> String { source.isEmpty ? "" : source + ": " }
    
    private static let topKeys: Set<String> = [
        "schema", "id", "name", "direction", "defaultDuration", "referenceFrames",
        "mirrorOf", "channels", "description", "author"
    ]
    
    /// Parses and validates without registering. `extraBases` are animations a "mirrorOf" may point
    /// at in addition to the registry (a pack being validated before anything is registered).
    static func parse(_ json: String, source: String,
                      extraBases: [String: ClipAnimation]? = nil,
                      expectedDirection: ClipAnimation.Direction? = nil) throws -> ClipAnimation {
        do {
            return try parseInternal(json, extraBases: extraBases, expectedDirection: expectedDirection)
        } catch let error as ClipAnimationFormatError {
            if source.isEmpty { throw error }
            throw ClipAnimationFormatError(prefix(source) + error.message, missingMirrorBase: error.missingMirrorBase)
        }
    }
    
    private static func parseInternal(_ json: String, extraBases: [String: ClipAnimation]?,
                                      expectedDirection: ClipAnimation.Direction?) throws -> ClipAnimation {
        if json.count > maxJSONChars {
            throw ClipAnimationFormatError("file is larger than \(maxJSONChars) characters")
        }
        let top = try asObject(try StrictJSON.parse(json), "$")
        for key in top.keys where !topKeys.contains(key) {
            throw ClipAnimationFormatError("$.\(key): unknown key")
        }
        
        let schema = try reqNumber(top, "schema", "$")
        guard schema == Double(supportedSchema) else {
            throw ClipAnimationFormatError("$.schema: unsupported schema \(fmt(schema)) (this app reads \(supportedSchema))")
        }
        
        let id = try reqString(top, "id", "$", 64)
        guard isValidID(id), id != "none" else {
            throw ClipAnimationFormatError("$.id: must be 1-64 characters of a-z 0-9 _ - and not 'none'")
        }
        var name = try optString(top, "name", "$", 64)
        if name == nil || name!.isEmpty { name = id }
        _ = try optString(top, "description", "$", 256)
        _ = try optString(top, "author", "$", 256)
        
        let dirString = try reqString(top, "direction", "$", 8)
        guard let direction = ClipAnimation.Direction(rawValue: dirString) else {
            throw ClipAnimationFormatError("$.direction: must be \"in\" or \"out\"")
        }
        if let expected = expectedDirection, direction != expected {
            throw ClipAnimationFormatError("$.direction: this file is in the \"\(expected.rawValue)\" folder but declares direction \"\(direction.rawValue)\"")
        }
        
        var duration = defaultDurationFallback
        if top["defaultDuration"] != nil {
            duration = try reqNumber(top, "defaultDuration", "$")
            guard duration > 0 && duration <= maxDefaultDuration else {
                throw ClipAnimationFormatError("$.defaultDuration: must be > 0 and <= \(Int(maxDefaultDuration)) seconds")
            }
        }
        
        let hasMirror = top["mirrorOf"] != nil
        let hasChannels = top["channels"] != nil
        guard hasMirror != hasChannels else {
            throw ClipAnimationFormatError("exactly one of \"mirrorOf\" or \"channels\" is required")
        }
        
        if hasMirror {
            let baseID = try reqString(top, "mirrorOf", "$", 64)
            let base = extraBases?[baseID] ?? get(baseID)
            guard let base else {
                throw ClipAnimationFormatError("$.mirrorOf: '\(baseID)' is not registered (load it first)", missingMirrorBase: true)
            }
            guard baseID != id else { throw ClipAnimationFormatError("$.mirrorOf: can't mirror itself") }
            return ClipAnimation.mirror(of: base, id: id, name: name!, direction: direction, defaultDuration: Float(duration))
        }
        
        var referenceFrames = 0
        if top["referenceFrames"] != nil {
            let rf = try reqNumber(top, "referenceFrames", "$")
            guard rf == rf.rounded(), rf >= 1, rf <= 10000 else {
                throw ClipAnimationFormatError("$.referenceFrames: must be a whole number 1-10000")
            }
            referenceFrames = Int(rf)
        }
        
        let channelObjects = try asObject(top["channels"], "$.channels")
        guard !channelObjects.isEmpty else {
            throw ClipAnimationFormatError("$.channels: at least one channel is required")
        }
        var curves: [ClipAnimation.Channel: ClipAnimation.Curve] = [:]
        for (key, value) in channelObjects {
            let path = "$.channels.\(key)"
            guard let channel = ClipAnimation.Channel.fromJSON(key) else {
                throw ClipAnimationFormatError("\(path): unknown channel")
            }
            curves[channel] = try parseCurve(try asObject(value, path), channel, referenceFrames, path)
        }
        return ClipAnimation(id: id, name: name!, direction: direction, defaultDuration: Float(duration),
                             curves: curves, reversed: false, referenceFrames: referenceFrames)
    }
    
    static func parseCurve(_ m: [String: Any], _ channel: ClipAnimation.Channel,
                                   _ referenceFrames: Int, _ path: String) throws -> ClipAnimation.Curve {
        let kind = try reqString(m, "kind", path, 16)
        switch kind {
        case "constant":
            try allowKeys(m, path, ["kind", "value"])
            let v = try reqNumber(m, "value", path)
            try checkRange(v, channel, path + ".value")
            return .constant(v)
            
        case "gaussian":
            try allowKeys(m, path, ["kind", "base", "peak", "tau"])
            let base = try (m["base"] != nil ? reqNumber(m, "base", path) : channel.neutral)
            let peak = try reqNumber(m, "peak", path)
            let tau = try reqNumber(m, "tau", path)
            guard tau >= 0.01 && tau <= 10.0 else {
                throw ClipAnimationFormatError("\(path).tau: must be between 0.01 and 10")
            }
            try checkRange(base, channel, path + ".base")
            try checkRange(base + peak, channel, path + " (base + peak)")
            return .gaussian(base: base, peak: peak, tau: tau)
            
        case "knots":
            try allowKeys(m, path, ["kind", "points", "frames", "interp"])
            let hasPoints = m["points"] != nil
            let hasFrames = m["frames"] != nil
            guard hasPoints != hasFrames else {
                throw ClipAnimationFormatError("\(path): exactly one of \"points\" or \"frames\" is required")
            }
            var smooth = false
            if m["interp"] != nil {
                let interp = try reqString(m, "interp", path, 16)
                if interp == "smooth" { smooth = true }
                else if interp != "linear" { throw ClipAnimationFormatError("\(path).interp: must be \"linear\" or \"smooth\"") }
            }
            let arrayKey = hasPoints ? "points" : "frames"
            let array = try asArray(m[arrayKey], "\(path).\(arrayKey)")
            guard !array.isEmpty else {
                throw ClipAnimationFormatError("\(path).\(arrayKey): at least one knot is required")
            }
            guard array.count <= maxKnotsPerChannel else {
                throw ClipAnimationFormatError("\(path).\(arrayKey): more than \(maxKnotsPerChannel) knots")
            }
            if hasFrames && referenceFrames == 0 {
                throw ClipAnimationFormatError("\(path).frames: needs a top-level \"referenceFrames\"")
            }
            var ps: [Double] = [], vs: [Double] = []
            for (i, item) in array.enumerated() {
                let kp = "\(path).\(arrayKey)[\(i)]"
                let pair = try asArray(item, kp)
                guard pair.count == 2, let t = pair[0] as? Double, let v = pair[1] as? Double else {
                    throw ClipAnimationFormatError("\(kp): must be [time, value]")
                }
                let p = hasFrames ? t / Double(referenceFrames) : t
                guard p >= 0.0 && p <= 1.0 else {
                    throw ClipAnimationFormatError("\(kp): time must be within 0..1" + (hasFrames ? " (frame / referenceFrames)" : ""))
                }
                if let last = ps.last, !(p > last) {
                    throw ClipAnimationFormatError("\(kp): times must be strictly increasing")
                }
                try checkRange(v, channel, kp)
                ps.append(p)
                vs.append(v)
            }
            return .knots(ps: ps, vs: vs, smooth: smooth)
            
        default:
            throw ClipAnimationFormatError("\(path).kind: must be \"constant\", \"knots\" or \"gaussian\"")
        }
    }
    
    private static func checkRange(_ v: Double, _ channel: ClipAnimation.Channel, _ path: String) throws {
        guard v >= channel.min && v <= channel.max else {
            throw ClipAnimationFormatError("\(path): \(fmt(v)) is outside the allowed range of '\(channel.json)' (\(fmt(channel.min)) .. \(fmt(channel.max)))")
        }
    }
    
    static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 }
    }
    
    // MARK: Typed accessors (shared with the pack manifest parser)
    
    /// Parses a document whose root must be an object (used for pack.json).
    static func parseObject(_ text: String) throws -> [String: Any] {
        try asObject(try StrictJSON.parse(text), "$")
    }
    
    static func asObject(_ value: Any?, _ path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw ClipAnimationFormatError("\(path): must be an object") }
        return object
    }
    
    static func asArray(_ value: Any?, _ path: String) throws -> [Any] {
        guard let array = value as? [Any] else { throw ClipAnimationFormatError("\(path): must be an array") }
        return array
    }
    
    static func reqNumber(_ object: [String: Any], _ key: String, _ path: String) throws -> Double {
        guard let value = object[key] as? Double else {
            throw ClipAnimationFormatError("\(path).\(key): " + (object[key] == nil ? "is required" : "must be a number"))
        }
        return value
    }
    
    static func reqString(_ object: [String: Any], _ key: String, _ path: String, _ maxChars: Int) throws -> String {
        guard let value = object[key] else { throw ClipAnimationFormatError("\(path).\(key): is required") }
        guard let string = value as? String else { throw ClipAnimationFormatError("\(path).\(key): must be a string") }
        guard string.count <= maxChars else { throw ClipAnimationFormatError("\(path).\(key): longer than \(maxChars) characters") }
        return string
    }
    
    static func optString(_ object: [String: Any], _ key: String, _ path: String, _ maxChars: Int) throws -> String? {
        object[key] == nil ? nil : try reqString(object, key, path, maxChars)
    }
    
    static func allowKeys(_ object: [String: Any], _ path: String, _ allowed: Set<String>) throws {
        for key in object.keys where !allowed.contains(key) {
            throw ClipAnimationFormatError("\(path).\(key): unknown key")
        }
    }
    
    static func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }
}

// MARK: - Strict JSON parser (RFC 8259)
//
// Numbers are returned as Double, strings as String, arrays as [Any], objects as [String: Any];
// null / booleans are rejected outright (no animation file needs them). Rejects duplicate keys,
// trailing data, leading zeros, NaN / Infinity, control characters in strings, and nesting deeper
// than 12 levels.

private struct StrictJSON {
    private let bytes: [UInt8]
    private var pos = 0
    private let maxDepth = 12
    private let maxArrayElements = 4096
    private let maxStringChars = 4096
    
    static func parse(_ text: String) throws -> Any {
        var parser = StrictJSON(text)
        return try parser.parseDocument()
    }
    
    private init(_ text: String) {
        var data = Array(text.utf8)
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { data.removeFirst(3) }   // BOM
        self.bytes = data
    }
    
    mutating func parseDocument() throws -> Any {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if pos != bytes.count { throw error("unexpected data after the end of the JSON document") }
        return value
    }
    
    private func error(_ message: String) -> ClipAnimationFormatError {
        // 1-based line/column of the current position, for a message a person can act on.
        var line = 1, column = 1
        for i in 0..<min(pos, bytes.count) {
            if bytes[i] == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return ClipAnimationFormatError("JSON syntax error at line \(line), column \(column): \(message)")
    }
    
    private mutating func skipWhitespace() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
    }
    
    private mutating func parseValue(depth: Int) throws -> Any {
        guard depth <= maxDepth else { throw error("nested deeper than \(maxDepth) levels") }
        guard pos < bytes.count else { throw error("unexpected end of data") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""): return try parseString()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character (only objects, arrays, strings and numbers are allowed)")
        }
    }
    
    private mutating func parseObject(depth: Int) throws -> [String: Any] {
        pos += 1   // {
        var object: [String: Any] = [:]
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return object }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw error("expected a quoted key") }
            let key = try parseString()
            if object[key] != nil { throw error("duplicate key \"\(key)\"") }
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("expected ':' after key") }
            pos += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth)
            skipWhitespace()
            guard pos < bytes.count else { throw error("unexpected end of data in object") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return object }
            throw error("expected ',' or '}'")
        }
    }
    
    private mutating func parseArray(depth: Int) throws -> [Any] {
        pos += 1   // [
        var array: [Any] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return array }
        while true {
            skipWhitespace()
            if array.count >= maxArrayElements { throw error("array has more than \(maxArrayElements) elements") }
            array.append(try parseValue(depth: depth))
            skipWhitespace()
            guard pos < bytes.count else { throw error("unexpected end of data in array") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return array }
            throw error("expected ',' or ']'")
        }
    }
    
    private mutating func parseString() throws -> String {
        pos += 1   // opening quote
        var scalars = String.UnicodeScalarView()
        var count = 0
        while true {
            guard pos < bytes.count else { throw error("unterminated string") }
            let b = bytes[pos]
            if b == UInt8(ascii: "\"") { pos += 1; return String(scalars) }
            if b < 0x20 { throw error("control character in string") }
            count += 1
            if count > maxStringChars { throw error("string longer than \(maxStringChars) characters") }
            if b == UInt8(ascii: "\\") {
                pos += 1
                guard pos < bytes.count else { throw error("unterminated escape") }
                switch bytes[pos] {
                case UInt8(ascii: "\""): scalars.append("\""); pos += 1
                case UInt8(ascii: "\\"): scalars.append("\\"); pos += 1
                case UInt8(ascii: "/"):  scalars.append("/");  pos += 1
                case UInt8(ascii: "b"):  scalars.append("\u{08}"); pos += 1
                case UInt8(ascii: "f"):  scalars.append("\u{0C}"); pos += 1
                case UInt8(ascii: "n"):  scalars.append("\n"); pos += 1
                case UInt8(ascii: "r"):  scalars.append("\r"); pos += 1
                case UInt8(ascii: "t"):  scalars.append("\t"); pos += 1
                case UInt8(ascii: "u"):
                    pos += 1
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {            // high surrogate: needs a low one
                        guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                            throw error("unpaired surrogate in \\u escape")
                        }
                        pos += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("unpaired surrogate in \\u escape") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw error("unpaired surrogate in \\u escape")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("invalid \\u escape") }
                    scalars.append(scalar)
                default: throw error("invalid escape sequence")
                }
            } else {
                // Copy one UTF-8 encoded scalar.
                let length: Int
                switch b {
                case 0x00...0x7F: length = 1
                case 0xC2...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF4: length = 4
                default: throw error("invalid UTF-8")
                }
                guard pos + length <= bytes.count,
                      let s = String(bytes: bytes[pos..<(pos + length)], encoding: .utf8),
                      let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1 else {
                    throw error("invalid UTF-8")
                }
                scalars.append(scalar)
                pos += length
            }
        }
    }
    
    private mutating func hex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw error("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[pos]
            let digit: UInt32
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A")) + 10
            default: throw error("invalid \\u escape")
            }
            value = value * 16 + digit
            pos += 1
        }
        return value
    }
    
    private mutating func parseNumber() throws -> Double {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        guard pos < bytes.count else { throw error("invalid number") }
        if bytes[pos] == UInt8(ascii: "0") {
            pos += 1
            if pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) {
                throw error("leading zeros are not allowed")
            }
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[pos]) {
            while pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) { pos += 1 }
        } else {
            throw error("invalid number")
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            let digitsStart = pos
            while pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) { pos += 1 }
            if pos == digitsStart { throw error("digits expected after '.'") }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            let digitsStart = pos
            while pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) { pos += 1 }
            if pos == digitsStart { throw error("digits expected in exponent") }
        }
        guard let text = String(bytes: bytes[start..<pos], encoding: .utf8),
              let value = Double(text), value.isFinite else {
            throw error("number out of range")
        }
        return value
    }
}
