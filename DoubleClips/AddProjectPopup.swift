import SwiftUI

struct AddProjectPopup: View {
    @Environment(\.dismiss) var dismiss
    
    // Called with the new project when user confirms
    var onNewProject: (ProjectData) -> Void
    var onImportProject: () -> Void
    
    @State private var projectTitle: String = ""
    @State private var showNewProjectForm: Bool = false
    @FocusState private var titleFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: Dimens.spacingLg) {
            
            if showNewProjectForm {
                // ── New Project Form ──────────────────────────────────────
                VStack(alignment: .leading, spacing: Dimens.spacingBase) {
                    Text("New Project")
                        .font(.mdHeadlineSmall)
                        .foregroundColor(.mdOnSurface)
                    
                    Text("Give your project a name to get started.")
                        .font(.mdBodyLarge)
                        .foregroundColor(.secondary)
                    
                    // Title Input
                    TextField("Project title...", text: $projectTitle)
                        .font(.mdBodyLarge)
                        .padding(12)
                        .background(Color.mdSurfaceContainerHigh)
                        .cornerRadius(Dimens.cornerBase)
                        .focused($titleFieldFocused)
                        .onAppear { titleFieldFocused = true }
                    
                    // Confirm Button
                    Button(action: createProject) {
                        Text("Create Project")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(projectTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? Color.mdPrimary.opacity(0.4)
                                        : Color.mdPrimary)
                            .cornerRadius(Dimens.cornerBase)
                    }
                    .disabled(projectTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    
                    // Back
                    Button(action: { withAnimation { showNewProjectForm = false } }) {
                        Text("Back")
                            .font(.mdBodyLarge)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                
            } else {
                // ── Option Picker ─────────────────────────────────────────
                Text("Create New Project")
                    .font(.mdHeadlineSmall)
                    .foregroundColor(.mdOnSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: Dimens.spacingSm) {
                    // New Project Option
                    Button(action: {
                        withAnimation { showNewProjectForm = true }
                    }) {
                        OptionCard(icon: "plus", text: "New Project", color: .mdPrimary)
                    }
                    
                    // Import Project Option
                    Button(action: onImportProject) {
                        OptionCard(icon: "square.and.arrow.down", text: "Import Project", color: .mdSecondary)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(Dimens.spacingLg)
        .background(Color.mdSurface)
        .cornerRadius(Dimens.cornerLg)
        .animation(.easeInOut(duration: 0.25), value: showNewProjectForm)
    }
    
    // MARK: - Create Project
    
    private func createProject() {
        let title = projectTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        
        // Generate a unique project path using timestamp
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let path = "/projects/\(timestamp)"
        
        let newProject = ProjectData(
            projectPath: path,
            projectTitle: title,
            projectTimestamp: timestamp,
            projectSize: 32767,        // New project starts empty
            projectDuration: 124
        )
        
        onNewProject(newProject)
        dismiss()
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
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: Dimens.cornerBase)
                .stroke(Color.mdOutline, lineWidth: 1)
        )
        .cornerRadius(Dimens.cornerBase)
    }
}
