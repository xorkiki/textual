import SwiftUI

struct FriendRequestActions: View {
    let busy: Bool
    let identifierPrefix: String
    var username: String? = nil
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            action(.checkmark, "Accept friend request", suffix: "accept", perform: accept)
            action(.close, "Decline friend request", suffix: "decline", perform: decline)
        }
        .disabled(busy)
    }

    private func action(_ icon: DesignSystemIcon, _ label: String, suffix: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) { DesignSystemIconView(icon, size: TextualIconStyle.compact.size) }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(label)
            .accessibilityValue(busy ? "Updating" : "")
            .accessibilityIdentifier("\(identifierPrefix).\(suffix)" + (username.map { ".\($0)" } ?? ""))
    }
}
