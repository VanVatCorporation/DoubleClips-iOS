//
//  ExampleButto.swift
//  DoubleClips
//
//  Created by Nguyen Viet on 5/1/26.
//

import SwiftUI

struct ComponentProjectElement: View {
    var image: Image
    var title: String
    var date: String
    var size: String
    var duration: String
    var onMoreTapped: () -> Void
    
    var body: some View {
        ZStack {
            // Background container
            RoundedRectangle(cornerRadius: 12)
                .fill(Color("colorPalette1_4"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color("colorGlassBackground"), lineWidth: 1)
                )
            
            HStack(alignment: .top, spacing: 8) {
                // Preview image
                image
                    .resizable()
                    //.scaledToFill()
                    .frame(width: 25, height: 25) //75
                    .background(Color("colorGlassBackground"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color("colorPrimaryBackground"), lineWidth: 2)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title + More button row
                    HStack {
                        Text(title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color("colorPrimaryButton"))
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Button(action: onMoreTapped) {
                            Image(systemName: "ellipsis")
                                .foregroundColor(.primary)
                        }
                    }
                    
                    // Date
                    Text(date)
                        .foregroundColor(Color("colorPrimaryButton"))
                    
                    // Size
                    Text(size)
                        .foregroundColor(Color("colorPrimaryButton"))
                }
                
                Spacer()
            }
            .padding(8)
            
            // Duration below preview image
            VStack {
                Spacer()
                HStack {
                    Text(duration)
                        .foregroundColor(Color("colorPrimaryButton"))
                        .frame(width: 75)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.leading, 8)
            }
        }
        .frame(height: 110)
        .padding(.horizontal, 25)
        .padding(.top, 10)
    }
}

