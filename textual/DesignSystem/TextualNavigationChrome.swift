import SwiftUI
import UIKit

/// A shared dark fade that can sit behind controls or extend beyond them.
struct TextualChromeFade: View {
    var edge: VerticalEdge

    var body: some View {
        LinearGradient(stops: edge == .bottom ? [
            .init(color: .inkwell, location: 0),
            .init(color: .inkwell.opacity(0.844), location: 0.25),
            .init(color: .inkwell.opacity(0.5), location: 0.5),
            .init(color: .inkwell.opacity(0.156), location: 0.75),
            .init(color: .inkwell.opacity(0), location: 1)
        ] : [
            .init(color: .inkwell, location: 0),
            .init(color: .inkwell.opacity(0.96), location: 0.45),
            .init(color: .inkwell.opacity(0.72), location: 0.7),
            .init(color: .inkwell.opacity(0.3), location: 0.86),
            .init(color: .inkwell.opacity(0), location: 1)
        ], startPoint: edge == .top ? .top : .bottom,
           endPoint: edge == .top ? .bottom : .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TextualChromeBackground: ViewModifier {
    let edge: VerticalEdge
    let fadeLength: CGFloat
    let fadeInside: Bool

    func body(content: Content) -> some View {
        content.background {
            Group {
                if fadeInside {
                    // End the fade at the header's edge, behind its controls.
                    // The first card below it stays fully visible.
                    VStack(spacing: 0) {
                        if edge == .bottom { TextualChromeFade(edge: edge).frame(height: fadeLength) }
                        Color.inkwell
                        if edge == .top { TextualChromeFade(edge: edge).frame(height: fadeLength) }
                    }
                    .ignoresSafeArea(.container, edges: edge == .top ? .top : .bottom)
                } else {
                    Color.inkwell
                        .ignoresSafeArea(.container, edges: edge == .top ? .top : .bottom)
                        .overlay(alignment: edge == .top ? .bottom : .top) {
                            TextualChromeFade(edge: edge)
                                .frame(height: fadeLength)
                                .offset(y: edge == .top ? fadeLength : -fadeLength)
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func textualChromeBackground(edge: VerticalEdge, fadeLength: CGFloat = 48, fadeInside: Bool = false) -> some View {
        modifier(TextualChromeBackground(edge: edge, fadeLength: fadeLength, fadeInside: fadeInside))
    }

    /// Every screen uses the same inset, fade, text defaults, and hidden native toolbar.
    func textualPageHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        self
            .textualScreenDefaults()
            .background(Color.inkwell.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                header()
                    .padding(.top, TextualLayout.headerTop)
                    .padding(.bottom, TextualLayout.headerBottom)
                    .frame(maxWidth: .infinity)
                    .textualChromeBackground(edge: .top, fadeInside: true)
                    .zIndex(1)
            }
    }

    /// Native navigation bars in sheets and detail pages use the same dark palette.
    func textualNavigationChrome() -> some View {
        toolbarBackground(LinearGradient(colors: [.inkwell, .dropdownSurface],
            startPoint: .top, endPoint: .bottom), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// App-owned navigation controls stay outside native toolbars so iOS cannot
/// place a Liquid Glass container behind the design-system arrow.
struct TextualBackButton: View {
    var label: String = "Back"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DesignSystemIconView(.arrowLeft, size: TextualIconStyle.navigation.size, color: .paper)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Dismiss-only actions share an X icon and a spoken close label.
struct TextualCloseButton: View {
    var label: String = "Close"
    let action: () -> Void

    var body: some View {
        IconButton(icon: .close, action: action)
            .accessibilityLabel(label)
    }
}

/// Repeated page headings share one font, color, and accessibility treatment.
struct TextualHeading: View {
    let title: String
    var style: DesignSystemFont = .sectionHeading
    var body: some View {
        Text(title)
            .font(.designSystem(style))
            .foregroundStyle(Color.paper)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A single header row for tabs, pushed screens, and sheets.
/// Controls move below the title when the width or preferred text size needs it.
struct TextualHeader<Actions: View>: View {
    let title: String?
    var backLabel: String = "Back"
    var backIdentifier: String = "navigation.back"
    var titleIdentifier: String = "navigation.title"
    var backAction: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: TextualLayout.itemGap) {
                        titleRow.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: TextualLayout.itemGap)
                        actions().fixedSize(horizontal: true, vertical: false)
                    }
                    stacked
                }
            }
        }
        .buttonStyle(TextualHeaderActionStyle())
        .frame(maxWidth: .infinity, minHeight: TextualLayout.touchTarget, alignment: .leading)
        .padding(.horizontal, TextualLayout.pageInset)
    }

    private var titleRow: some View {
        HStack(spacing: TextualLayout.itemGap) {
            if let backAction {
                TextualBackButton(label: backLabel, action: backAction)
                    .accessibilityIdentifier(backIdentifier)
            }
            if let title {
                TextualHeading(title: title, style: .heading3)
                    .accessibilityIdentifier(titleIdentifier)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            titleRow
            if Actions.self != EmptyView.self {
                ScrollView(.horizontal) {
                    actions()
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension TextualHeader where Actions == EmptyView {
    init(title: String?, backLabel: String = "Back", backIdentifier: String = "navigation.back",
         titleIdentifier: String = "navigation.title", backAction: (() -> Void)? = nil) {
        self.title = title
        self.backLabel = backLabel
        self.backIdentifier = backIdentifier
        self.titleIdentifier = titleIdentifier
        self.backAction = backAction
        self.actions = { EmptyView() }
    }
}

extension View {
    func textualPageTitle(_ title: String) -> some View {
        textualPageHeader { TextualHeader(title: title.uppercased()) }
    }

    func textualBackHeader(title: String? = nil, backLabel: String = "Back",
                           action: @escaping () -> Void) -> some View {
        navigationBarBackButtonHidden(true)
            .textualPageHeader {
                TextualHeader(title: title, backLabel: backLabel, backAction: action)
            }
    }

    func textualSheetHeader(_ title: String, closeLabel: String = "Close", isEnabled: Bool = true,
                            onClose: @escaping () -> Void) -> some View {
        textualPageHeader {
            TextualHeader(title: title) {
                TextualCloseButton(label: closeLabel, action: onClose).disabled(!isEnabled)
            }
        }
        .presentationBackground(Color.inkwell)
    }
}

/// Fallback for system-owned navigation surfaces. App headers use TextualHeader.
enum TextualNavigationAppearance {
    static func configure() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.inkwell)
        let title: [NSAttributedString.Key: Any] = [
            .font: DesignSystemFont.heading3.uiFont,
            .foregroundColor: UIColor(Color.paper)
        ]
        appearance.titleTextAttributes = title
        appearance.largeTitleTextAttributes = title
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = UIColor(Color.paper)
    }
}
