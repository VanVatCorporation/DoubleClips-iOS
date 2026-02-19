import SwiftUI

struct ProjectElementView: View {
    let project: ProjectData
    var image: Image? // In a real app this might be a URL or AsyncImage loaded from projectPath/preview.png
    
    // Actions
    var onEdit: () -> Void      // Enter Editor
    var onEditTitle: () -> Void // Rename Project
    var onShare: () -> Void
    var onClone: () -> Void
    var onUpload: () -> Void    // Upload to Cloud
    var onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Preview Image (80dp x 80dp)
            thumbnailView
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Title and Details
            VStack(alignment: .leading, spacing: 4) {
                Text(project.projectTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    // Disable the parent context menu for this specific element
                    // so the long press triggers onEditTitle instead of the preview.
                    .contextMenu(menuItems: { EmptyView() })
                    .onLongPressGesture {
                        onEditTitle()
                    }
                
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
            
            // More Options Button (Menu)
            Menu {
                menuActions
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundColor(.mdOnSurfaceVariant)
                    .frame(width: Dimens.touchTargetMin, height: Dimens.touchTargetMin)
                    .contentShape(Rectangle())
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.mdOutline.opacity(0.2), lineWidth: 0.5)
        )
        // ── Context Menu (Long Press Preview) ──────────────────────────────
        // Equivalent to Safari link preview / Messenger conversation preview.
        // Shows a rich preview card + the same actions as the 3-dot menu.
        .contextMenu {
            menuActions
        } preview: {
            projectPreviewCard
        }
    }
    
    // MARK: - Shared Menu Actions
    // Defined once, used in both the 3-dot Menu and the context menu
    @ViewBuilder
    private var menuActions: some View {
        Button(action: onEditTitle) {
            Label("Edit title", systemImage: "pencil")
        }
        
        Button(action: onShare) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        
        Button(action: onUpload) {
            Label("Upload", systemImage: "icloud.and.arrow.up")
        }
        
        Button(action: onClone) {
            Label("Clone", systemImage: "doc.on.doc")
        }
        
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
    
    // MARK: - Context Menu Preview Card
    // This is the rich preview shown when the user long-presses the card.
    // Shows the project thumbnail (large), title, date, duration, and size.
    private var projectPreviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Large Thumbnail
            ZStack {
                if let image = image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.mdSurfaceContainerHigh
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Preview")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 320, height: 180)
            .clipped()
            
            // Project Info
            VStack(alignment: .leading, spacing: 6) {
                Text(project.projectTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                HStack(spacing: 12) {
                    Label(formatDate(project.projectTimestamp), systemImage: "calendar")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 16) {
                    Label(formatDuration(project.projectDuration), systemImage: "clock")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    
                    Label(formatSize(project.projectSize), systemImage: "internaldrive")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
            .background(Color.mdBackground)
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Thumbnail Helper
    @ViewBuilder
    private var thumbnailView: some View {
        if let image = image {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.mdSurfaceContainerHigh
                .overlay(
                    Image(systemName: "film.stack")
                        .foregroundColor(.secondary)
                )
        }
    }
    
    // MARK: - Formatters
    func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy hh:mm:ss"
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
