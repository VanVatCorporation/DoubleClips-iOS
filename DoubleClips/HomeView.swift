import SwiftUI

struct HomeView: View {
    @State private var projects: [ProjectData] = []
    @State private var isLoading: Bool = false
    @State private var showAddProjectPopup: Bool = false
    
    // Mock Data Loader
    func loadProjects() {
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Mock Data
            projects = [
                ProjectData(projectPath: "/path/1", projectTitle: "Vacation Edit", projectTimestamp: 1672531200000, projectSize: 157286400, projectDuration: 125000),
                ProjectData(projectPath: "/path/2", projectTitle: "Gaming Clip", projectTimestamp: 1675123200000, projectSize: 52428800, projectDuration: 45000),
                ProjectData(projectPath: "/path/3", projectTitle: "Vlog #42", projectTimestamp: 1677628800000, projectSize: 314572800, projectDuration: 450000)
            ]
            isLoading = false
        }
    }
    
    var body: some View {
        ZStack {
            Color.mdBackground.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Creative Header / Action Area (Fixed at top)
                Button(action: {
                    showAddProjectPopup = true
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 48))
                            .foregroundColor(.white)
                        
                        Text("Start Creating")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.top, 8)
                        
                        Text("Tap to create a new project")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(Color.iosBlue) // Using the new color
                    .cornerRadius(24)
                    .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                    .padding(16) // Margin: 16dp
                }
                
                // Section Title
                HStack {
                    Text("Recent Projects")
                        .font(.system(size: 20, weight: .bold)) // 20sp bold
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    Spacer()
                }
                
                // Project List (Scrollable)
                List {
                    ForEach(projects) { project in
                        ProjectElementView(
                            project: project,
                            image: Image(systemName: "photo"), // Placeholder
                            onEdit: { print("Edit \(project.projectTitle)") },
                            onDelete: {
                                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                                    projects.remove(at: index)
                                }
                            },
                            onShare: { print("Share \(project.projectTitle)") },
                            onClone: { print("Clone \(project.projectTitle)") }
                        )
                        .listRowInsets(EdgeInsets()) // Remove default padding
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.horizontal, 5) // match android layout margin
                        .padding(.top, 5)
                    }
                }
                .listStyle(PlainListStyle())
                .refreshable {
                    loadProjects()
                }
                .background(Color.mdBackground) // Background behind list (Adaptive)
            }
            
            // Progress Bar
            if isLoading && projects.isEmpty { // Only show full screen loader if empty
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .onAppear {
            loadProjects()
        }
        .sheet(isPresented: $showAddProjectPopup) {
            AddProjectPopup(
                onNewProject: { newProject in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        projects.insert(newProject, at: 0) // Add to top like Android
                    }
                    showAddProjectPopup = false
                },
                onImportProject: {
                    print("Import Project Clicked")
                    showAddProjectPopup = false
                }
            )
        }
    }
}


#Preview {
    HomeView()
}
