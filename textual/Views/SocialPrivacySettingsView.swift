import SwiftUI

/// Owner-only privacy: activity sharing and what visitors see on the library card.
/// Changes save on this iPhone first and reach the server on the next attempt.
struct SocialPrivacySettingsView: View {
    @Environment(\.socialStore) private var social
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if let store = social?.settings, let settings = store.settings {
                        section("Reading activity", detail: "Friends see when you start or finish a book, save a quote, share a review, or add a book to your shelf. Turning this off hides what you’ve already shared; anything you do while it’s off stays private, even if you turn it back on.") {
                            toggle("Share my reading activity with friends", settings.activitySharing, id: "privacy.activity") {
                                SocialSettingsChange(activitySharing: $0)
                            }
                        }
                        section("Library card", detail: "Anyone signed in to Textual can open a visible statistic to see the books or genres behind it. Your shelf always shows the books you chose for it.") {
                            toggle("Books read", settings.booksReadVisible, id: "privacy.booksRead") { SocialSettingsChange(booksReadVisible: $0) }
                            toggle("Genres", settings.genresVisible, id: "privacy.genres") { SocialSettingsChange(genresVisible: $0) }
                            toggle("Rereads", settings.rereadsVisible, id: "privacy.rereads") { SocialSettingsChange(rereadsVisible: $0) }
                        }
                        if let message = store.message {
                            Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        }
                    } else {
                        Text("Your privacy settings couldn’t load. Check your connection and try again.")
                            .textStyle(.bodyMedium).foregroundStyle(Color.ghost)
                        Button("Try again") { Task { await social?.settings.refresh() } }
                            .buttonStyle(TextualButtonStyle(variant: .tonal))
                    }
                }
                .padding(TextualLayout.pageInset)
                .frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.paper)
            .background(Color.inkwell.ignoresSafeArea())
            .textualSheetHeader("Privacy & sharing") { dismiss() }
            .task { await social?.settings.refresh() }
        }
        .preferredColorScheme(.dark).tint(.paper)
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            TextualHeading(title: title)
            content()
            Text(detail).textStyle(.bodySmall).foregroundStyle(Color.ghost)
        }
    }

    private func toggle(_ title: String, _ value: Bool, id: String,
                        change: @escaping (Bool) -> SocialSettingsChange) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { newValue in
            Task { await social?.settings.update(change(newValue)) }
        }))
        .toggleStyle(TextualCheckboxToggleStyle())
        .font(.designSystem(.bodyMedium))
        .accessibilityIdentifier(id)
    }
}
