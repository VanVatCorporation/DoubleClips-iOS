//
//  ExampleButto.swift
//  DoubleClips
//
//  Created by Nguyen Viet on 5/1/26.
//

import SwiftUI

struct ExampleButton: View {
    var title: String
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity) // controls width behavior
                .background(Color.blue)
                .cornerRadius(8)
        }
    }
}
