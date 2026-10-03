import Foundation

// MARK: - Animation assets + installable packs
// (port of Android ClipAnimationAssets + ClipAnimationPacks)
//
// Bundled animations live in the app bundle's `animations/in/*.json` and `animations/out/*.json`
// (add the `animations` folder to the Xcode target as a *folder reference*, the blue folder icon, so
// the sub-folders survive). The folder a file is in must match the direction it declares.
// Installed packs live in <Application Support>/animation_packs/<packId>/.
//
// PACK FORMAT (the zip may contain exactly these entries and nothing else):
//   pack.json                  { "schema": 1, "id": "my-pack", "name": "My Pack", "version": 1,
//                                "author": "...", "description": "..." }      // id: [a-z0-9_-]{1,64}
//   animations/in/<id>.json    one animation file each (see ClipAnimationLoader for the format);
//   animations/out/<id>.json   the file name must equal the animation's "id", and an animation in
//                              in/ must be an "in" one, in out/ an "out" one
//
// SECURITY. A pack is an untrusted download, so installation is strict and bounded and writes
// nothing until EVERYTHING has been validated in memory:
//  - only the whitelisted entry names above are accepted, so "..", absolute paths, backslashes,
//    sub-folders, symlinks and stray files are all rejected outright. No entry name is ever used as
//    a path: each file is rebuilt from the validated animation id;
//  - hard caps: 2 MB zip, 4 MB unpacked in total, 512 KB per entry, 80 entries, 32 animations. The
//    caps are checked against the sizes the zip claims AND against the bytes actually written, so a
//    zip bomb stops at the cap;
//  - every animation goes through the same strict parser as the bundled ones; ids may not collide
//    with a built-in or another installed animation;
//  - the install is atomic: files are staged in a hidden folder and swapped in with a rename, so a
//    failed or interrupted install never leaves a half-written pack, and a failed UPDATE leaves the
//    old version intact.
// Nothing in a pack is ever executed: animations are numbers plus three fixed formulas.

/// A pack that can't be installed / removed; the message is written for the user.
struct ClipAnimationPackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// An installed pack, for listing in the UI.
struct ClipAnimationPackInfo: Identifiable {
    let id: String
    let name: String
    let version: Int
    let author: String
    let packDescription: String
    let inIDs: [String]
    let outIDs: [String]
    /// false when the pack's manifest is unreadable: it is still listed so the user can remove it.
    let damaged: Bool
    
    var animationCount: Int { inIDs.count + outIDs.count }
}

struct ClipAnimationInstallResult {
    let pack: ClipAnimationPackInfo
    /// The version that was replaced, or 0 for a fresh install.
    let replacedVersion: Int
}

enum ClipAnimationStore {
    
    static let assetDir = "animations"
    static let packsDirName = "animation_packs"
    
    static let maxZipBytes: Int64 = 2 * 1024 * 1024
    static let maxTotalBytes: Int64 = 4 * 1024 * 1024
    static let maxEntryBytes: Int64 = 512 * 1024
    static let maxEntries = 80
    static let maxAnimations = 32
    static let supportedPackSchema = 1
    
    private static let lock = NSRecursiveLock()
    private static var builtInsLoaded = false
    private static var packsLoaded = false
    
    static var packsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(packsDirName, isDirectory: true)
    }
    
    // MARK: Loading
    
    /// Loads the bundled animations, then the installed packs. Idempotent; this is what the app calls.
    /// Returns human-readable problems, one per bad file (an empty list means everything loaded).
    @discardableResult
    static func loadAll() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var problems = loadBuiltIns()
        problems.append(contentsOf: loadInstalledPacks())
        return problems
    }
    
    private struct Pending {
        let url: URL
        let label: String
        let expected: ClipAnimation.Direction?
    }
    
    @discardableResult
    static func loadBuiltIns() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var errors: [String] = []
        guard !builtInsLoaded else { return errors }
        
        var pending: [Pending] = []
        let fm = FileManager.default
        if let root = Bundle.main.url(forResource: assetDir, withExtension: nil) {
            for direction in ClipAnimation.Direction.allCases {
                let folder = root.appendingPathComponent(direction.rawValue, isDirectory: true)
                let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
                for name in names where name.hasSuffix(".json") {
                    pending.append(Pending(url: folder.appendingPathComponent(name),
                                           label: "\(direction.rawValue)/\(name)", expected: direction))
                }
            }
        }
        
        if pending.isEmpty {
            // Friendly fallback for the common mistake of adding the .json files as a plain group:
            // Xcode then flattens them into the bundle root and the folders are lost.
            let loose = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in loose {
                pending.append(Pending(url: url, label: url.lastPathComponent, expected: nil))
            }
            if loose.isEmpty {
                errors.append("The app bundle has no animations/in or animations/out folder: no animations available. Add the 'animations' folder to the Xcode target as a folder reference.")
                return errors
            }
        }
        
        // Files are independent except "mirrorOf" ones, which need their base registered first (an
        // "out" animation often mirrors an "in" one). Keep retrying the ones that were only waiting
        // on a base until a whole pass makes no progress.
        var progress = true
        var looseFileSkipped: [String] = []
        while !pending.isEmpty && progress {
            progress = false
            var stillPending: [Pending] = []
            for item in pending {
                do {
                    let text = try String(contentsOf: item.url, encoding: .utf8)
                    try ClipAnimationLoader.register(text, source: item.label, builtIn: true, expectedDirection: item.expected)
                    progress = true
                } catch let error as ClipAnimationFormatError {
                    if error.missingMirrorBase {
                        stillPending.append(item)
                    } else if item.expected == nil {
                        looseFileSkipped.append(item.label)     // some unrelated JSON in the bundle
                        progress = true
                    } else {
                        errors.append(error.message)
                        progress = true
                    }
                } catch {
                    errors.append("\(item.label): can't read file: \(error.localizedDescription)")
                    progress = true
                }
            }
            pending = stillPending
        }
        for item in pending {
            errors.append("\(item.label): its \"mirrorOf\" animation was never loaded")
        }
        if !looseFileSkipped.isEmpty && ClipAnimationLoader.list(.in).isEmpty && ClipAnimationLoader.list(.out).isEmpty {
            errors.append("No animation files were found. Add the 'animations' folder to the Xcode target as a folder reference.")
        }
        builtInsLoaded = true
        return errors
    }
    
    /// Loads the installed animation packs (after the built-ins). Idempotent; installs and removals
    /// keep the registry current themselves.
    @discardableResult
    static func loadInstalledPacks() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !packsLoaded else { return [] }
        loadBuiltIns()                       // pack ids are checked against the built-ins
        packsLoaded = true
        return loadInstalled(packsDir: packsDirectory)
    }
    
    // MARK: App-level entry points
    
    /// Installs the pack .zip the user picked (a security-scoped URL from the file importer).
    static func importPack(from url: URL) throws -> ClipAnimationInstallResult {
        lock.lock(); defer { lock.unlock() }
        loadAll()    // so the new pack is checked against everything already installed
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try install(zipURL: url, packsDir: packsDirectory)
    }
    
    static func installedPacks() -> [ClipAnimationPackInfo] {
        lock.lock(); defer { lock.unlock() }
        loadAll()
        return listInstalled(packsDir: packsDirectory)
    }
    
    static func removePack(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        loadAll()
        try uninstall(packsDir: packsDirectory, packID: id)
    }
    
    // MARK: Reading + validating a zip (no side effects on the registry or the packs folder)
    
    private struct Raw {
        var manifestText: String?
        /// entry path ("animations/in/x.json") -> JSON text, in zip order
        var animations: [(path: String, text: String)] = []
    }
    
    private struct Manifest {
        var id = ""
        var name = ""
        var version = 1
        var author = ""
        var description = ""
    }
    
    private static let allowedDirs: Set<String> = ["animations/", "animations/in/", "animations/out/"]
    private static let manifestName = "pack.json"
    
    private static func shown(_ name: String) -> String {
        String(name.prefix(60).map { ch -> Character in
            if let v = ch.unicodeScalars.first?.value, v < 0x20 || v == 0x7F { return "?" }
            return ch
        })
    }
    
    /// "animations/in/<id>.json" → (direction, id), or nil.
    private static func animationEntry(_ path: String) -> (ClipAnimation.Direction, String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "animations",
              let direction = ClipAnimation.Direction(rawValue: parts[1]),
              parts[2].hasSuffix(".json") else { return nil }
        let id = String(parts[2].dropLast(5))
        return ClipAnimationLoader.isValidID(id) ? (direction, id) : nil
    }
    
    private static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // editors on Windows like to add a BOM
        return text
    }
    
    private static func readZip(at url: URL) throws -> Raw {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ClipAnimationPackError("Couldn't read that file.") }
        guard size <= maxZipBytes else {
            throw ClipAnimationPackError("The file is larger than \(maxZipBytes / 1024) KB.")
        }
        
        let reader: ZipArchiveReader
        do { reader = try ZipArchiveReader(url: url) }
        catch let error as ZipError {
            if case .notAZip = error { throw ClipAnimationPackError("That isn't a valid .zip file.") }
            throw ClipAnimationPackError("Couldn't read the pack: \(error.localizedDescription)")
        }
        catch { throw ClipAnimationPackError("Couldn't read the pack: \(error.localizedDescription)") }
        
        guard reader.entries.count <= maxEntries else {
            throw ClipAnimationPackError("The pack has too many files (limit \(maxEntries)).")
        }
        
        // Pass 1: names and claimed sizes. Nothing is extracted until every entry has passed.
        var claimed: Int64 = 0
        var seen = Set<String>()
        var wanted: [ZipArchiveReader.Entry] = []
        for entry in reader.entries {
            let name = entry.path
            if entry.isSymlink { throw ClipAnimationPackError("Unexpected link in the pack: '\(shown(name))'.") }
            if entry.isDirectory {
                guard allowedDirs.contains(name.hasSuffix("/") ? name : name + "/") else {
                    throw ClipAnimationPackError("Unexpected folder in the pack: '\(shown(name))'.")
                }
                continue
            }
            guard name == manifestName || animationEntry(name) != nil else {
                throw ClipAnimationPackError("Unexpected file in the pack: '\(shown(name))'. A pack may only contain pack.json and animations/in|out/<id>.json.")
            }
            guard seen.insert(name).inserted else {
                throw ClipAnimationPackError("The pack lists '\(shown(name))' twice.")
            }
            guard entry.uncompressedSize <= UInt64(maxEntryBytes) else {
                throw ClipAnimationPackError("'\(shown(name))' is larger than \(maxEntryBytes / 1024) KB.")
            }
            claimed += Int64(entry.uncompressedSize)
            guard claimed <= maxTotalBytes else {
                throw ClipAnimationPackError("The pack is larger than \(maxTotalBytes / 1024 / 1024) MB when unpacked.")
            }
            wanted.append(entry)
        }
        
        // Pass 2: extract each whitelisted entry to a scratch file whose name we choose, counting the
        // bytes actually written (a zip can lie about its sizes) and stopping at the cap.
        let scratch = fm.temporaryDirectory.appendingPathComponent("animpack-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        
        var raw = Raw()
        var total: Int64 = 0
        for (index, entry) in wanted.enumerated() {
            let file = scratch.appendingPathComponent("e\(index)")
            var written: Int64 = 0
            var overCap = false
            do {
                try reader.extract(entry, to: file, progress: { count in
                    written += Int64(count)
                    if written > maxEntryBytes || total + written > maxTotalBytes { overCap = true }
                }, isCancelled: { overCap })
            } catch {
                if overCap {
                    throw ClipAnimationPackError(written > maxEntryBytes
                        ? "'\(shown(entry.path))' is larger than \(maxEntryBytes / 1024) KB."
                        : "The pack is larger than \(maxTotalBytes / 1024 / 1024) MB when unpacked.")
                }
                throw ClipAnimationPackError("Couldn't read the pack: \(error.localizedDescription)")
            }
            guard let data = try? Data(contentsOf: file), Int64(data.count) <= maxEntryBytes else {
                throw ClipAnimationPackError("Couldn't read '\(shown(entry.path))' from the pack.")
            }
            total += Int64(data.count)
            if entry.path == manifestName { raw.manifestText = decode(data) }
            else { raw.animations.append((entry.path, decode(data))) }
        }
        
        guard raw.manifestText != nil else {
            throw ClipAnimationPackError("pack.json is missing. Is this an animation pack .zip?")
        }
        guard !raw.animations.isEmpty else { throw ClipAnimationPackError("The pack contains no animations.") }
        guard raw.animations.count <= maxAnimations else {
            throw ClipAnimationPackError("The pack has more than \(maxAnimations) animations.")
        }
        return raw
    }
    
    private static func parseManifest(_ text: String) throws -> Manifest {
        do {
            let m = try ClipAnimationLoader.parseObject(text)
            try ClipAnimationLoader.allowKeys(m, "$", ["schema", "id", "name", "version", "author", "description"])
            let schema = try ClipAnimationLoader.reqNumber(m, "schema", "$")
            guard schema == Double(supportedPackSchema) else {
                throw ClipAnimationFormatError("$.schema: unsupported pack schema \(ClipAnimationLoader.fmt(schema)) (this app reads \(supportedPackSchema))")
            }
            var manifest = Manifest()
            manifest.id = try ClipAnimationLoader.reqString(m, "id", "$", 64)
            guard ClipAnimationLoader.isValidID(manifest.id) else {
                throw ClipAnimationFormatError("$.id: must be 1-64 characters of a-z 0-9 _ -")
            }
            let name = try ClipAnimationLoader.optString(m, "name", "$", 64)
            manifest.name = (name ?? "").isEmpty ? manifest.id : name!
            if m["version"] != nil {
                let v = try ClipAnimationLoader.reqNumber(m, "version", "$")
                guard v == v.rounded(), v >= 1, v <= 1_000_000 else {
                    throw ClipAnimationFormatError("$.version: must be a whole number 1-1000000")
                }
                manifest.version = Int(v)
            }
            manifest.author = try ClipAnimationLoader.optString(m, "author", "$", 64) ?? ""
            manifest.description = try ClipAnimationLoader.optString(m, "description", "$", 256) ?? ""
            return manifest
        } catch let error as ClipAnimationFormatError {
            throw ClipAnimationPackError("pack.json: \(error.message)")
        }
    }
    
    /// Parses every animation of the pack WITHOUT touching the registry (a mirrorOf may point at
    /// another animation of the same pack, or at one that is already registered). Returns them by
    /// id, in dependency order.
    private static func parseAll(_ animations: [(path: String, text: String)]) throws -> [(id: String, animation: ClipAnimation)] {
        var staged: [(id: String, animation: ClipAnimation)] = []
        var stagedByID: [String: ClipAnimation] = [:]
        var pending = animations
        var lastError: [String: String] = [:]
        var progress = true
        while !pending.isEmpty && progress {
            progress = false
            var next: [(path: String, text: String)] = []
            for item in pending {
                guard let (direction, stem) = animationEntry(item.path) else {
                    throw ClipAnimationPackError("Unexpected file in the pack: '\(shown(item.path))'.")
                }
                do {
                    let animation = try ClipAnimationLoader.parse(item.text, source: item.path,
                                                                  extraBases: stagedByID, expectedDirection: direction)
                    guard animation.id == stem else {
                        throw ClipAnimationPackError("\(item.path): the file name must match the animation's id ('\(animation.id)').")
                    }
                    guard stagedByID[animation.id] == nil else {
                        throw ClipAnimationPackError("The pack defines the animation id '\(animation.id)' twice.")
                    }
                    stagedByID[animation.id] = animation
                    staged.append((animation.id, animation))
                    progress = true
                } catch let error as ClipAnimationFormatError {
                    if !error.missingMirrorBase { throw ClipAnimationPackError(error.message) }
                    next.append(item)
                    lastError[item.path] = error.message
                }
            }
            pending = next
        }
        if let first = pending.first { throw ClipAnimationPackError(lastError[first.path] ?? "A mirrorOf animation was never resolved.") }
        return staged
    }
    
    // MARK: Install / uninstall / list
    
    /// Validates the pack in `zipURL` and installs it under `packsDir`, replacing an installed pack
    /// with the same id (an update). On success its animations are registered immediately. On ANY
    /// failure nothing has changed.
    private static func install(zipURL: URL, packsDir: URL) throws -> ClipAnimationInstallResult {
        let raw = try readZip(at: zipURL)
        let manifest = try parseManifest(raw.manifestText ?? "")
        let staged = try parseAll(raw.animations)
        
        let existing = findInstalled(packsDir: packsDir, id: manifest.id)
        var own = Set<String>()
        if let existing { own.formUnion(existing.inIDs); own.formUnion(existing.outIDs) }
        for (id, _) in staged {
            if ClipAnimationLoader.isBuiltIn(id) {
                throw ClipAnimationPackError("The animation id '\(id)' is a built-in animation and can't be provided by a pack.")
            }
            if ClipAnimationLoader.get(id) != nil && !own.contains(id) {
                throw ClipAnimationPackError("The animation id '\(id)' is already used by another installed animation.")
            }
        }
        
        let fm = FileManager.default
        do { try fm.createDirectory(at: packsDir, withIntermediateDirectories: true) }
        catch { throw ClipAnimationPackError("Couldn't create the animation packs folder.") }
        
        let stamp = UUID().uuidString
        let staging = packsDir.appendingPathComponent(".staging-\(stamp)", isDirectory: true)
        let target = packsDir.appendingPathComponent(manifest.id, isDirectory: true)
        let old = packsDir.appendingPathComponent(".old-\(stamp)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        
        do {
            try writePack(to: staging, raw: raw)
            let hadOld = fm.fileExists(atPath: target.path)
            if hadOld {
                do { try fm.moveItem(at: target, to: old) }
                catch { throw ClipAnimationPackError("Couldn't replace the installed pack (is it in use?).") }
            }
            do { try fm.moveItem(at: staging, to: target) }
            catch {
                if hadOld { try? fm.moveItem(at: old, to: target) }     // put the previous version back
                throw ClipAnimationPackError("Couldn't finish installing the pack.")
            }
            if hadOld { try? fm.removeItem(at: old) }
        } catch let error as ClipAnimationPackError {
            throw error
        } catch {
            throw ClipAnimationPackError("Couldn't write the pack: \(error.localizedDescription)")
        }
        
        for id in own { ClipAnimationLoader.unregister(id) }
        do {
            for (id, animation) in staged {
                try ClipAnimationLoader.registerParsed(animation, builtIn: false, source: id)
            }
        } catch {
            throw ClipAnimationPackError(error.localizedDescription)     // can't happen after the checks above
        }
        return ClipAnimationInstallResult(pack: readInfo(dir: target, id: manifest.id),
                                          replacedVersion: existing?.version ?? 0)
    }
    
    /// Writes the already-validated pack: file names are rebuilt from the validated ids, never from
    /// zip entry names.
    private static func writePack(to dir: URL, raw: Raw) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((raw.manifestText ?? "").utf8).write(to: dir.appendingPathComponent(manifestName), options: .atomic)
        for item in raw.animations {
            guard let (direction, id) = animationEntry(item.path) else { continue }
            let folder = dir.appendingPathComponent("animations/\(direction.rawValue)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(item.text.utf8).write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }
    
    /// Removes an installed pack and its animations (clips that used them keep their saved id and
    /// show "not installed").
    private static func uninstall(packsDir: URL, packID: String) throws {
        guard ClipAnimationLoader.isValidID(packID) else { throw ClipAnimationPackError("Not a valid pack id.") }
        let dir = packsDir.appendingPathComponent(packID, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ClipAnimationPackError("That pack isn't installed.")
        }
        let info = readInfo(dir: dir, id: packID)
        for id in info.inIDs + info.outIDs { ClipAnimationLoader.unregister(id) }
        try? FileManager.default.removeItem(at: dir)
        if FileManager.default.fileExists(atPath: dir.path) {
            throw ClipAnimationPackError("Couldn't remove the pack's files.")
        }
    }
    
    /// The installed packs, sorted by id. Unreadable ones are included (marked damaged) so they can
    /// be removed.
    private static func listInstalled(packsDir: URL) -> [ClipAnimationPackInfo] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: packsDir.path)) ?? []).sorted()
        return names.compactMap { name in
            let dir = packsDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard ClipAnimationLoader.isValidID(name),
                  FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return readInfo(dir: dir, id: name)
        }
    }
    
    private static func findInstalled(packsDir: URL, id: String) -> ClipAnimationPackInfo? {
        let dir = packsDir.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            ? readInfo(dir: dir, id: id) : nil
    }
    
    private static func readInfo(dir: URL, id: String) -> ClipAnimationPackInfo {
        let inIDs = animationIDs(in: dir.appendingPathComponent("animations/in", isDirectory: true), direction: .in)
        let outIDs = animationIDs(in: dir.appendingPathComponent("animations/out", isDirectory: true), direction: .out)
        do {
            let text = try String(contentsOf: dir.appendingPathComponent(manifestName), encoding: .utf8)
            let manifest = try parseManifest(text)
            guard manifest.id == id else { throw ClipAnimationPackError("folder name differs from pack id") }
            return ClipAnimationPackInfo(id: manifest.id, name: manifest.name, version: manifest.version,
                                         author: manifest.author, packDescription: manifest.description,
                                         inIDs: inIDs, outIDs: outIDs, damaged: false)
        } catch {
            return ClipAnimationPackInfo(id: id, name: "\(id) (damaged)", version: 0, author: "",
                                         packDescription: "", inIDs: inIDs, outIDs: outIDs, damaged: true)
        }
    }
    
    private static func animationIDs(in folder: URL, direction: ClipAnimation.Direction) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return names.compactMap { name in
            animationEntry("animations/\(direction.rawValue)/\(name)")?.1
        }
    }
    
    // MARK: Loading installed packs at startup
    
    /// Registers every installed pack's animations (call after the built-ins are loaded). Returns one
    /// message per problem; a bad pack or file never stops the others. Also cleans up folders left
    /// behind by an interrupted install.
    private static func loadInstalled(packsDir: URL) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: packsDir.path)) ?? []).sorted()
        for name in names {
            let dir = packsDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if name.hasPrefix(".") { try? fm.removeItem(at: dir); continue }   // .staging-* / .old-* leftovers
            guard ClipAnimationLoader.isValidID(name) else { continue }
            loadPackDirectory(dir, problems: &problems)
        }
        return problems
    }
    
    private static func loadPackDirectory(_ dir: URL, problems: inout [String]) {
        let pack = dir.lastPathComponent
        do {
            let text = try String(contentsOf: dir.appendingPathComponent(manifestName), encoding: .utf8)
            let manifest = try parseManifest(text)
            guard manifest.id == pack else {
                throw ClipAnimationPackError("pack.json: id '\(manifest.id)' doesn't match the folder name")
            }
        } catch {
            problems.append("Pack '\(pack)' skipped: \(error.localizedDescription)")
            return
        }
        
        var texts: [(path: String, text: String)] = []
        let fm = FileManager.default
        for direction in ClipAnimation.Direction.allCases {
            let folder = dir.appendingPathComponent("animations/\(direction.rawValue)", isDirectory: true)
            for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                let entry = "animations/\(direction.rawValue)/\(name)"
                guard animationEntry(entry) != nil else { continue }
                let file = folder.appendingPathComponent(name)
                do {
                    let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if size > maxEntryBytes { throw ClipAnimationPackError("file is too large") }
                    texts.append((entry, try String(contentsOf: file, encoding: .utf8)))
                } catch {
                    problems.append("Pack '\(pack)': \(entry): \(error.localizedDescription)")
                }
            }
        }
        
        var pending = texts
        var progress = true
        var waiting: [String: String] = [:]
        while !pending.isEmpty && progress {
            progress = false
            var next: [(path: String, text: String)] = []
            for item in pending {
                guard let (direction, stem) = animationEntry(item.path) else { continue }
                do {
                    let animation = try ClipAnimationLoader.parse(item.text, source: "pack '\(pack)': \(item.path)",
                                                                  extraBases: nil, expectedDirection: direction)
                    if animation.id != stem {
                        problems.append("Pack '\(pack)': \(item.path): the file name must match the animation's id")
                    } else if ClipAnimationLoader.get(animation.id) != nil {
                        problems.append("Pack '\(pack)': animation '\(animation.id)' skipped, that id is already in use")
                    } else {
                        try ClipAnimationLoader.registerParsed(animation, builtIn: false, source: item.path)
                    }
                    progress = true
                } catch let error as ClipAnimationFormatError {
                    if error.missingMirrorBase { next.append(item); waiting[item.path] = error.message }
                    else { problems.append(error.message); progress = true }
                } catch {
                    problems.append("Pack '\(pack)': \(item.path): \(error.localizedDescription)")
                    progress = true
                }
            }
            pending = next
        }
        for item in pending {
            problems.append(waiting[item.path] ?? "Pack '\(pack)': \(item.path): its mirrorOf animation was never loaded")
        }
    }
}
