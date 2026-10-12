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
    @StateObject private var viewModel = BookDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.inkwell
                .ignoresSafeArea()
            
            contentView(volume: viewModel.volume ?? viewModel.savedVolume(book: book))
        }
        .id(book.id)
        .textualBackHeader { dismiss() }
        .task(id: book.id) {
            await viewModel.fetchVolume(book: book)
        }
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
