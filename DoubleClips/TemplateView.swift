import SwiftUI

struct TemplateView: View {
    @State private var templates: [TemplateData] = []
    @State private var isLoading: Bool = false
    @State private var searchText: String = ""
    
    // Grid Setup
    let columns = [
        GridItem(.flexible(), spacing: Dimens.spacingSm),
        GridItem(.flexible(), spacing: Dimens.spacingSm)
    ]
    
    // Data Loader
    func loadTemplates() {
        isLoading = true
        
        guard let url = URL(string: "https://app.vanvatcorp.com/doubleclips/api/fetch-templates") else {
            print("Invalid URL")
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let error = error {
                    print("Error fetching templates: \(error.localizedDescription)")
                    return
                }
                
                guard let data = data else {
                    print("No data received")
                    return
                }
                
                do {
                    // Java: new Gson().fromJson(response.toString(), TemplateData[].class)
                    // Swift: JSONDecoder().decode([TemplateData].self, from: data)
                    let decodedTemplates = try JSONDecoder().decode([TemplateData].self, from: data)
                    self.templates = decodedTemplates
                } catch {
                    print("Error decoding templates: \(error)")
                }
            }
        }.resume()
    }
    
    var filteredTemplates: [TemplateData] {
        if searchText.isEmpty {
            return templates
        } else {
            return templates.filter { $0.templateTitle.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.mdBackground.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Header (150dp equivalent)
                    ZStack(alignment: .topLeading) {
                        // Background
                        Color.mdSecondaryContainer
                            .edgesIgnoringSafeArea(.top)
                            .frame(height: 150)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            // Title Panel
                            HStack {
                                Text("Material Template")
                                    .font(.mdHeadlineSmall)
                                    .foregroundColor(.mdSecondaryContainer)
                                    .padding(.leading, 25)
                                Spacer()
                            }
                            .frame(height: 50)
                            
                            // Search Panel
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.mdOnSurfaceVariant)
                                
                                TextField("Search for template", text: $searchText)
                                    .foregroundColor(.mdOnSurface)
                                    .textFieldStyle(PlainTextFieldStyle())
                            }
                            .padding(Dimens.spacingBase)
                            .background(Color.mdSurface)
                            .cornerRadius(Dimens.cornerFull)
                            .padding(.horizontal, Dimens.spacingSm)
                            .padding(.top, Dimens.spacingSm)
                        }
                        .padding(.top, 0)
                    }
                    .frame(height: 150)
                    .zIndex(1)
                    
                    // Content (RecyclerView equivalent)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Dimens.spacingSm) {
                            ForEach(Array(filteredTemplates.enumerated()), id: \.element.id) { index, template in
                                TemplateElementView(template: template)
                                    .onTapGesture {
                                        // Push to stack
                                        navigationPath.append(template)
                                    }
                            }
                        }
                        .padding(Dimens.spacingSm)
                    }
                    .background(Color.mdTertiaryContainer)
                    .refreshable {
                        loadTemplates()
                    }
                }
                
                // Loading Indicator
                if isLoading && templates.isEmpty {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
            .onAppear {
                loadTemplates()
            }
            .navigationDestination(for: TemplateData.self) { template in
                // Find index
                if let index = templates.firstIndex(where: { $0.id == template.id }) {
                    TemplatePreviewView(templates: templates, initialScrollIndex: index)
                }
            }
        }
    }
}

#Preview {
    TemplateView()
}
