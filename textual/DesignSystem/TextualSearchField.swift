import SwiftUI

/// Shared field treatment for catalog search, archive search, and shelf selection.
struct TextualSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil
    var onClear: (() -> Void)? = nil
    var onSubmit: () -> Void = {}

    init(_ prompt: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil,
         onClear: (() -> Void)? = nil, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt
        self._text = text
        self.focus = focus
        self.onClear = onClear
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: TextualLayout.itemGap) {
            DesignSystemIconView(.search, size: TextualIconStyle.compact.size)
                .foregroundStyle(Color.ghost)
                .accessibilityHidden(true)
            Group {
                if let focus { field.focused(focus) } else { field }
            }
            if !text.isEmpty {
                Button {
                    if let onClear { onClear() } else { text = "" }
                } label: { DesignSystemIconView(.clear) }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, TextualLayout.controlPadding)
        .frame(minHeight: TextualLayout.touchTarget)
        .background(Color.dropdownSurface, in: Capsule())
    }

    private var field: some View {
        TextField(prompt, text: $text)
            .font(.designSystem(.bodyMedium))
            .foregroundStyle(Color.paper)
            .tint(.paper)
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit(onSubmit)
            .padding(.vertical, TextualLayout.contentTop)
    }
}
