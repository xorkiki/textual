import SwiftUI
import UniformTypeIdentifiers

struct StoryGraphImportView: View {
    let repository: LibraryRepository
    let accountEmail: String?
    let openArchive: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chooseFile = false
    @State private var document: StoryGraphDocument?
    @State private var preview: StoryGraphImportPreview?
    @State private var completed: StoryGraphImportPreview?
    @State private var fileName = ""
    @State private var errorMessage: String?
    @State private var isReading = false
    @State private var isSaving = false
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(completed == nil ? "Bring your reading with you." : "Your reading, saved.")
                        .font(.custom("CormorantGaramond-Regular", size: 32, relativeTo: .title))
                    if let completed {
                        Text("\(completed.added) added · \(completed.updated) updated · \(completed.unchanged) already in your archive")
                        Text("Your reading history is saved to this account on this iPhone.")
                        Text(repository.message ?? (repository.syncState == .idle ? "Your archive is synced." : "Your archive will sync when connected."))
                            .foregroundStyle(Color.ghost)
                        action("View My Archive") { dismiss(); openArchive() }
                    } else {
                        Text("Choose your StoryGraph CSV export. Review it here before adding it to My Archive.")
                            .foregroundStyle(Color.ghost)
                        Text("Private to \(accountEmail ?? "your signed-in account")")
                            .font(.custom("PlusJakartaSans-Regular", size: 13, relativeTo: .caption))
                        if isReading {
                            ProgressView("Reading your export…")
                        } else if let document, let preview {
                            Text(fileName).font(.caption).foregroundStyle(Color.ghost).lineLimit(2)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("\(document.records.count) books").font(.custom("PlusJakartaSans-Medium", size: 20))
                                countRow("New books", preview.added)
                                countRow("Reading data updates", preview.updated)
                                countRow("Already imported", preview.unchanged)
                                Divider().overlay(Color.velvet)
                                ForEach(["read", "currently-reading", "to-read", "did-not-finish"], id: \.self) { status in
                                    if let count = document.statusCounts[status], count > 0 {
                                        countRow(statusTitle(status), count)
                                    }
                                }
                            }
                            Text("Reading dates, rereads, ratings, reviews, moods, tags and ownership are preserved. Matching books keep their current titles and covers; their StoryGraph reading data will be updated. Nothing else is removed.")
                                .font(.custom("PlusJakartaSans-Regular", size: 13, relativeTo: .caption))
                                .foregroundStyle(Color.ghost)
                            if document.duplicateRows > 0 { Text("\(document.duplicateRows) identical duplicate rows skipped.") }
                            if !document.warnings.isEmpty {
                                DisclosureGroup("\(document.warnings.count) import notes") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                                            Text(warning).font(.caption)
                                        }
                                    }
                                }
                            }
                            DisclosureGroup("Preview books") {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(document.records, id: \.reading.sourceKey) { record in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.title)
                                            Text("\(record.author) · \(record.reading.statusLabel)")
                                                .font(.caption).foregroundStyle(Color.ghost)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(.top, 12)
                            }
                            action(isSaving ? "Saving…" : "Import into My Archive") { save(document) }
                                .accessibilityIdentifier("import.confirm")
                                .disabled(isSaving)
                        }
                        if !isReading {
                            Button(document == nil ? "Choose CSV Import" : "Choose another file") { chooseFile = true }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.velvet.opacity(0.35), in: Capsule())
                                .disabled(isSaving)
                                .accessibilityIdentifier("import.choose")
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(Color.paper).accessibilityIdentifier("import.error")
                        }
                    }
                }
                .font(.custom("PlusJakartaSans-Regular", size: 15, relativeTo: .body))
                .foregroundStyle(Color.paper)
                .padding(28)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Color.inkwell)
            .navigationTitle("Import reading data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(isSaving) } }
        }
        .tint(Color.paper)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { read(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onDisappear { readTask?.cancel() }
    }

    private func countRow(_ label: String, _ count: Int) -> some View {
        HStack { Text(label); Spacer(); Text(count.formatted()).monospacedDigit() }
    }
    private func statusTitle(_ status: String) -> String {
        switch status {
        case "read": return "Read"
        case "currently-reading": return "Currently reading"
        case "to-read": return "To read"
        default: return "Did not finish"
        }
    }
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(Color.inkwell).background(Color.paper, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func read(_ url: URL) {
        readTask?.cancel()
        document = nil; preview = nil; errorMessage = nil; isReading = true
        fileName = url.lastPathComponent
        readTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try StoryGraphImporter.read(url: url) }
            do {
                let parsed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                preview = try repository.previewStoryGraphImport(parsed)
                document = parsed
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
            isReading = false
        }
    }
    private func save(_ document: StoryGraphDocument) {
        guard !isSaving else { return }
        isSaving = true; errorMessage = nil
        Task {
            do {
                completed = try await repository.importStoryGraph(document, expectedUserID: repository.userID)
                self.document = nil
                isSaving = false
                await repository.synchronize()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
