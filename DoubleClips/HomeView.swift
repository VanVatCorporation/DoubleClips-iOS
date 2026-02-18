import SwiftUI

struct HomeView: View {
    @Binding var isBlockingGestures: Bool // Controls parent TabView swipe
    
    @State private var projects: [ProjectData] = []
    @State private var isLoading: Bool = false
    @State private var showAddProjectPopup: Bool = false
    @State private var editingProject: ProjectData? = nil
    
    // Real Project Loader — equivalent of MainAreaScreen.reloadingProject()
    func loadProjects() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Ensure the projects root directory exists
            IOHelper.createEmptyDirectories(Constants.DEFAULT_PROJECT_DIRECTORY)
            
            // List all subdirectories in the projects folder
            let dirs = IOHelper.listFiles(Constants.DEFAULT_PROJECT_DIRECTORY, options: .directories)
            
            var loaded: [ProjectData] = []
            for dir in dirs {
                if let data = ProjectData.loadProperties(from: dir.path) {
                    loaded.append(data)
                }
            }
            
            // Sort by timestamp descending (newest first) — matching Android default
            loaded.sort { $0.projectTimestamp > $1.projectTimestamp }
            
            DispatchQueue.main.async {
                projects = loaded
                isLoading = false
            }
        }
    }
    
    // Real Project Creator — equivalent of MainAreaScreen.addNewProjectWithName(title)
    func createProject(title: String) -> ProjectData? {
        // Find next available project_N directory
        let projectPath = IOHelper.getNextIndexPathInFolder(
            folderPath: Constants.DEFAULT_PROJECT_DIRECTORY,
            prefix: "project_",
            extension: "",
            createEmptyFile: false
        )
        
        // Create the project directory
        IOHelper.createEmptyDirectories(projectPath)
        guard IOHelper.isFileExist(projectPath) else { return nil }
        
        // Create required subdirectories (matching Java's basicDir + previewDir)
        IOHelper.createEmptyDirectories(IOHelper.combinePath(projectPath, Constants.DEFAULT_CLIP_TEMP_DIRECTORY, "frames"))
        IOHelper.createEmptyDirectories(IOHelper.combinePath(projectPath, Constants.DEFAULT_PREVIEW_CLIP_DIRECTORY))
        IOHelper.createEmptyDirectories(IOHelper.combinePath(projectPath, Constants.DEFAULT_CLIP_DIRECTORY))
        
        // Build and save project.properties
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var data = ProjectData(
            projectPath: projectPath,
            projectTitle: title,
            projectTimestamp: now,
            projectSize: 0,
            projectDuration: 0
        )
        data.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        data.savePropertiesAtProject()
        
        return data
    }
    
    var body: some View {
        NavigationStack {
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
                            onEdit: { editingProject = project },
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
                        .onTapGesture {
                            editingProject = project
                        }
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
        .navigationDestination(item: $editingProject) { project in
            EditingView(project: project)
                .onAppear { isBlockingGestures = true }
                .onDisappear { isBlockingGestures = false }
        }
        .sheet(isPresented: $showAddProjectPopup) {
            AddProjectPopup(
                onNewProject: { newProject in
                    // Create real project on disk, then use the returned data
                    if let realProject = createProject(title: newProject.projectTitle) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            projects.insert(realProject, at: 0)
                        }
                        // Open editor immediately, just like Android does
                        editingProject = realProject
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
        } // NavigationStack
    }


#Preview {
    HomeView(isBlockingGestures: .constant(false))
}
