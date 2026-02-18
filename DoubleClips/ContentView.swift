//
//  ContentView.swift
//  DoubleClips
//
//  Created by Nguyen Viet on 5/1/26.
//

import SwiftUI

enum Tab: Hashable, CaseIterable {
   case home, template, search, storage, profile
}

struct ContentView: View {
    @State private var selection: Tab = .home
    
    // Ordered list of tabs for swipe navigation
    private let tabOrder: [Tab] = [.home, .template, .search, .storage, .profile]
    
    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Tab.home)
            
            TemplateView()
                .tabItem {
                    Label("Template", systemImage: "tray")
                }
                .tag(Tab.template)
            
            Text("Search Screen")
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(Tab.search)
            
            Text("Inbox Screen")
                .tabItem {
                    Label("Storage", systemImage: "server.rack")
                }
                .tag(Tab.storage)
            
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .tag(Tab.profile)
        }
        // Swipe left/right to change tabs, just like Android ViewPager.
        // We use a simultaneous DragGesture so vertical scrolling inside
        // child views (ScrollView, List, etc.) is NOT blocked.
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    // Only trigger on clearly horizontal swipes
                    // (horizontal translation must be > 2x the vertical)
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical) * 2 else { return }
                    
                    guard let currentIndex = tabOrder.firstIndex(of: selection) else { return }
                    
                    if horizontal < -30, currentIndex < tabOrder.count - 1 {
                        // Swipe left → next tab
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = tabOrder[currentIndex + 1]
                        }
                    } else if horizontal > 30, currentIndex > 0 {
                        // Swipe right → previous tab
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = tabOrder[currentIndex - 1]
                        }
                    }
                }
        )
    }
}

#Preview {
    ContentView()
}
