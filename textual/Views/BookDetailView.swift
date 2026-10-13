//
//  BookDetailView.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import SwiftUI
import SwiftData
import Foundation

struct BookDetailView: View {
    let book: Book
    var isPresentedAsSheet = false
    var showsReadingActivity = false
    @StateObject private var viewModel = BookDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.reviewLibraryRepository) private var repository
    @State private var route: BookActionRoute?
    @State private var statusError: String?

    private var reading: StoryGraphReadingData { UpNextQueue.metadata(for: book) }
    
    var body: some View {
        ZStack {
            Color.inkwell
                .ignoresSafeArea()
            
            contentView(volume: viewModel.volume ?? viewModel.savedVolume(book: book))
        }
        .id(book.id)
        .textualDropdownHost()
        .presentationBackground(Color.inkwell)
        .navigationBarBackButtonHidden(true)
        .textualPageHeader {
            if isPresentedAsSheet {
                TextualHeader(title: nil) { TextualCloseButton { dismiss() } }
            } else {
                TextualHeader(title: nil, backAction: { dismiss() })
            }
        }
        .sheet(item: $route) { BookActionSheet(route: $0, repository: repository) }
        .alert("Couldn't save reading", isPresented: Binding(get: { statusError != nil }, set: { if !$0 { statusError = nil } })) {
            Button("OK") { statusError = nil }
        } message: { Text(statusError ?? "") }
        .task(id: book.id) {
            await viewModel.fetchVolume(book: book)
        }
    }

    private func setReadingStatus(_ status: String) {
        do {
            try BookReadingActions.setStatus(status, book: book, context: context, repository: repository)
            Task { await repository?.synchronize() }
        } catch { statusError = error.localizedDescription }
    }
    
    private func contentView(volume: BookCatalogService.BookItem) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Cover + Title block
                HStack(alignment: .top, spacing: 20) {
                    coverImage(urlString: viewModel.coverURL(from: volume))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.title(from: volume))
                            .textStyle(.heading3)
                            .foregroundColor(.paper)
                        
                        if let subtitle = viewModel.subtitle(from: volume) {
                            Text(subtitle)
                                .textStyle(.bodyMedium)
                                .foregroundColor(.ghost)
                        }
                        
                        Text(viewModel.authors(from: volume))
                            .textStyle(.bodySmall)
                            .foregroundColor(.ghost)

                        if !book.isRemovedFromLibrary {
                            TextualDropdown(label: "Reading status", title: reading.statusLabel,
                                options: [
                                    .init(value: "currently-reading", title: "Currently reading"),
                                    .init(value: "read", title: "Finish + rate"),
                                    .init(value: "to-read", title: "To read"),
                                    .init(value: "did-not-finish", title: "Did not finish")
                                ], selection: Binding(get: { reading.status }, set: { status in
                                    if status == "read" { route = .init(book: book, action: .finish) }
                                    else { setReadingStatus(status) }
                                }))
                            .padding(.top, 4)
                        }

                        if let rating = viewModel.averageRating(from: volume) {
                            RatingView(
                                rating: rating,
                                count: viewModel.ratingsCount(from: volume)
                            )
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.paper)
                        Text("Loading additional details…")
                            .textStyle(.bodySmall)
                            .foregroundColor(.ghost)
                    }
                } else if let message = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message)
                            .textStyle(.bodySmall)
                            .foregroundColor(.ghost)
                        TonalButton(title: "Retry", action: {
                            Task { await viewModel.fetchVolume(book: book, forceRefresh: true) }
                        })
                        .frame(width: 120)
                    }
                }
                
                if showsReadingActivity { BookReadingSection(book: book) }
                BookReviewSection(book: book)

                // Categories
                let categories = viewModel.categories(from: volume)
                if !categories.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(categories, id: \.self) { category in
                            Badge(text: category)
                        }
                    }
                }
                
                // Description
                if let desc = viewModel.description(from: volume) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .textStyle(.subheadingSmall)
                            .foregroundColor(.paper)
                        
                        Text(AttributedString(html: desc, color: .paper, font: .bodyMedium))
                            .textStyle(.bodyMedium)
                            .foregroundColor(.paper)
                            .lineSpacing(6)
                    }
                }
            }
            .padding()
        }
    }
    
    private func coverImage(urlString: String) -> some View {
        SavedBookCover(book: book, width: 140, height: 210, fetchedURL: urlString)
            .shadow(color: .inkwell.opacity(0.3), radius: 8, x: 0, y: 4)
    }

}

// MARK: - Flow Layout for Badges
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                     y: bounds.minY + result.positions[index].y),
                        proposal: .unspecified)
        }
    }
    
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

#Preview {
    NavigationStack {
        BookDetailView(book: Book(
            title: "Sample Book",
            author: "Author Name",
            isbn: "zyTCAlFPjgYC",
            coverURL: "",
            googleBooksVolumeId: "zyTCAlFPjgYC"
        ))
    }
    .modelContainer(for: Book.self, inMemory: true)
}

// MARK: - Shared review entry points
extension EnvironmentValues {
    @Entry var readerReviews: ReaderReviewStore? = nil
    @Entry var reviewLibraryRepository: LibraryRepository? = nil
}

/// Can be embedded on any book surface. Only an explicit tap adds a catalog book.
struct BookReviewSection: View {
    let book: Book
    @Environment(\.readerReviews) private var store
    @Environment(\.reviewLibraryRepository) private var repository
    @Query private var books: [Book]
    @Query private var reviews: [ReaderReviewDraft]
    @State private var editingBook: Book?
    @State private var message: String?

    init(book: Book) {
        self.book = book
        let id = book.id
        let providerID = book.googleBooksVolumeId
        _books = Query(filter: #Predicate<Book> {
            $0.id == id || (providerID != nil && $0.googleBooksVolumeId == providerID)
        })
    }
    private var localBook: Book? { books.first { !$0.isRemovedFromLibrary } ?? books.first }
    private var draft: ReaderReviewDraft? {
        reviews.first { $0.localBookID == (localBook?.id ?? book.id) && $0.userID == store?.userID }
    }

    private var review: ReaderReviewPresentation { .init(book: localBook ?? book, draft: draft) }

    var body: some View {
        if let store {
            VStack(alignment: .leading, spacing: TextualLayout.groupGap) {
                Text("Your review").textStyle(.sectionHeading)
                if let content = review.content {
                    ReaderReviewContentView(content: content)
                } else {
                    Text(review.hasDraftChanges
                         ? "You have an unfinished review. Pick up where you left off."
                         : "What stayed with you? Leave a rating, a review, or both.")
                        .textStyle(.bodyMedium).foregroundStyle(Color.ghost)
                }
                if review.isVisible {
                    Text(review.statusLabel).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                }
                Button(actionTitle) { openEditor() }
                    .buttonStyle(TextualButtonStyle(variant: .tonal))
                    .accessibilityIdentifier("book.review")
                if let message {
                    Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    Button("Retry") { Task { await load() } }.buttonStyle(TextualHeaderActionStyle())
                }
            }
            .foregroundStyle(Color.paper)
            .padding(.vertical, TextualLayout.groupGap)
            .overlay(alignment: .top) { Divider().overlay(Color.ghost.opacity(0.3)) }
            .overlay(alignment: .bottom) { Divider().overlay(Color.ghost.opacity(0.3)) }
            .sheet(item: $editingBook) { book in
                ReaderReviewEditor(book: book, store: store, repository: repository)
            }
            .task(id: localBook?.canonicalBookID) { await load() }
        }
    }
    private var actionTitle: String {
        if localBook == nil || localBook?.isRemovedFromLibrary == true { return "Add to archive & review" }
        if review.hasDraftChanges { return "Continue review" }
        return review.content == nil ? "Write a review" : "Edit review"
    }
    private func openEditor() {
        do {
            guard let repository else { return }
            editingBook = try repository.add(localBook ?? book)
            message = nil
        } catch { message = "This book couldn’t be opened for review. Please try again." }
    }
    private func load() async {
        guard let store, let localBook else { return }
        await repository?.synchronize()
        guard localBook.canonicalBookID != nil else { return }
        do { try await store.loadRemote(for: localBook); message = nil }
        catch ReaderReviewError.submissionPending { message = nil }
        catch ReaderReviewError.conflict { message = "Your review has changes to resolve. Open it to continue." }
        catch { message = "Couldn’t refresh your review. Your saved version is still available." }
    }
}

struct ReaderReviewContentView: View {
    let content: ReaderReviewContent
    @State private var revealSpoilers = false

    var body: some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            if let rating = content.rating {
                HStack {
                    RatingView(rating: Double(rating) / 4)
                    Text("\((Double(rating) / 4).formatted()) / 5").textStyle(.bodySmall)
                }
            }
            if !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if content.spoilers && !revealSpoilers {
                    Button("Contains spoilers · Show review") { revealSpoilers = true }
                        .buttonStyle(TextualHeaderActionStyle())
                } else {
                    Text(content.body).textStyle(.bodyMedium).textSelection(.enabled)
                    if content.spoilers {
                        Button("Hide spoilers") { revealSpoilers = false }.buttonStyle(TextualHeaderActionStyle())
                    }
                }
            }
        }
        .foregroundStyle(Color.paper)
    }
}

/// The same editor is used by book detail and My reviews; future surfaces can present it directly.
struct ReaderReviewEditor: View {
    @State private var model: ReaderReviewEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false

    init(book: Book, store: ReaderReviewStore, repository: LibraryRepository? = nil) {
        _model = State(initialValue: ReaderReviewEditorModel(book: book, store: store, repository: repository))
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<ReaderReviewContent, Value>) -> Binding<Value> {
        Binding(get: { model.content[keyPath: keyPath] }, set: { value in
            var content = model.content; content[keyPath: keyPath] = value; model.update(content)
        })
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
                        Text(model.book.title).textStyle(.sectionHeading)
                        Text(model.book.author).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    }
                    VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
                        Text("Your rating").textStyle(.sectionHeading)
                        RatingPicker(rating: binding(\.rating))
                    }
                    VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
                        Text("Your review").textStyle(.sectionHeading)
                        Text("A few words or a whole chapter. It’s up to you.")
                            .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        TextEditor(text: binding(\.body))
                            .font(.designSystem(.bodyMedium))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 180)
                            .padding(TextualLayout.itemGap)
                            .background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
                            .accessibilityLabel("Your review")
                            .accessibilityIdentifier("review.body")
                        Text("\(model.content.body.unicodeScalars.count.formatted()) / 20,000")
                            .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Toggle("Contains spoilers", isOn: binding(\.spoilers))
                            .toggleStyle(TextualCheckboxToggleStyle())
                            .font(.designSystem(.bodyMedium))
                    }
                    Text("Only you can see this review. Closing keeps your draft on this device.")
                        .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    if model.book.importedReading?.status != "read" {
                        Text("Saving your review marks this book as read.")
                            .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    }
                    if model.hasConflict, let conflict = model.draft?.conflict {
                        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
                            Text("Saved on another device").textStyle(.sectionHeading)
                            if conflict.deleted { Text("The review was removed.").textStyle(.bodyMedium) }
                            else { ReaderReviewContentView(content: conflict.content) }
                            Button("Keep my draft") { model.resolve(keepLocal: true) }
                                .buttonStyle(TextualButtonStyle(variant: .secondary))
                            Button("Use synced review") { model.resolve(keepLocal: false) }
                                .buttonStyle(TextualButtonStyle(variant: .secondary))
                        }
                    }
                    if let message = model.message {
                        Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                            .accessibilityIdentifier("review.status")
                    }
                    if model.hasPending {
                        Button("Retry sync") { Task { await model.retry() } }
                            .buttonStyle(TextualButtonStyle(variant: .secondary))
                    }
                    if model.isBusy { ProgressView("Syncing review…").tint(.paper) }
                    Button("Save review") {
                        Task { await model.save(); if model.didSave { dismiss() } }
                    }
                    .buttonStyle(TextualButtonStyle())
                    .disabled(!model.canSave || model.hasConflict || model.hasPending)
                    .accessibilityIdentifier("review.save")
                    if model.presentation.content != nil && !model.hasPending && !model.hasConflict {
                        Button("Remove review", role: .destructive) { confirmRemoval = true }
                            .buttonStyle(TextualHeaderActionStyle())
                    }
                }
                .disabled(model.isBusy)
                .padding(TextualLayout.pageInset)
                .frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(Color.paper)
            .background(Color.inkwell.ignoresSafeArea())
            .textualSheetHeader(model.presentation.content == nil ? "Write a review" : "Edit review") { dismiss() }
            .task { await model.load() }
            .confirmationDialog("Remove your rating and review?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove review", role: .destructive) {
                    Task { await model.remove(); if model.didSave { dismiss() } }
                }
            } message: { Text("The book will stay in your archive.") }
        }
        .preferredColorScheme(.dark).tint(.paper)
    }
}

struct ReaderReviewsView: View {
    @Environment(\.readerReviews) private var store
    @Environment(\.reviewLibraryRepository) private var repository
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var books: [Book]
    @Query private var drafts: [ReaderReviewDraft]
    @State private var editingBook: Book?
    @State private var message: String?
    @State private var search = ""
    @State private var isLoading = false

    private var rows: [(book: Book, review: ReaderReviewPresentation)] {
        ReaderReviewPresentation.rows(books: books, drafts: drafts, userID: store?.userID, search: search)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                TextualSearchField("Search your reviews", text: $search)
                if isLoading { ProgressView("Syncing your reviews…").tint(.paper) }
                if let message {
                    Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    Button("Retry") { Task { await refresh() } }.buttonStyle(TextualHeaderActionStyle())
                }
                if rows.isEmpty && !isLoading {
                    Text(search.isEmpty ? "Your reading, in your own words." : "No matching reviews.")
                        .textStyle(.sectionHeading)
                    Text(search.isEmpty ? "Open a book in your archive to leave your first rating or review." : "Try another title or author.")
                        .textStyle(.bodyMedium).foregroundStyle(Color.ghost)
                }
                ForEach(rows, id: \.book.id) { row in
                    VStack(alignment: .leading, spacing: TextualLayout.groupGap) {
                        NavigationLink { BookDetailView(book: row.book) } label: {
                            VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
                                Text(row.book.title).textStyle(.sectionHeading)
                                Text(row.book.author).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                            }
                        }
                        .buttonStyle(.plain)
                        if let content = row.review.content { ReaderReviewContentView(content: content) }
                        Text(row.review.statusLabel).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        Button(row.review.hasDraftChanges ? "Continue review" : "Edit review") {
                            do { editingBook = try repository?.add(row.book) }
                            catch { message = "This review couldn’t be opened. Please try again." }
                        }
                        .buttonStyle(TextualButtonStyle(variant: .tonal))
                    }
                    .padding(.vertical, TextualLayout.groupGap)
                    .overlay(alignment: .bottom) { Divider().overlay(Color.ghost.opacity(0.3)) }
                }
            }
            .padding(TextualLayout.pageInset)
            .padding(.bottom, TextualNavigationLayout.bottomExtent)
            .frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.paper).background(Color.inkwell.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .textualBackHeader(title: "My reviews") { dismiss() }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $editingBook) { book in
            if let store { ReaderReviewEditor(book: book, store: store, repository: repository) }
        }
    }
    private func refresh() async {
        guard !isLoading, let store else { return }
        isLoading = true
        defer { isLoading = false }
        await repository?.synchronize()
        do { try await store.flush(); try await store.refreshLibrary(); message = nil }
        catch { message = "Couldn’t sync your reviews. Anything saved on this device is still here." }
    }
}
