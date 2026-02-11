//
//  DesignSystem+Rating.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import SwiftUI

/// 5-star rating display with optional count
struct RatingView: View {
    let rating: Double
    let count: Int?
    
    init(rating: Double, count: Int? = nil) {
        self.rating = min(5, max(0, rating))
        self.count = count
    }
    
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: starName(for: index))
                        .font(.system(size: 14))
                        .foregroundColor(.bloodletter)
                }
            }
            if let count, count > 0 {
                Text("(\(count))")
                    .textStyle(.uiLabel)
                    .foregroundColor(.ghost)
            }
        }
    }
    
    private func starName(for index: Int) -> String {
        let threshold = Double(index) + 0.5
        if rating >= Double(index + 1) {
            return "star.fill"
        }
        if rating >= threshold {
            return "star.leadinghalf.filled"
        }
        return "star"
    }
}
