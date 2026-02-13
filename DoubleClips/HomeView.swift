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
                // Title Frame (150dp equivalent)
                ZStack(alignment: .leading) {
                    // Background Image
                    // Using a color for now to represent @color/colorPalette1_2
                    Color.mdPrimary
                        .edgesIgnoringSafeArea(.top)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        // Title Panel
                        HStack {
                            Text("Welcome") // @string/welcome
                                .font(.mdHeadlineSmall)
                                .foregroundColor(.mdOnPrimary) // Assuming contrast color
                                .padding(.leading, 25)
                            Spacer()
                        }
                        .frame(height: 50)
                        
                        // Add Project Panel
                        Button(action: {
                            showAddProjectPopup = true
                        }) {
                            Text("Add Project") // @string/add_project
                                .font(.mdHeadlineSmall)
                                .foregroundColor(.mdOnPrimaryContainer)
                                .frame(maxWidth: .infinity)
                                .frame(height: 80) // Approx height filling the rest
                                .background(Color.mdPrimaryContainer) // @color/colorPalette1_1 equivalent mechanism
                                .cornerRadius(Dimens.cornerBase)
                                .padding(.horizontal, 25)
                                .padding(.vertical, 5)
                        }
                    }
                    .padding(.bottom, Dimens.spacingBase) // Adjust alignment
                }
                .frame(height: 150)
                
                // SwipeRefreshLayout & RecyclerView equivalent
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
                .background(Color.mdTertiaryContainer) // Background behind list (colorPalette1_4)
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
                onNewProject: {
                    print("New Project Clicked")
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
