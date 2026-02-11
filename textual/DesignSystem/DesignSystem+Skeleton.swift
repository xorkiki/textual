//
//  DesignSystem+Skeleton.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import SwiftUI

/// Skeleton placeholder for loading states
struct Skeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.velvet.opacity(0.5))
    }
}

struct SkeletonModifier: ViewModifier {
    let isActive: Bool
    
    func body(content: Content) -> some View {
        if isActive {
            content
                .redacted(reason: .placeholder)
                .opacity(0.6)
        } else {
            content
        }
    }
}

extension View {
    func skeleton(when condition: Bool) -> some View {
        modifier(SkeletonModifier(isActive: condition))
    }
}
