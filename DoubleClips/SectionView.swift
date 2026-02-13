import SwiftUI

struct SectionView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: Dimens.spacingSm) {
            Text(title)
                .font(.mdTitleMedium) // Assuming similar style for section headers
                .foregroundColor(.mdOnSurfaceVariant) // Typically slightly muted
                .padding(.horizontal, Dimens.spacingBase)
                .padding(.top, Dimens.spacingSm)
            
            VStack(spacing: 0) {
                content
            }
            .background(Color.mdSurfaceContainerLow) // Or similar container color
            .cornerRadius(Dimens.cornerBase)
            .padding(.horizontal, Dimens.spacingBase)
        }
    }
}
