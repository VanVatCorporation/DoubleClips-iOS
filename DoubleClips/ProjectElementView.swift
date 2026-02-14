import SwiftUI

struct ProjectElementView: View {
    let project: ProjectData
    var image: Image? // In a real app this might be a URL or AsyncImage loaded from projectPath/preview.png
    
    // Actions
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onShare: () -> Void
    var onClone: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Preview Image (80dp x 80dp)
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12)) // ShapeAppearance.Material3.Corner.Medium approx 12dp
            } else {
                Rectangle()
                    .fill(Color.mdSurfaceContainerHigh)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Title and Details
            VStack(alignment: .leading, spacing: 4) {
                Text(project.projectTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text(formatDate(project.projectTimestamp))
                    .font(.system(size: 14))
                    .foregroundColor(.mdOnSurfaceVariant)
                
                HStack(spacing: 4) {
                    Text(formatDuration(project.projectDuration))
                        .font(.system(size: 12))
                        .foregroundColor(.mdOnSurfaceVariant)
                    
                    Text("•")
                        .font(.system(size: 12))
                        .foregroundColor(.mdOnSurfaceVariant)
                    
                    Text(formatSize(project.projectSize))
                        .font(.system(size: 12))
                        .foregroundColor(.mdOnSurfaceVariant)
                }
            }
            
            Spacer()
            
            // More Button
            Button(action: {
                // Trigger More Action
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundColor(.mdOnSurfaceVariant)
                    .frame(width: 48, height: 48) // Touch target
            }
        }
        .padding(12) // Internal Padding 12dp
        .background(.ultraThinMaterial) // Liquid Glass Effect
        .cornerRadius(16) // Card Corner Radius
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.mdOutline.opacity(0.2), lineWidth: 0.5) // Stroke 0.5dp
        )
        // External margins handled by container (List/VStack)
    }
    
    // Helpers
    func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
    
    func formatDuration(_ duration: Int64) -> String {
        let seconds = duration / 1000
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
    
    func formatSize(_ size: Int64) -> String {
        let mb = Double(size) / 1024 / 1024
        return String(format: "%.0fMB", mb)
    }
}
