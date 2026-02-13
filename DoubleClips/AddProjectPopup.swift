import SwiftUI

struct AddProjectPopup: View {
    var onNewProject: () -> Void
    var onImportProject: () -> Void
    
    var body: some View {
        VStack(spacing: Dimens.spacingLg) {
            Text("Create New Project") // Localize string here
                .font(.mdHeadlineSmall)
                .foregroundColor(.mdOnSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: Dimens.spacingSm) {
                // New Project Option
                Button(action: onNewProject) {
                    OptionCard(icon: "plus", text: "New Project", color: .mdPrimary)
                }
                
                // Import Project Option
                Button(action: onImportProject) {
                    OptionCard(icon: "square.and.arrow.down", text: "Import Project", color: .mdSecondary)
                }
            }
        }
        .padding(Dimens.spacingLg)
        .background(Color.mdSurface)
        .cornerRadius(Dimens.cornerLg)
    }
}

private struct OptionCard: View {
    var icon: String
    var text: String
    var color: Color
    
    var body: some View {
        VStack(spacing: Dimens.spacingBase) {
            Image(systemName: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Dimens.iconSizeXl, height: Dimens.iconSizeXl)
                .foregroundColor(color)
            
            Text(text)
                .font(.mdTitleMedium)
                .foregroundColor(.mdOnSurface)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(Color.clear) // Transparent background
        .overlay(
            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                .stroke(Color.mdOutline, lineWidth: 1)
        )
        .cornerRadius(Dimens.cornerBase)
    }
}
