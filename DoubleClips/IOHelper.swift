import Foundation

/// iOS equivalent of IOHelper.java
/// Provides file system utilities: path combining, read/write (text + binary),
/// append, truncated append, directory creation, copy, delete, and file listing.
///
/// Key differences from Android:
///   - No `Context` parameter needed — iOS doesn't require a context for file I/O.
///   - `getPersistentDataPath` returns the app's Documents directory.
///   - All operations are synchronous (same as the Java original).
///   - Error handling uses Swift's `try/catch` instead of checked exceptions.
enum IOHelper {

    // MARK: - Base Paths

    /// Equivalent of `context.getExternalFilesDir(null).getAbsolutePath()`
    /// On iOS, the Documents directory is the closest equivalent —
    /// it is persistent, backed up by iCloud, and user-accessible via Files app.
    static var persistentDataPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.path
    }

    // MARK: - Path Combining

    /// Equivalent of `IOHelper.CombinePath(String... paths)`
    /// Joins path components and normalises duplicate slashes.
    static func combinePath(_ paths: String...) -> String {
        combinePath(paths)
    }

    static func combinePath(_ paths: [String]) -> String {
        // Join with "/" separator
        var result = paths.joined(separator: "/")
        // Collapse multiple consecutive slashes into one
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        // Ensure leading slash
        if !result.hasPrefix("/") {
            result = "/" + result
        }
        return result
    }

    // MARK: - Next Index Path

    /// Equivalent of `getNextIndexPathInFolder(context, folderPath, prefix, extension, createEmptyFile)`
    /// Returns the next available numbered path in a folder, e.g. `.../project_0`, `.../project_1`, …
    @discardableResult
    static func getNextIndexPathInFolder(
        folderPath: String,
        prefix: String = "",
        extension ext: String = "",
        createEmptyFile: Bool
    ) -> String {
        var index = 0
        var candidate: String
        repeat {
            candidate = combinePath(folderPath, "\(prefix)\(index)") + ext
            index += 1
        } while isFileExist(candidate)

        if createEmptyFile {
            createEmptyFileIfNotExist(candidate)
        }
        return candidate
    }

    // MARK: - File Size

    /// Equivalent of `getFileSize(context, filePath)`
    /// Returns the total byte size of a file or recursively of a directory.
    static func getFileSize(_ filePath: String) -> Int {
        let url = URL(fileURLWithPath: filePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else { return 0 }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: filePath, isDirectory: &isDir)

        if isDir.boolValue {
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total = 0
            for case let fileURL as URL in enumerator {
                total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return total
        } else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }

    // MARK: - Read

    /// Equivalent of `readFromFile(context, filePath)` → String
    static func readFromFile(_ filePath: String) -> String {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            createEmptyDirectories(URL(fileURLWithPath: filePath).deletingLastPathComponent().path)
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Equivalent of `readFromFileAsRaw(context, filePath)` → byte[]
    static func readFromFileAsRaw(_ filePath: String) -> Data {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    // MARK: - Write

    /// Equivalent of `writeToFile(context, filePath, content)`
    static func writeToFile(_ filePath: String, content: String) {
        createEmptyFile(filePath)
        let url = URL(fileURLWithPath: filePath)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Equivalent of `writeToFileAsRaw(context, filePath, content)`
    static func writeToFileAsRaw(_ filePath: String, content: Data) {
        createEmptyFile(filePath)
        let url = URL(fileURLWithPath: filePath)
        try? content.write(to: url, options: .atomic)
    }

    // MARK: - Append

    /// Equivalent of `appendToFile(context, filePath, content)`
    static func appendToFile(_ filePath: String, content: String) {
        let existing = readFromFile(filePath)
        writeToFile(filePath, content: existing + "\n" + content)
    }

    /// Equivalent of `appendToFileAsRaw(context, filePath, content)`
    static func appendToFileAsRaw(_ filePath: String, content: Data) {
        var existing = readFromFileAsRaw(filePath)
        existing.append(content)
        writeToFileAsRaw(filePath, content: existing)
    }

    // MARK: - Truncated Append

    /// Equivalent of `appendToFileTrunc(context, filePath, content, truncByte)`
    /// Appends text but keeps the file under `truncByte` characters by trimming the oldest content.
    static func appendToFileTrunc(_ filePath: String, content: String, truncByte: Int) {
        var existing = readFromFile(filePath)
        if existing.count > truncByte {
            existing = String(existing.suffix(truncByte))
        }
        writeToFile(filePath, content: existing + "\n" + content)
    }

    /// Equivalent of `appendToFileTruncAsRaw(context, filePath, content, truncByte)`
    static func appendToFileTruncAsRaw(_ filePath: String, content: Data, truncByte: Int) {
        var existing = readFromFileAsRaw(filePath)
        if existing.count > truncByte {
            existing = existing.suffix(truncByte)
        }
        existing.append(content)
        writeToFileAsRaw(filePath, content: existing)
    }

    // MARK: - Directory / File Creation

    /// Equivalent of `createEmptyDirectories(filePath)`
    static func createEmptyDirectories(_ dirPath: String) {
        try? FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Equivalent of `createEmptyFile(context, filePath)`
    /// Creates the file and all parent directories. Overwrites with empty content.
    static func createEmptyFile(_ filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        createEmptyDirectories(url.deletingLastPathComponent().path)
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }
        // Write empty string (matches Java behaviour of always writing "")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Equivalent of `createEmptyFileIfNotExist(context, filePath)`
    static func createEmptyFileIfNotExist(_ filePath: String, additionalText: String = "") {
        if !isFileExist(filePath) {
            writeToFile(filePath, content: additionalText)
        }
    }

    // MARK: - Existence Check

    /// Equivalent of `isFileExist(filePath)`
    static func isFileExist(_ filePath: String) -> Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    // MARK: - Delete

    /// Equivalent of `deleteFile(filePath)`
    @discardableResult
    static func deleteFile(_ filePath: String) -> Bool {
        (try? FileManager.default.removeItem(atPath: filePath)) != nil
    }

    /// Equivalent of `deleteDir(filePath)` — recursively deletes directory and contents
    @discardableResult
    static func deleteDir(_ dirPath: String) -> Bool {
        (try? FileManager.default.removeItem(atPath: dirPath)) != nil
    }

    /// Equivalent of `deleteFilesInDir(filePath)` — deletes contents but keeps the directory
    @discardableResult
    static func deleteFilesInDir(_ dirPath: String) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return true }
        var success = true
        for item in contents {
            let itemPath = combinePath(dirPath, item)
            if ((try? fm.removeItem(atPath: itemPath) == ()).map({ _ in true }) == nil) ?? false {
                success = false
            }
        }
        return success
    }

    // MARK: - Copy

    /// Equivalent of `copyFile(context, filePath, destinationFilePath)`
    static func copyFile(from sourcePath: String, to destinationPath: String) {
        let data = readFromFileAsRaw(sourcePath)
        writeToFileAsRaw(destinationPath, content: data)
    }

    /// Equivalent of `copyDir(context, filePath, destinationFilePath)`
    static func copyDir(from sourcePath: String, to destinationPath: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: sourcePath, isDirectory: &isDir)

        if isDir.boolValue {
            createEmptyDirectories(destinationPath)
            guard let children = try? fm.contentsOfDirectory(atPath: sourcePath) else { return }
            for child in children {
                copyDir(
                    from: combinePath(sourcePath, child),
                    to: combinePath(destinationPath, child)
                )
            }
        } else {
            copyFile(from: sourcePath, to: destinationPath)
        }
    }

    // MARK: - File Listing

    enum FileListing {
        case directories, files, both
    }

    /// Equivalent of `listFiles(context, directoryPath, options)`
    static func listFiles(_ directoryPath: String, options: FileListing) -> [URL] {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: directoryPath)
        guard let contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        switch options {
        case .files:
            return contents.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
            }
        case .directories:
            return contents.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        case .both:
            return contents
        }
    }
}
