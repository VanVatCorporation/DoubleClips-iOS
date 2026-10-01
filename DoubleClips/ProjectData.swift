import Foundation

/// iOS equivalent of MainAreaScreen.ProjectData
/// Codable so it can be serialised to/from JSON (project.properties file).
struct ProjectData: Identifiable, Codable, Hashable {

    // MARK: - Fields (match Java field names for JSON compatibility)
    var version: String?
    var projectPath: String
    var projectTitle: String
    var projectTimestamp: Int64
    var projectSize: Int64
    var projectDuration: Int64

    /// Stable identity based on the project directory path
    var id: String { projectPath }

    // MARK: - Init
    init(projectPath: String,
         projectTitle: String,
         projectTimestamp: Int64,
         projectSize: Int64,
         projectDuration: Int64) {
        self.projectPath = projectPath
        self.projectTitle = projectTitle
        self.projectTimestamp = projectTimestamp
        self.projectSize = projectSize
        self.projectDuration = projectDuration
    }

    // MARK: - Disk I/O (equivalent of Java savePropertiesAtProject / loadProperties)

    /// Saves this project's metadata to `<projectPath>/project.properties` as JSON.
    /// Equivalent of `ProjectData.savePropertiesAtProject(context)`
    func savePropertiesAtProject() {
        let propertiesPath = IOHelper.combinePath(projectPath, Constants.DEFAULT_PROJECT_PROPERTIES_FILENAME)
        if let json = try? JSONEncoder().encode(self),
           let jsonString = String(data: json, encoding: .utf8) {
            IOHelper.writeToFile(propertiesPath, content: jsonString)
        }
    }

    /// Loads a ProjectData from `<path>/project.properties`.
    /// Returns `nil` if the file doesn't exist or can't be decoded.
    /// Equivalent of `ProjectData.loadProperties(context, path)`
    ///
    /// IMPORTANT: the `projectPath` stored inside the JSON is NOT trusted. On iOS the app
    /// sandbox path (`/var/mobile/Containers/Data/Application/<UUID>/…`) can change between
    /// launches — app update, reinstall over existing data, backup restore — while the files
    /// themselves are carried over. A path saved yesterday then points into a container that
    /// no longer exists, so delete / rename / open would silently act on nothing. The folder we
    /// actually found the project in is the source of truth, so we re-anchor to it here (and
    /// rewrite the JSON so it stays correct).
    static func loadProperties(from path: String) -> ProjectData? {
        let propertiesPath = IOHelper.combinePath(path, Constants.DEFAULT_PROJECT_PROPERTIES_FILENAME)
        let json = IOHelper.readFromFile(propertiesPath)
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(ProjectData.self, from: data) else { return nil }
        
        let stored = URL(fileURLWithPath: decoded.projectPath).resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if stored != actual {
            print("[Project] Re-anchored stale projectPath\n  was: \(decoded.projectPath)\n  now: \(path)")
            decoded.projectPath = path
            decoded.savePropertiesAtProject()
        }
        return decoded
    }
    
    // MARK: - Errors
    
    enum ProjectError: LocalizedError {
        case emptyTitle
        case alreadyExists(String)
        case io(String)
        
        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "The project name can't be empty."
            case .alreadyExists(let name): return "A project named \"\(name)\" already exists."
            case .io(let message): return message
            }
        }
    }
    
    /// Folder-safe version of a title (no path separators or characters iOS/Android dislike).
    static func sanitizedFolderName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name
    }
    
    // MARK: - Operations (Rename, Clone)
    
    /// Renames the project directory and updates the internal title.
    /// Equivalent of `ProjectData.setProjectTitle(context, title, true)`.
    /// Throws instead of failing silently, so the UI can tell the user what went wrong.
    mutating func rename(to newTitle: String) throws {
        let typedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = ProjectData.sanitizedFolderName(typedTitle)
        guard !folderName.isEmpty else { throw ProjectError.emptyTitle }
        
        let parentDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        let newPath = IOHelper.combinePath(parentDir, folderName)
        
        // APFS is case-insensitive by default: a case-only change keeps the folder as is.
        if newPath.lowercased() != projectPath.lowercased() {
            if IOHelper.isFileExist(newPath) { throw ProjectError.alreadyExists(folderName) }
            do {
                try FileManager.default.moveItem(atPath: projectPath, toPath: newPath)
            } catch {
                throw ProjectError.io("Couldn't rename the project: \(error.localizedDescription)")
            }
            projectPath = newPath
        }
        
        projectTitle = typedTitle
        savePropertiesAtProject()
    }
    
    /// Deletes the project folder. A folder that is already gone counts as deleted;
    /// any real failure is reported instead of being swallowed.
    func delete() throws {
        guard IOHelper.isFileExist(projectPath) else { return }
        do {
            try FileManager.default.removeItem(atPath: projectPath)
        } catch {
            throw ProjectError.io("Couldn't delete the project: \(error.localizedDescription)")
        }
    }
    
    /// Clones the project to a new directory.
    func clone() -> ProjectData? {
        // Generate new project path
        let newPath = IOHelper.getNextIndexPathInFolder(
            folderPath: Constants.DEFAULT_PROJECT_DIRECTORY,
            prefix: "project_",
            extension: "",
            createEmptyFile: false
        )
        
        // Copy directory
        IOHelper.copyDir(from: projectPath, to: newPath)
        
        // Update properties in the new project
        var clonedData = self
        clonedData.projectPath = newPath
        clonedData.projectTitle = "\(self.projectTitle) (Copy)"
        clonedData.projectTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        // Save new properties to the new location
        clonedData.savePropertiesAtProject()
        
        return clonedData
    }

    // MARK: - Formatting Helpers

    var dateString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(projectTimestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }

    var sizeString: String {
        let sizeInMB = Double(projectSize) / 1024.0 / 1024.0
        return String(format: "%.2fMB", sizeInMB)
    }

    var durationString: String {
        let seconds = projectDuration / 1000
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
