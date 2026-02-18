import SwiftUI

struct TemplateView: View {
    @State private var templates: [TemplateData] = []
    @State private var isLoading: Bool = false
    @State private var searchText: String = ""
    
    @State private var navigationPath = NavigationPath()
    
    // Masonry Grid Helpers
    var filteredTemplates: [TemplateData] {
        if searchText.isEmpty {
            return templates
        } else {
            return templates.filter { $0.templateTitle.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var leftColumnTemplates: [TemplateData] {
        filteredTemplates.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
    }
    
    var rightColumnTemplates: [TemplateData] {
        filteredTemplates.enumerated().filter { $0.offset % 2 != 0 }.map { $0.element }
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.mdBackground.edgesIgnoringSafeArea(.all)
                
                VStack(alignment: .leading, spacing: 0) {
                    
                    // ── Header Title ─────────────────────────────────────────
                    // Matches: android:textSize="32sp" android:textStyle="bold"
                    // android:layout_marginStart="24dp" android:layout_marginTop="24dp"
                    Text("Template")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                    
                    // ── Search Bar ────────────────────────────────────────────
                    // Matches: MaterialCardView with cardCornerRadius="24dp",
                    // cardBackgroundColor="colorSurfaceContainerHigh", SearchView inside
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                        
                        TextField("Search templates...", text: $searchText)
                            .foregroundColor(.primary)
                            .textFieldStyle(PlainTextFieldStyle())
                        
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.mdSurfaceContainerHigh)
                    .clipShape(Capsule()) // cardCornerRadius="24dp" → Capsule
                    .overlay(
                        Capsule()
                            .stroke(Color.mdOutlineVariant, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // ── Template List ─────────────────────────────────────────
                    // Matches: SwipeRefreshLayout + StaggeredGridLayoutManager(2 cols)
                    GeometryReader { geometry in
                        let spacing: CGFloat = 4 // ~3dp like Android
                        let itemWidth = (geometry.size.width - (spacing * 3)) / 2
                        
                        ScrollView {
                            HStack(alignment: .top, spacing: spacing) {
                                // Left Column
                                LazyVStack(spacing: spacing) {
                                    ForEach(leftColumnTemplates) { template in
                                        TemplateElementView(template: template, itemWidth: itemWidth)
                                            .onTapGesture {
                                                navigationPath.append(template)
                                            }
                                    }
                                }
                                
                                // Right Column
                                LazyVStack(spacing: spacing) {
                                    ForEach(rightColumnTemplates) { template in
                                        TemplateElementView(template: template, itemWidth: itemWidth)
                                            .onTapGesture {
                                                navigationPath.append(template)
                                            }
                                    }
                                }
                            }
                            .padding(.horizontal, spacing)
                            .padding(.bottom, 80) // Match Android paddingBottom="80dp" for nav bar
                        }
                        .refreshable {
                            loadTemplates()
                        }
                    }
                }
                
                // ── Center Progress Bar ───────────────────────────────────────
                // Matches: ProgressBar android:layout_centerInParent="true"
                if isLoading && templates.isEmpty {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
            .onAppear {
                loadTemplates()
            }
            .navigationDestination(for: TemplateData.self) { template in
                if let index = templates.firstIndex(where: { $0.id == template.id }) {
                    TemplatePreviewView(templates: templates, initialScrollIndex: index)
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    func loadTemplates() {
        isLoading = true
        
        guard let url = URL(string: "https://app.vanvatcorp.com/doubleclips/api/fetch-templates") else {
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data, error == nil else { return }
                if let decoded = try? JSONDecoder().decode([TemplateData].self, from: data) {
                    self.templates = decoded
                }
            }
        }.resume()
    }
}

#Preview {
    TemplateView()
}
