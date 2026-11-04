import SwiftUI

/// Repeated page and control geometry. Feature-specific chart/card geometry stays local.
enum TextualLayout {
    static let pageInset: CGFloat = 24
    static let headerTop: CGFloat = 8
    static let headerBottom: CGFloat = 4
    static let contentTop: CGFloat = 12
    static let touchTarget: CGFloat = 44
    static let buttonHeight: CGFloat = 56
    static let controlPadding: CGFloat = 16
    static let coverRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let menuRadius: CGFloat = 20
    static let itemGap: CGFloat = 8
    static let groupGap: CGFloat = 16
}

enum TextualNavigationLayout {
    static let itemHeight: CGFloat = TextualLayout.touchTarget
    static let innerPadding: CGFloat = 6
    static let outerPadding: CGFloat = TextualLayout.pageInset
    static let bottomPadding: CGFloat = 24
    static var bottomExtent: CGFloat { itemHeight + innerPadding * 2 + bottomPadding }
}
