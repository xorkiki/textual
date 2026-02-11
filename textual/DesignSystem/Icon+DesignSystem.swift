//
//  Icon+DesignSystem.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI

enum DesignSystemIcon: String, CaseIterable {
    // Arrows
    case arrowDown = "arrow-down"
    case arrowDownLeft = "arrow-down-left"
    case arrowDownRight = "arrow-down-right"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case arrowUp = "arrow-up"
    case arrowUpLeft = "arrow-up-left"
    case arrowUpRight = "arrow-up-right"
    
    // Navigation
    case homeSimple = "home-simple"
    case menu = "menu"
    case search = "search"
    case profile = "profile"
    
    // Actions
    case bookmark = "bookmark"
    case chat = "chat"
    case write = "write"
    case star = "star"
    case report = "report"
    
    // Social
    case community = "community"
    
    var filename: String {
        return "\(rawValue).svg"
    }
    
    var resourcePath: String {
        return "Resources/Icons/\(filename)"
    }
    
    /// Asset name for use in Assets.xcassets
    /// SVG files should be added to Assets.xcassets with this name
    var assetName: String {
        return rawValue
    }
}

extension Image {
    init(designSystemIcon: DesignSystemIcon) {
        // Icons are loaded from Assets.xcassets as vector images (iOS 13+)
        // The asset name matches the icon's rawValue (e.g., "arrow-down", "bookmark")
        self.init(designSystemIcon.rawValue)
    }
}

// MARK: - Icon View Helper
struct DesignSystemIconView: View {
    let icon: DesignSystemIcon
    let size: CGFloat
    let color: Color
    
    init(_ icon: DesignSystemIcon, size: CGFloat = 24, color: Color = .paper) {
        self.icon = icon
        self.size = size
        self.color = color
    }
    
    var body: some View {
        // Icons are loaded from Assets.xcassets as vector images
        Image(designSystemIcon: icon)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(color)
            .frame(width: size, height: size)
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Convenience View Extension
extension View {
    func icon(_ icon: DesignSystemIcon, size: CGFloat = 24, color: Color = .paper) -> some View {
        DesignSystemIconView(icon, size: size, color: color)
    }
}
