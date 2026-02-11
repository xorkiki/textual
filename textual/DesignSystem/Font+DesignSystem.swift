//
//  Font+DesignSystem.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import UIKit

enum DesignSystemFont {
    case displayHero
    case heading1
    case heading2
    case heading3
    case subheadingLarge
    case subheadingSmall
    case bodyLarge
    case bodyMedium
    case bodySmall
    case uiButton
    case uiLabel
}

extension Font {
    static func designSystem(_ style: DesignSystemFont) -> Font {
        // Font files are registered in Info.plist at Resources/Fonts/
        // Font names should match the PostScript name or full name from the font file
        switch style {
        case .displayHero:
            return .custom("CormorantGaramond-Regular", size: 64)
        case .heading1:
            return .custom("CormorantGaramond-Regular", size: 48)
        case .heading2:
            return .custom("CormorantGaramond-Regular", size: 36)
        case .heading3:
            return .custom("CormorantGaramond-Regular", size: 28)
        case .subheadingLarge:
            return .custom("LamarPen-Regular", size: 24)
        case .subheadingSmall:
            return .custom("LamarPen-Regular", size: 18)
        case .bodyLarge:
            return .custom("PlusJakartaSans-Regular", size: 18)
        case .bodyMedium:
            return .custom("PlusJakartaSans-Regular", size: 16)
        case .bodySmall:
            return .custom("PlusJakartaSans-Regular", size: 14)
        case .uiButton:
            return .custom("PlusJakartaSans-Medium", size: 16)
        case .uiLabel:
            return .custom("PlusJakartaSans-Regular", size: 12)
        }
    }
    
    /// Helper to verify if a font is available
    static func isFontAvailable(_ fontName: String) -> Bool {
        return UIFont(name: fontName, size: 17) != nil
    }
}

extension DesignSystemFont {
    /// Returns the corresponding UIFont for use in attributed strings (e.g. HTML-rendered body text).
    var uiFont: UIFont {
        let (name, size) = fontNameAndSize
        return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
    }

    private var fontNameAndSize: (name: String, size: CGFloat) {
        switch self {
        case .displayHero: return ("CormorantGaramond-Regular", 64)
        case .heading1: return ("CormorantGaramond-Regular", 48)
        case .heading2: return ("CormorantGaramond-Regular", 36)
        case .heading3: return ("CormorantGaramond-Regular", 28)
        case .subheadingLarge: return ("LamarPen-Regular", 24)
        case .subheadingSmall: return ("LamarPen-Regular", 18)
        case .bodyLarge: return ("PlusJakartaSans-Regular", 18)
        case .bodyMedium: return ("PlusJakartaSans-Regular", 16)
        case .bodySmall: return ("PlusJakartaSans-Regular", 14)
        case .uiButton: return ("PlusJakartaSans-Medium", 16)
        case .uiLabel: return ("PlusJakartaSans-Regular", 12)
        }
    }
}

extension View {
    func textStyle(_ style: DesignSystemFont) -> some View {
        self.modifier(DesignSystemTextModifier(style: style))
    }
    
    /// Applies CormorantGaramond font to navigation titles using custom toolbar title
    func navigationTitleFont() -> some View {
        self.modifier(NavigationTitleFontModifier())
    }
}

struct DesignSystemTextModifier: ViewModifier {
    let style: DesignSystemFont
    
    var fontSize: CGFloat {
        switch style {
        case .displayHero: return 64
        case .heading1: return 48
        case .heading2: return 36
        case .heading3: return 28
        case .subheadingLarge: return 24
        case .subheadingSmall: return 18
        case .bodyLarge: return 18
        case .bodyMedium: return 16
        case .bodySmall: return 14
        case .uiButton: return 16
        case .uiLabel: return 12
        }
    }
    
    var lineHeight: CGFloat {
        switch style {
        case .displayHero: return 48
        case .heading1: return 36
        case .heading2: return 28
        case .heading3: return 24
        case .subheadingLarge: return 20
        case .subheadingSmall: return 16
        case .bodyLarge: return 16
        case .bodyMedium: return 14
        case .bodySmall: return 12
        case .uiButton: return 14
        case .uiLabel: return 10
        }
    }
    
    var fontName: String {
        switch style {
        case .displayHero, .heading1, .heading2, .heading3:
            return "CormorantGaramond-Regular"
        case .subheadingLarge, .subheadingSmall:
            return "LamarPen-Regular"
        case .bodyLarge, .bodyMedium, .bodySmall, .uiLabel:
            return "PlusJakartaSans-Regular"
        case .uiButton:
            return "PlusJakartaSans-Medium"
        }
    }
    
    func body(content: Content) -> some View {
        content
            .font(.custom(fontName, size: fontSize))
            .lineSpacing(lineHeight - fontSize)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct NavigationTitleFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
