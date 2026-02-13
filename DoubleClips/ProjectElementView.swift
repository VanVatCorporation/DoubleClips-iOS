import SwiftUI

struct ProjectElementView: View {
    let project: ProjectData
    var image: Image // In a real app this might be a URL or AsyncImage loaded from projectPath/preview.png
    
    // Actions
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onShare: () -> Void
    var onClone: () -> Void
    
    var body: some View {
        HStack(spacing: Dimens.spacingSm) {
            // Preview Thumbnail
            ZStack(alignment: .bottomTrailing) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 85, height: 85)
                    .background(Color.mdSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: Dimens.cornerMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: Dimens.cornerMd)
                            .stroke(Color.mdOutline, lineWidth: 1)
                    )
                
                // Duration Badge
                Text(project.durationString)
                    .font(.mdLabelSmall)
                    .fontWeight(.bold)
                    .foregroundColor(.mdOnTertiaryContainer)
                    .padding(.horizontal, Dimens.spacingXs)
                    .padding(.vertical, 2)
                    .background(Color.mdTertiaryContainer)
                    .cornerRadius(Dimens.cornerXs)
                    .padding(4)
            }
            
            // Content Area
            VStack(alignment: .leading, spacing: 2) {
                Text(project.projectTitle)
                    .font(.mdTitleMedium)
                    .fontWeight(.bold)
                    .foregroundColor(.mdOnSurface)
                    .lineLimit(2)
                
                Text(project.dateString)
                    .font(.mdBodySmall)
                    .foregroundColor(.mdOnSurfaceVariant)
                    .padding(.top, Dimens.spacingXs)
                
                Text(project.sizeString)
                    .font(.mdBodySmall)
                    .foregroundColor(.mdOnSurfaceVariant)
            }
            
            Spacer()
            
            // More Options Button (Menu)
            Menu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button(action: onClone) {
                    Label("Clone", systemImage: "doc.on.doc")
                }
                if #available(iOS 15.0, *) {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    Button(action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundColor(.mdOnSurfaceVariant)
                    .frame(width: Dimens.touchTargetMin, height: Dimens.touchTargetMin)
                    .contentShape(Rectangle())
            }
        }
        .padding(Dimens.spacingSm)
        .background(Color.mdSurfaceContainerHigh)
        .cornerRadius(Dimens.cornerBase)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
        )
        .padding(.horizontal, Dimens.spacingSm)
        .padding(.top, Dimens.spacingSm)
    }
}
