//
//  ContentView.swift
//  DoubleClips
//
//  Created by Nguyen Viet on 5/1/26.
//

import SwiftUI

enum Tab: Hashable {
   case home, template, search, storage, profile
}

struct ContentView: View {
    @State private var selection: Tab = .home
    
    @State private var items = ["Apple", "Banana", "Cherry"]
    
    var body: some View {
        
        TabView(selection: $selection) {
//            VStack {
//                Button (role: .destructive) {
//                    print("Item deleted")
//                } label: {
//                    Label("Add project", systemImage: "square.and.arrow.down")
//                }
//                    .font(.headline)
//                    .foregroundColor(.white)
//                    .frame(maxWidth: .infinity, maxHeight: 75) // controls width behavior
//                    .background(Color.blue)
//                    .cornerRadius(8)
//                
//                    Button ("Hi from button", role: .destructive) {
//                        print("Item deleted")
//                    }
//                
//                LazyVStack {
//                    ForEach(items, id: \.self) { item in ComponentProjectElement(
//                        image: Image(systemName: "house"),
//                        title: "My Title",
//                        date: "05/01/2026",
//                        size: "1024MB",
//                        duration: "01:23:45",
//                        onMoreTapped: { print("More tapped") }
//                    )
//                        
//
//
//                            .padding() .frame(maxWidth: .infinity) .background(Color.blue.opacity(0.2)) .cornerRadius(8)
//                    }
//                }
//                Spacer();
//            }
//            .padding()
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
                .badge(3)
                .tag(Tab.search)
            Text("Inbox Screen")
                .tabItem {
                    Label("Storage", systemImage: "server.rack")
                }
                .badge(3)
                .tag(Tab.storage)
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .badge(3)
                .tag(Tab.profile)
        }
        

    }
}

#Preview {
    ContentView()
}
