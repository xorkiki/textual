import SwiftUI
import SwiftData

struct BookActionSheet: View {
    let route: BookActionRoute
    let repository: LibraryRepository?
    @Environment(\.readerReviews) private var reviews
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if route.action == .finish {
                if let reviews {
                    ReaderReviewEditor(book: route.book, store: reviews, repository: repository)
                } else {
                    NavigationStack {
                        Text("Your rating editor isn’t available. Reopen your archive and try again.")
                            .textStyle(.bodyMedium)
                            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.inkwell).foregroundStyle(Color.paper)
                            .textualSheetHeader("Finish + rate") { dismiss() }
                    }
                }
            } else {
                ReadingEntrySheet(book: route.book, action: route.action, repository: repository,
                                  editingEntry: route.editingEntry)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }.preferredColorScheme(.dark).tint(.paper)
            .presentationBackground(Color.inkwell)
    }
}

private struct ReadingEntrySheet: View {
    let book: Book
    let action: BookQuickAction
    let repository: LibraryRepository?
    let editingEntry: ReadingJournal.Entry?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.socialStore) private var social
    @State private var text = ""
    @State private var pageText = ""
    @State private var unit: ReadingJournal.Progress.Unit = .page
    @State private var error: String?
    @FocusState private var focused: Bool

    private var pageNumber: Int? {
        guard action == .quote, !pageText.isEmpty, let n = Int(pageText), n > 0 else { return nil }
        return n
    }
    private var sheetTitle: String {
        editingEntry != nil ? "Edit quote" : action.title
    }
    private var valid: Bool {
        if action == .progress {
            guard let value = Int(text) else { return false }
            return (0...(unit == .percent ? 100 : 1_000_000)).contains(value)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else { return false }
        if action == .quote, !pageText.isEmpty {
            guard let n = Int(pageText), n > 0, n <= 1_000_000 else { return false }
        }
        return true
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(book.title).textStyle(.sectionHeading)
                    if action == .progress {
                        HStack(spacing: 4) {
                            ForEach(ReadingJournal.Progress.Unit.allCases, id: \.self) { option in
                                Button {
                                    if unit != option { unit = option; text = "" }
                                } label: {
                                    Text(option == .page ? "Page" : "Percent")
                                        .font(.designSystem(.bodySmall))
                                        .foregroundStyle(unit == option ? Color.paper : Color.ghost)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(unit == option ? Color.bloodletterFaded : Color.clear, in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(unit == option ? .isSelected : [])
                            }
                        }
                        .padding(4)
                        .background(Color.velvet, in: Capsule())
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Measure progress in")
                        TextField(unit == .page ? "Page number" : "Percentage (0–100)", text: $text)
                            .keyboardType(.numberPad).focused($focused)
                            .textFieldStyle(.plain).font(.designSystem(.heading3))
                            .padding().background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
                            .accessibilityIdentifier("reading.progress.input")
                    } else {
                        TextEditor(text: $text)
                            .focused($focused).scrollContentBackground(.hidden)
                            .font(.designSystem(.bodyMedium)).frame(minHeight: 140)
                            .padding(12).background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
                            .accessibilityLabel(action == .quote ? "Quote" : "Note")
                            .accessibilityIdentifier("reading.\(action.rawValue).input")
                        Text("\(text.count) / 4,000 · \(audience)")
                            .textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        if action == .quote {
                            TextField("Page number (optional)", text: $pageText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.plain)
                                .font(.designSystem(.bodyMedium))
                                .padding(12)
                                .background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
                                .accessibilityIdentifier("reading.quote.page")
                        }
                    }
                    if let error { Text(error).textStyle(.bodySmall).foregroundStyle(Color.ghost) }
                    Button("Save") { save() }
                        .buttonStyle(TextualButtonStyle()).disabled(!valid)
                        .accessibilityIdentifier("reading.save")
                }.padding(TextualLayout.pageInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(Color.paper).background(Color.inkwell)
            .textualSheetHeader(sheetTitle) { dismiss() }
            .onAppear {
                if let entry = editingEntry {
                    text = entry.text
                    if let page = entry.page { pageText = String(page) }
                } else if action == .progress, let progress = book.importedReading?.journal?.progress {
                    unit = progress.unit; text = String(progress.value)
                }
                focused = true
            }
        }
    }
    /// Only a newly saved quote can be shared, and only while sharing is on.
    private var audience: String {
        action == .quote && editingEntry == nil && social?.settings.stamp != nil ? "Shared with friends" : "Only you"
    }

    private func save() {
        do {
            if action == .progress, let value = Int(text) {
                try BookReadingActions.updateProgress(value, unit: unit, book: book, context: context, repository: repository)
            } else if let entry = editingEntry {
                try BookReadingActions.updateEntry(id: entry.id, text: text, page: pageNumber,
                                                   action: action, book: book, context: context, repository: repository)
            } else {
                try BookReadingActions.append(text, page: pageNumber, action: action, book: book,
                                              context: context, repository: repository)
            }
            Task { await repository?.synchronize() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Embedded only in the personal reading detail route, not public/catalog details.
struct BookReadingSection: View {
    let book: Book
    @Environment(\.reviewLibraryRepository) private var repository
    @Environment(\.modelContext) private var context
    @State private var route: BookActionRoute?
    @State private var error: String?
    @State private var quoteToDelete: ReadingJournal.Entry?
    private var reading: StoryGraphReadingData { UpNextQueue.metadata(for: book) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextualDropdown(label: "Reading status", title: reading.statusLabel,
                    options: [
                        .init(value: "currently-reading", title: "Currently reading"),
                        .init(value: "read", title: "Finish + rate"),
                        .init(value: "to-read", title: "To read"),
                        .init(value: "did-not-finish", title: "Did not finish")
                    ], selection: Binding(get: { reading.status }, set: { status in
                        if status == "read" { route = .init(book: book, action: .finish) }
                        else { setStatus(status) }
                    }))
                Spacer()
                Button { route = .init(book: book, action: .progress) } label: {
                    Label(reading.journal?.progress?.label ?? "Update progress", textualIcon: .pieChart)
                        .frame(minHeight: 44)
                }
            }.textStyle(.bodySmall)
            quoteSection(entries: reading.journal?.quotes ?? [])
            journalSection("Notes", entries: reading.journal?.notes ?? [], action: .note)
        }
        .foregroundStyle(Color.paper)
        .buttonStyle(.plain)
        .sheet(item: $route) { BookActionSheet(route: $0, repository: repository) }
        .confirmationDialog("Delete this quote?",
            isPresented: Binding(get: { quoteToDelete != nil }, set: { if !$0 { quoteToDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = quoteToDelete { deleteQuote(entry); quoteToDelete = nil }
            }
        }
        .alert("Couldn’t save reading", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func quoteSection(entries: [ReadingJournal.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved quotes").textStyle(.sectionHeading)
                Spacer()
                Button { route = .init(book: book, action: .quote) } label: {
                    DesignSystemIconView(BookQuickAction.quote.icon, size: 20).frame(width: 44, height: 44)
                }.accessibilityLabel(BookQuickAction.quote.title)
            }
            if entries.isEmpty {
                Text("Keep the words that stay with you.")
                    .textStyle(.bodySmall).foregroundStyle(Color.ghost)
            }
            ForEach(entries.reversed()) { entry in
                quoteCard(entry)
            }
        }
    }

    private func quoteCard(_ entry: ReadingJournal.Entry) -> some View {
        ReadingQuoteCard(entry: entry,
                         edit: { route = .init(book: book, action: .quote, editingEntry: entry) },
                         delete: { quoteToDelete = entry })
    }

    private func journalSection(_ title: String, entries: [ReadingJournal.Entry], action: BookQuickAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).textStyle(.sectionHeading)
                Spacer()
                Button { route = .init(book: book, action: action) } label: {
                    DesignSystemIconView(action.icon, size: 20).frame(width: 44, height: 44)
                }.accessibilityLabel(action.title)
            }
            if entries.isEmpty {
                Text("A place for your thoughts.")
                    .textStyle(.bodySmall).foregroundStyle(Color.ghost)
            }
            ForEach(entries.reversed()) { entry in
                Text(entry.text).textStyle(.bodyMedium).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
            }
        }
    }

    private func setStatus(_ status: String) {
        do {
            try BookReadingActions.setStatus(status, book: book, context: context, repository: repository)
            Task { await repository?.synchronize() }
        } catch { self.error = error.localizedDescription }
    }

    private func deleteQuote(_ entry: ReadingJournal.Entry) {
        do {
            try BookReadingActions.deleteEntry(id: entry.id, action: .quote, book: book,
                                               context: context, repository: repository)
            Task { await repository?.synchronize() }
        } catch { self.error = error.localizedDescription }
    }
}

/// Shared by book detail's Saved quotes and My quotes: tap to edit, hold for edit/delete.
/// Community shows a friend's quote with the same card, read-only.
struct ReadingQuoteCard: View {
    let entry: ReadingJournal.Entry
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ReadingQuoteText(text: entry.text, page: entry.page)
        .onTapGesture(perform: edit)
        .textualContextMenu {
            Button(action: edit) { Label("Edit", textualIcon: .edit) }
            Button(role: .destructive, action: delete) { Label("Delete", textualIcon: .remove) }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Delete", delete)
    }
}

struct ReadingQuoteText: View {
    let text: String
    let page: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).textStyle(.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let page {
                Text("p. \(page)").textStyle(.bodySmall).foregroundStyle(Color.ghost)
            }
        }
        .padding(14)
        .background(Color.velvet, in: RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
        .contentShape(RoundedRectangle(cornerRadius: TextualLayout.cardRadius))
    }
}

/// My Archive → My quotes: every saved quote, grouped by book, laid out like My reviews.
struct ReaderQuotesView: View {
    @Environment(\.reviewLibraryRepository) private var repository
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }, sort: \Book.title) private var books: [Book]
    @State private var route: BookActionRoute?
    @State private var quoteToDelete: (book: Book, entry: ReadingJournal.Entry)?
    @State private var error: String?
    @State private var search = ""

    private var rows: [(book: Book, quotes: [ReadingJournal.Entry])] {
        ReadingQuoteRows.rows(books: books, search: search)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                TextualSearchField("Search your quotes", text: $search)
                if rows.isEmpty {
                    Text(search.isEmpty ? "The words that stayed with you." : "No matching quotes.")
                        .textStyle(.sectionHeading)
                    Text(search.isEmpty ? "Open a book in your archive to save your first quote." : "Try another title, author, or phrase.")
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
                        ForEach(row.quotes) { entry in
                            ReadingQuoteCard(entry: entry,
                                             edit: { route = .init(book: row.book, action: .quote, editingEntry: entry) },
                                             delete: { quoteToDelete = (row.book, entry) })
                        }
                        Button("Add quote") { route = .init(book: row.book, action: .quote) }
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
        .textualBackHeader(title: "My quotes") { dismiss() }
        .refreshable { await repository?.synchronize() }
        .sheet(item: $route) { BookActionSheet(route: $0, repository: repository) }
        .confirmationDialog("Delete this quote?",
            isPresented: Binding(get: { quoteToDelete != nil }, set: { if !$0 { quoteToDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = quoteToDelete { deleteQuote(target.entry, from: target.book); quoteToDelete = nil }
            }
        }
        .alert("Couldn’t save reading", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func deleteQuote(_ entry: ReadingJournal.Entry, from book: Book) {
        do {
            try BookReadingActions.deleteEntry(id: entry.id, action: .quote, book: book,
                                               context: context, repository: repository)
            Task { await repository?.synchronize() }
        } catch { self.error = error.localizedDescription }
    }
}
