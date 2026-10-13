import SwiftUI

/// Asset names and the few unavailable utility symbols are defined only here.
/// Features select a semantic role rather than naming image files or SF Symbols.
enum DesignSystemIcon: String, CaseIterable {
    case arrowDown = "arrow-down", arrowDownLeft = "arrow-down-left", arrowDownRight = "arrow-down-right"
    case arrowLeft = "arrow-left", arrowRight = "arrow-right", arrowUp = "arrow-up"
    case arrowUpLeft = "arrow-up-left", arrowUpRight = "arrow-up-right"
    case chevronDown = "chevron-down", chevronLeft = "chevron-left"
    case chevronUp = "chevron-up", chevronRight = "chevron-right"
    case homeSimple = "home-simple", home, menu, search, profile, bookmark, chat, write, star, report
    case community, download, bookmarkBook = "bookmark-book", favoriteBook = "fav-book"
    case openBook = "open-book", people, happy, starFilled = "star-filled"
    // Line Rounded assets. Semantic action names keep feature call sites independent of filenames.
    case add = "plus", remove = "trash", preview = "eye", selected = "check-circle"
    case checkmark = "check-mark", clear = "close-circle", close, edit, heart, pieChart = "pie-chart", settings
    // These three variants are not present in either supplied folder.
    case conceal, unselected, warning, quote

    static var archive: Self { .bookmarkBook }
    static var discover: Self { .community }
    static var stats: Self { .pieChart }
    static var bookPlaceholder: Self { .openBook }
    static var filter: Self { .menu }

    var systemName: String? {
        switch self {
        case .quote: return "quote.opening"
        case .conceal: return "eye.slash"
        case .unselected: return "circle"
        case .warning: return "exclamationmark.circle"
        default: return nil
        }
    }

    var assetName: String? { systemName == nil ? rawValue : nil }
}

extension Image {
    init(designSystemIcon icon: DesignSystemIcon) {
        if let symbol = icon.systemName { self.init(systemName: symbol) }
        else { self.init(icon.rawValue) }
    }
}

struct DesignSystemIconView: View {
    let icon: DesignSystemIcon
    var size: CGFloat = TextualIconStyle.navigation.size
    var color: Color? = nil

    init(_ icon: DesignSystemIcon, size: CGFloat = TextualIconStyle.navigation.size, color: Color? = nil) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if let color { glyph.foregroundStyle(color) }
            else { glyph }
        }
        .frame(width: size, height: size)
    }

    private var glyph: some View {
        Image(designSystemIcon: icon)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
    }
}

extension Label where Title == Text, Icon == DesignSystemIconView {
    init(_ title: String, textualIcon: DesignSystemIcon) {
        self.init { Text(title) } icon: { DesignSystemIconView(textualIcon, size: TextualIconStyle.compact.size) }
    }
}

/// Icon sizing is independent of text sizes.
enum TextualIconStyle {
    case navigation, compact, disclosure, checkmark, selection, shelfAdd, emptyState, rating
    var size: CGFloat {
        switch self {
        case .navigation: return 24
        case .compact: return 18
        case .rating: return 14
        case .disclosure: return 10
        case .checkmark: return 12
        case .selection: return 22
        case .shelfAdd: return 23
        case .emptyState: return 44
        }
    }
    var weight: Font.Weight {
        switch self {
        case .disclosure, .checkmark: return .semibold
        case .shelfAdd: return .light
        default: return .regular
        }
    }
}

extension Font {
    static func textualIcon(_ style: TextualIconStyle, scale: CGFloat = 1) -> Font {
        .system(size: style.size * scale, weight: style.weight)
    }
}
