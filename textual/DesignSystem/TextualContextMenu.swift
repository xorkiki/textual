import SwiftUI

/// App-owned menu content keeps its solid surface while the system animates presentation.
private struct TextualContextMenu<MenuContent: View>: ViewModifier {
    var isEnabled: Bool
    @ViewBuilder var menu: () -> MenuContent
    @State private var isPresented = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(LongPressGesture().onEnded { _ in
                if isEnabled { isPresented = true }
            })
            .accessibilityAction(named: "Show options") {
                if isEnabled { isPresented = true }
            }
            .popover(isPresented: $isPresented) {
                TextualContextMenuContent(content: menu)
                    .presentationBackground(Color.dropdownSurface)
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: isEnabled) { _, enabled in if !enabled { isPresented = false } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { isPresented = false } }
            .onDisappear { isPresented = false }
    }
}

struct TextualContextMenuContent<MenuContent: View>: View {
    @ViewBuilder var content: () -> MenuContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 280, maxWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .font(.designSystem(.bodySmall))
        .foregroundStyle(Color.paper)
        .buttonStyle(TextualContextMenuActionStyle())
        .background(Color.dropdownSurface)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("textual.contextMenu.options")
    }
}

private struct TextualContextMenuActionStyle: PrimitiveButtonStyle {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            dismiss()
            configuration.trigger()
        } label: {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: TextualLayout.touchTarget, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(configuration.role == .destructive ? Color.errorText : Color.paper)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    func textualContextMenu<MenuContent: View>(isEnabled: Bool = true,
        @ViewBuilder content: @escaping () -> MenuContent) -> some View {
        modifier(TextualContextMenu(isEnabled: isEnabled, menu: content))
    }
}
