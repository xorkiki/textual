//
//  Color+Theme.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI

extension Color {
    // MARK: - Neutrals
    static let inkwell = Color(hex: "0D0D0D")
    static let paper = Color(hex: "F2F2F2")
    static let ghost = Color(hex: "8C8C8C")
    static let velvet = Color(hex: "232323")
    
    // MARK: - Primary
    static let bloodletter = Color(hex: "4C1308")
    static let bloodletterFaded = Color(hex: "4C1308").opacity(0.3)
    
    // MARK: - Accents
    static let moss = Color(hex: "4B5A41")
    static let inkstorm = Color(hex: "1A2636")
    static let duskpetal = Color(hex: "452C42")
    static let clayhearth = Color(hex: "B4683C")
    
    // MARK: - Hex Initializer
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
