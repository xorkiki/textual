import SwiftUI

struct TextualEmptyState: View {
    let title: String
    let icon: DesignSystemIcon
    let detail: String

    var body: some View {
        VStack(spacing: TextualLayout.groupGap) {
            DesignSystemIconView(icon, size: TextualIconStyle.emptyState.size, color: .ghost)
                .accessibilityHidden(true)
            TextualHeading(title: title)
            Text(detail).font(.designSystem(.bodySmall)).foregroundStyle(Color.ghost)
        }
        .multilineTextAlignment(.center)
        .padding(TextualLayout.pageInset)
        .frame(maxWidth: .infinity)
    }
}
