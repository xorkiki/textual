import SwiftUI
import SwiftData

/// Shared confirmation and save path for archive covers and book details.
private struct ArchiveBookRemoval: ViewModifier {
    @Binding var book: Book?
    let repository: LibraryRepository?
    var onRemoved: () -> Void
    @Environment(\.modelContext) private var context
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Remove from archive?", isPresented: Binding(
                get: { book != nil }, set: { if !$0 { book = nil } }),
                presenting: book) { book in
                Button("Remove from archive", role: .destructive) { remove(book) }
                Button("Cancel", role: .cancel) { self.book = nil }
            } message: { book in
                Text("Remove “\(book.title)” from your personal archive?")
            }
            .alert("Couldn’t remove book", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func remove(_ book: Book) {
        do {
            guard book.modelContext === context, !book.isRemovedFromLibrary else {
                throw ReadingActionError.unavailable
            }
            if let repository {
                try repository.remove(book)
                Task { await repository.synchronize() }
            } else {
                context.delete(book)
                try context.save()
            }
            self.book = nil
            onRemoved()
        } catch {
            context.rollback()
            self.book = nil
            self.error = "Your book couldn’t be removed. Please try again."
        }
    }
}

extension View {
    func archiveBookRemoval(_ book: Binding<Book?>, repository: LibraryRepository?,
                            onRemoved: @escaping () -> Void = {}) -> some View {
        modifier(ArchiveBookRemoval(book: book, repository: repository, onRemoved: onRemoved))
    }
}
