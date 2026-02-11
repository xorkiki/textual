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
            
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(message: error)
            } else if let volume = viewModel.volume {
                contentView(volume: volume)
            } else {
                fallbackView
            }
        }
        .id(book.id)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(Color.inkwell, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    DesignSystemIconView(.arrowLeft, size: 24, color: .paper)
                }
                .buttonStyle(IconButtonStyle())
            }
            ToolbarItem(placement: .principal) {
                Text("Book Details")
                    .font(.custom("CormorantGaramond-Regular", size: 20))
                    .textCase(.uppercase)
                    .foregroundColor(.paper)
            }
        }
        .onAppear {
            Task { await viewModel.fetchVolume(book: book) }
        }
    }
    
    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Cover skeleton
                Skeleton()
                    .frame(width: 140, height: 210)
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Skeleton()
                        .frame(width: 200, height: 28)
                    Skeleton()
                        .frame(width: 120, height: 18)
                }
                
                Skeleton()
                    .frame(height: 120)
                
                ProgressView()
                    .tint(.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
            .padding()
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.ghost)
            Text(message)
                .textStyle(.bodyMedium)
                .foregroundColor(.ghost)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            TonalButton(title: "Go Back", action: { dismiss() })
                .frame(width: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var fallbackView: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundColor(.ghost)
            Text("Details not available")
                .textStyle(.heading3)
                .foregroundColor(.paper)
            Text("This book may have been added before detail lookup was available.")
                .textStyle(.bodySmall)
                .foregroundColor(.ghost)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            TonalButton(title: "Go Back", action: { dismiss() })
                .frame(width: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func contentView(volume: GoogleBooksService.BookItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Cover + Title block
                HStack(alignment: .top, spacing: 20) {
                    coverImage(urlString: book.coverURL.isEmpty ? viewModel.coverURL(from: volume) : book.coverURL)
                    
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
                        
                        Text(AttributedString(html: desc))
                            .textStyle(.bodyMedium)
                            .foregroundColor(.paper)
                            .lineSpacing(6)
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func coverImage(urlString: String) -> some View {
        if !urlString.isEmpty {
            BookCoverImage(urlString: urlString, width: 140, height: 210)
                .shadow(color: .inkwell.opacity(0.3), radius: 8, x: 0, y: 4)
        } else {
            coverPlaceholder
        }
    }
    
    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.velvet.opacity(0.3))
            .frame(width: 140, height: 210)
            .overlay {
                Image(systemName: "book.closed")
                    .foregroundColor(.ghost)
                    .font(.system(size: 48))
            }
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
