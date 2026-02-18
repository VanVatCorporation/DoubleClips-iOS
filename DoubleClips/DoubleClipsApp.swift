//
//  DoubleClipsApp.swift
//  DoubleClips
//
//  Created by Nguyen Viet on 5/1/26.
//

import SwiftUI

@main
struct DoubleClipsApp: App {
    @AppStorage("theme_mode") private var themeMode: String = "system"
    @AppStorage("ads_popup") private var adsPopup: Bool = true
    @AppStorage("early_access_issues_notification") private var earlyAccessNotification: Bool = true
    
    @State private var showAdsPopup: Bool = false
    @State private var showEarlyAccessPopup: Bool = false
    
    var colorScheme: ColorScheme? {
        switch themeMode {
        case "dark":
            return .dark
        case "light":
            return .light
        default:
            return nil // System default
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
                .onAppear {
                    // Delay slightly so the UI is ready, matching Android's onCreate behavior
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if earlyAccessNotification {
                            showEarlyAccessPopup = true
                        } else if adsPopup {
                            showAdsPopup = true
                        }
                    }
                }
                .sheet(isPresented: $showEarlyAccessPopup, onDismiss: {
                    // After early access popup is dismissed, show ads popup if enabled
                    if adsPopup {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showAdsPopup = true
                        }
                    }
                }) {
                    EarlyAccessPopup()
                }
                .sheet(isPresented: $showAdsPopup) {
                    AdsConsentPopup()
                }
        }
    }
}

