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
    static func loadProperties(from path: String) -> ProjectData? {
        let propertiesPath = IOHelper.combinePath(path, Constants.DEFAULT_PROJECT_PROPERTIES_FILENAME)
        let json = IOHelper.readFromFile(propertiesPath)
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProjectData.self, from: data)
    }
    
    // MARK: - Operations (Rename, Clone)
    
    /// Renames the project directory and updates the internal title.
    /// Equivalent of `ProjectData.setProjectTitle(context, title, true)`
    mutating func rename(to newTitle: String) -> Bool {
        let cleanTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }
        
        // 1. Determine new directory path
        // Parent folder of current project
        let parentDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        // New project folder name (Title is used as folder name in Android implementation logic, though create uses project_N)
        // Android logic: IOHelper.CombinePath(Constants.DEFAULT_PROJECT_DIRECTORY(context), projectTitle);
        // We should follow the same pattern if we want 1:1 sync, or just keep project_N and change title in json.
        // Android SPECIFICALLY renames the directory:
        // String newDir = IOHelper.CombinePath(Constants.DEFAULT_PROJECT_DIRECTORY(context), projectTitle);
        // So we must rename the directory too.
        
        let newPath = IOHelper.combinePath(Constants.DEFAULT_PROJECT_DIRECTORY, cleanTitle)
        
        // Avoid overwriting existing folder
        if IOHelper.isFileExist(newPath) && newPath != projectPath {
            return false 
        }
        
        // 2. Rename Directory
        do {
            try FileManager.default.moveItem(atPath: projectPath, toPath: newPath)
        } catch {
            print("Rename failed: \(error)")
            return false
        }
        
        // 3. Update properties
        self.projectPath = newPath
        self.projectTitle = cleanTitle
        self.savePropertiesAtProject()
        
        return true
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
