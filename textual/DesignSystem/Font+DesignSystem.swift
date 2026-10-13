import SwiftUI
import UIKit

/// Every font family and text role lives here, including intentional brand variants.
enum TextualFontFamily: String {
    case editorial = "CormorantGaramond-Regular"
    case editorialEmphasis = "CormorantGaramond-SemiBold"
    case laLuxesSerif = "LaLuxesSerifW05-Regular"
    case handwritten = "LamarPen-Regular"
    case body = "PlusJakartaSans-Regular"
    case medium = "PlusJakartaSans-Medium"
}

enum DesignSystemFont: CaseIterable {
    case displayHero, brandDisplay, heading1, heading2, heading3, sectionHeading
    case subheadingLarge, subheadingSmall
    case bodyLarge, bodyMedium, bodySmall, caption, uiButton, uiLabel
    case metric, metricLabel, chartAnnotation, fieldLabel, fieldInput
    case wordmark, welcomeTitle, welcomeTagline

    var family: TextualFontFamily {
        switch self {
        case .displayHero, .heading1, .heading2, .heading3, .sectionHeading,
             .metric, .wordmark, .welcomeTitle, .welcomeTagline: return .editorial
        case .brandDisplay: return .laLuxesSerif
        case .subheadingLarge, .subheadingSmall: return .handwritten
        case .uiButton: return .medium
        default: return .body
        }
    }

    var size: CGFloat {
        switch self {
        case .displayHero, .brandDisplay: return 64
        case .heading1: return 48
        case .heading2: return 36
        case .heading3: return 28
        case .sectionHeading: return 26
        case .subheadingLarge: return 24
        case .subheadingSmall: return 18
        case .bodyLarge: return 18
        case .bodyMedium, .uiButton: return 16
        case .bodySmall: return 14
        case .caption: return 13
        case .uiLabel: return 12
        case .metric: return 38
        case .metricLabel: return 11
        case .chartAnnotation: return 9
        case .fieldLabel: return 10
        case .fieldInput: return 21
        case .wordmark: return 18
        case .welcomeTitle: return 76
        case .welcomeTagline: return 38
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .displayHero, .brandDisplay, .heading1, .welcomeTitle, .metric: return .largeTitle
        case .heading2, .welcomeTagline: return .title
        case .heading3, .sectionHeading: return .title2
        case .subheadingLarge, .subheadingSmall, .wordmark: return .headline
        case .caption, .uiLabel, .metricLabel, .fieldLabel: return .caption
        case .chartAnnotation: return .caption2
        default: return .body
        }
    }

    var uiTextStyle: UIFont.TextStyle {
        switch relativeTo {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .headline: return .headline
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }

    var baseUIFont: UIFont {
        UIFont(name: family.rawValue, size: size) ?? UIFont.systemFont(ofSize: size)
    }

    var uiFont: UIFont {
        UIFontMetrics(forTextStyle: uiTextStyle).scaledFont(for: baseUIFont)
    }
}

extension Font {
    static func designSystem(_ style: DesignSystemFont) -> Font {
        .custom(style.family.rawValue, size: style.size, relativeTo: style.relativeTo)
    }

    static func isFontAvailable(_ fontName: String) -> Bool {
        UIFont(name: fontName, size: 17) != nil
    }
}

extension View {
    func textStyle(_ style: DesignSystemFont) -> some View {
        // Let the registered font supply its natural line height at every text size.
        font(.designSystem(style))
    }

    func navigationTitleFont() -> some View {
        toolbarColorScheme(.dark, for: .navigationBar)
    }

    func textualScreenDefaults() -> some View {
        font(.designSystem(.bodyMedium))
            .foregroundStyle(Color.paper)
            .tint(.paper)
            .preferredColorScheme(.dark)
    }
}

/// The library card keeps its printed proportions; it shares the global font families.
enum ReaderCardTypography {
    case brand, title, name, sentence, count, label, monogram

    private var specification: (TextualFontFamily, CGFloat) {
        switch self {
        case .brand: return (.editorial, 28)
        case .title: return (.editorialEmphasis, 29)
        case .name: return (.editorial, 31)
        case .sentence: return (.editorial, 15.5)
        case .count: return (.editorial, 23)
        case .label: return (.body, 7)
        case .monogram: return (.editorial, 64)
        }
    }

    func font(scale: CGFloat) -> Font {
        let (family, size) = specification
        return .custom(family.rawValue, fixedSize: size * scale)
    }
}
