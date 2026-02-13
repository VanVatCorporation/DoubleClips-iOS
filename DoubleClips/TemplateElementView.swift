import SwiftUI

struct TemplateElementView: View {
    let template: TemplateData
    let itemWidth: CGFloat // Passed from parent
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview Image Container
            ZStack(alignment: .bottomLeading) {
                // Async Loading for Preview
                AsyncImage(url: URL(string: template.templateSnapshotLink)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill() // Fill the width
                            .frame(width: itemWidth - (Dimens.spacingXs * 2)) // Adjust width for inner padding
                            .frame(maxHeight: (itemWidth - (Dimens.spacingXs * 2)) * 16 / 9) // Cap height
                            .clipped()
                    } else if phase.error != nil {
                        Color.mdSurfaceContainer
                   
                    } else {
                        Color.mdSurfaceContainer
                    }
                }
                .background(Color.mdSurfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: Dimens.cornerMd))
                .overlay(
                    RoundedRectangle(cornerRadius: Dimens.cornerMd)
                        .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
                )
                
                // Stats Overlay
                HStack(spacing: Dimens.spacingSm) {
                    StatItem(icon: "eye.fill", count: formatCount(template.viewCount))
                    StatItem(icon: "heart.fill", count: formatCount(template.heartCount))
                    StatItem(icon: "square.on.square.fill", count: formatCount(template.useCount))
                }
                .padding(.horizontal, Dimens.spacingSm)
                .padding(.vertical, Dimens.spacingXs)
                .background(Color.black.opacity(0.6))
                .cornerRadius(Dimens.cornerSm)
                .padding(Dimens.spacingSm)
            }
            .padding(Dimens.spacingXs) // Inner padding like Android margin=5dp
            
            // Template Info
            VStack(alignment: .leading, spacing: Dimens.spacingXs) {
                Text(template.templateTitle)
                    .font(.mdBodyLarge)
                    .fontWeight(.bold)
                    .foregroundColor(.mdOnSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: Dimens.spacingSm) {
                    // Avatar
                    AsyncImage(url: URL(string: "https://account.vanvatcorp.com/api/avatar/9da1e7af-25f8-5543-8a56-5c69f8143e0f")) { phase in
                         if let image = phase.image {
                             image.resizable().aspectRatio(contentMode: .fill)
                         } else {
                             Color.mdSecondaryContainer
                         }
                    }
                    .frame(width: 20, height: 20) // Match Android 20dp
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.mdOutline, lineWidth: 0.5))
                    
                    Text("@" + template.templateAuthor)
                        .font(.mdBodySmall)
                        .foregroundColor(.mdOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Dimens.spacingXs) // Match Android margin=5dp
            .padding(.bottom, Dimens.spacingXs)
        }
        .background(Color.mdSurfaceContainerHigh) // The Card Background
        .cornerRadius(Dimens.cornerBase)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
        )
        // Removed external padding to let Grid handle spacing
    }
    
    // Helper to format large numbers (e.g. 1.2k)
    func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// Helper view for stats
private struct StatItem: View {
    var icon: String
    var count: String
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .resizable()
                .frame(width: Dimens.iconSizeXs, height: Dimens.iconSizeXs)
                .foregroundColor(.white)
            
            Text(count)
                .font(.mdLabelSmall)
                .foregroundColor(.white)
        }
    }
}
