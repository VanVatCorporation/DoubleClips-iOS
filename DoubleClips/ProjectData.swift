import Foundation

struct ProjectData: Identifiable, Codable {
    var id: String { projectPath } // Unique identifier
    var projectPath: String
    var projectTitle: String
    var projectTimestamp: Int64
    var projectSize: Int64
    var projectDuration: Int64
    
    // Formatting Helpers
    
    var dateString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(projectTimestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss" // Matching typical default or DateHelper logic
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
