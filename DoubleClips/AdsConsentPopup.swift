import SwiftUI

/// Ads consent popup - equivalent of AdsConsentPopup.java + popup_asking_for_ads.xml
/// Shows when `ads_popup` setting is enabled. Lets user choose to watch rewarded,
/// interstitial, or decline ads.
struct AdsConsentPopup: View {
    @Environment(\.dismiss) var dismiss
    
    // Callbacks for ad actions (wired to real AdMob SDK later)
    var onRewardedAds: () -> Void = {}
    var onInterstitialAds: () -> Void = {}
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Spacer(minLength: 24)
                
                // Title
                Text("Hey you, professional editor…")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 24)
                
                // Description
                Text("I know ads is frustrating, but in order to keep this app available, I…huhu,…have to add ads to survive in this world. Without money, I can't promote this app further to more people. I can't host my web because domain soon expire. Huhu. I need your help…")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                // Buttons
                VStack(spacing: 12) {
                    // Rewarded Ads button
                    Button(action: {
                        dismiss()
                        onRewardedAds()
                    }) {
                        Text("Show rewarded ads (More juicy money)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.mdPrimary)
                            .cornerRadius(12)
                    }
                    
                    // Interstitial Ads button
                    Button(action: {
                        dismiss()
                        onInterstitialAds()
                    }) {
                        Text("I don't have time, show interstitial, skippable ads")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.mdSecondary)
                            .cornerRadius(12)
                    }
                    
                    // Decline button
                    Button(action: {
                        dismiss()
                    }) {
                        Text("It's your problem. Go bankrupt I don't care")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)
                
                // Tip text
                Text("Tip! I don't like ads either, you can turn off this popup in Settings. I ain't mad at you 😚")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                Spacer(minLength: 32)
            }
        }
        .background(Color.mdBackground.edgesIgnoringSafeArea(.all))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    AdsConsentPopup()
}
