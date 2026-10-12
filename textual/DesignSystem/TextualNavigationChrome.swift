import SwiftUI

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

    /// Keeps titles and filters readable while the page scrolls beneath them.
    func textualPageHeader<Header: View>(compact: Bool = false, @ViewBuilder _ header: () -> Header) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            header()
                .padding(.top, compact ? 8 : 12)
                .padding(.bottom, compact ? 4 : 8)
                .frame(maxWidth: .infinity)
                .textualChromeBackground(edge: .top, fadeInside: compact)
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
            DesignSystemIconView(.arrowLeft, size: 24, color: .paper)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
    }
}

extension View {
    func textualBackHeader(title: String? = nil, backLabel: String = "Back",
                           action: @escaping () -> Void) -> some View {
        self
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .textualPageHeader(compact: true) {
                HStack(spacing: 8) {
                    TextualBackButton(label: backLabel, action: action)
                    if let title {
                        Text(title)
                            .textStyle(.heading3)
                            .foregroundStyle(Color.paper)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        Spacer(minLength: 0)
                    }
                    // Balance the arrow's width to center the title on the page.
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
            }
    }
}
