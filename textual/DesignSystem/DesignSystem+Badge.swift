//
//  DesignSystem+Badge.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import SwiftUI

/// Pill-style badge for categories and tags
struct Badge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .textStyle(.uiLabel)
            .foregroundColor(.paper)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.velvet)
            .cornerRadius(8)
    }
}
