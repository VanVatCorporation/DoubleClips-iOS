import SwiftUI

struct TemplateElementView: View {
    let template: TemplateData
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview Image Container
            ZStack(alignment: .bottomLeading) {
                // Async Loading for Preview
                AsyncImage(url: URL(string: template.templateSnapshotLink)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        Color.mdSurfaceContainer // Error placeholder
                    } else {
                        Color.mdSurfaceContainer // Loading placeholder
                    }
                }
                .frame(height: 180)
                .background(Color.mdSurfaceContainer)
                .clipped()
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
            .padding(Dimens.spacingSm)
            
            // Template Info
            VStack(alignment: .leading, spacing: Dimens.spacingXs) {
                Text(template.templateTitle)
                    .font(.mdBodyLarge)
                    .fontWeight(.bold)
                    .foregroundColor(.mdOnSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: Dimens.spacingSm) {
                    // Async Loading for Avatar
                    // Mocking avatar URL structure from Java code: https://account.vanvatcorp.com/api/avatar/...
                    // In a real scenario, this URL construction might need to be dynamic or part of the model.
                    // For now, using a placeholder or the logic from Java if possible, but Java used a hardcoded UUID in one place?
                    // "https://account.vanvatcorp.com/api/avatar/9da1e7af-25f8-5543-8a56-5c69f8143e0f" was hardcoded in Java example?
                    // Actually Java code uses: ImageHelper.getImageBitmapFromNetwork(context, "https://account.vanvatcorp.com/api/avatar/9da1e7af-25f8-5543-8a56-5c69f8143e0f")
                    // But that seems to be a specific fallback or test?
                    // Let's assume for now we use a generic avatar or try to construct one.
                     
                    AsyncImage(url: URL(string: "https://account.vanvatcorp.com/api/avatar/9da1e7af-25f8-5543-8a56-5c69f8143e0f")) { phase in
                         if let image = phase.image {
                             image.resizable().aspectRatio(contentMode: .fill)
                         } else {
                             Color.mdSecondaryContainer
                         }
                    }
                    .frame(width: Dimens.avatarSizeXs, height: Dimens.avatarSizeXs)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.mdOutline, lineWidth: 0.5))
                    
                    Text("@" + template.templateAuthor)
                        .font(.mdBodySmall)
                        .foregroundColor(.mdOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Dimens.spacingBase)
            .padding(.bottom, Dimens.spacingBase)
            .padding(.top, Dimens.spacingSm)
        }
        .background(Color.mdSurfaceContainerHigh)
        .cornerRadius(Dimens.cornerBase)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
        )
        .padding(.horizontal, Dimens.spacingXs)
        .padding(.top, Dimens.spacingXs)
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
