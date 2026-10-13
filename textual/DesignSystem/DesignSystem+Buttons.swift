import SwiftUI

enum TextualButtonVariant { case primary, secondary, tonal }

struct TextualButtonStyle: ButtonStyle {
    var variant: TextualButtonVariant = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.designSystem(.uiButton))
            .multilineTextAlignment(.center)
            .foregroundStyle(variant == .primary ? Color.inkwell : Color.paper)
            .padding(.horizontal, TextualLayout.pageInset)
            .padding(.vertical, TextualLayout.controlPadding)
            .frame(maxWidth: .infinity, minHeight: TextualLayout.buttonHeight)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }

    private var fill: Color {
        switch variant {
        case .primary: return .paper
        case .secondary: return .controlSurface
        case .tonal: return .bloodletterFaded
        }
    }
}

struct FilledButton: View {
    let title: String
    let action: () -> Void
    var body: some View { Button(title, action: action).buttonStyle(TextualButtonStyle()) }
}

struct TonalButton: View {
    let title: String
    let action: () -> Void
    var body: some View { Button(title, action: action).buttonStyle(TextualButtonStyle(variant: .tonal)) }
}

struct IconButton: View {
    let icon: DesignSystemIcon
    let action: () -> Void
    var body: some View {
        Button(action: action) { DesignSystemIconView(icon) }.buttonStyle(IconButtonStyle())
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.textualIcon(.navigation))
            .foregroundStyle(Color.paper)
            .frame(width: TextualLayout.touchTarget, height: TextualLayout.touchTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

struct TextualHeaderActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.designSystem(.uiButton))
            .foregroundStyle(Color.paper)
            .frame(minWidth: TextualLayout.touchTarget, minHeight: TextualLayout.touchTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

extension View {
    func filledButtonStyle() -> some View { buttonStyle(TextualButtonStyle()) }
    func tonalButtonStyle() -> some View { buttonStyle(TextualButtonStyle(variant: .tonal)) }
    func iconButtonStyle() -> some View { buttonStyle(IconButtonStyle()) }
}


/// A flat selection control that shares Textual's colors and icon set.
struct TextualCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Color.bloodletterFaded : Color.velvet)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color.ghost.opacity(0.5), lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn { DesignSystemIconView(.checkmark, size: 14, color: .paper) }
                    }
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.paper)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
