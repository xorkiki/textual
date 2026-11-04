import SwiftUI

enum CommunityTab: String, TextualTabItem {
    case feed, friends
    var id: String { rawValue }
    var identifier: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Community: Friends and Feed, paged like The Archive's tabs. Friend content is
/// read-only; tapping a reader opens their public profile, tapping a book its details.
struct CommunityView: View {
    var isActive = true
    @Environment(\.socialStore) private var social
    @State private var selection: CommunityTab? = .feed
    @State private var query = ""
    @State private var openedBook: Book?

    var body: some View {
        NavigationStack {
            Group {
                if let social {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(CommunityTab.allCases) { tab in
                                page(tab, social: social)
                                    .containerRelativeFrame(.horizontal)
                                    .id(tab)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selection)
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                } else {
                    Color.inkwell.ignoresSafeArea()
                }
            }
            .textualPageHeader {
                TextualTabBar(selection: $selection, identifierPrefix: "community.tab", notice: {
                    $0 == .friends ? social?.pendingRequestNotice == true : social?.hasUnreadFeed == true
                })
            }
            .navigationDestination(for: ReaderRoute.self) { PublicReaderProfileView(username: $0.username) }
            .navigationDestination(item: $openedBook) { BookDetailView(book: $0) }
        }
        .task(id: isActive) {
            guard isActive else { return }
            await social?.reloadFriends()
            if selection == .feed {
                await loadViewedFeed()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { TextualKeyboard.dismiss() }
        }
        .onChange(of: selection) { _, tab in
            TextualKeyboard.dismiss()
            if isActive, tab == .feed {
                Task { await loadViewedFeed() }
            } else if isActive, tab == .friends {
                Task { await social?.reloadFriends() }
            }
        }
        .onChange(of: social?.pendingRequestNotice) { _, pending in
            if pending == true, isActive, selection == .friends {
                Task { await social?.reloadFriends() }
            }
        }
    }

    private func loadViewedFeed() async {
        if social?.hasUnreadFeed == true { await social?.refreshFeed() }
        else { await social?.openFeed() }
        if isActive, selection == .feed, social?.feedMessage == nil { social?.markFeedSeen() }
    }

    @ViewBuilder
    private func page(_ tab: CommunityTab, social: SocialStore) -> some View {
        switch tab {
        case .friends:
            CommunityFriendsPage(social: social, query: $query)
                .accessibilityIdentifier("community.page.friends")
        case .feed:
            CommunityFeedPage(social: social, openBook: { openedBook = $0.detailBook() },
                              findFriends: { withAnimation { selection = .friends } },
                              refresh: {
                                  await social.refreshFeed()
                                  if isActive, selection == .feed, social.feedMessage == nil { social.markFeedSeen() }
                              })
                .accessibilityIdentifier("community.page.feed")
        }
    }
}

// MARK: - Friends

private struct CommunityFriendsPage: View {
    let social: SocialStore
    @Binding var query: String
    @State private var confirmation: (action: FriendshipAction, reader: SocialReader)?

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                TextualSearchField("Search by name or username", text: $query)
                    .accessibilityIdentifier("community.search")
                if isSearching {
                    searchResults
                } else {
                    if !social.incoming.isEmpty {
                        section("Requests") {
                            ForEach(social.incoming) { reader in
                                SocialReaderRow(reader: reader) {
                                    requestActions(reader)
                                }
                            }
                        }
                    }
                    if !social.outgoing.isEmpty {
                        section("Sent") {
                            ForEach(social.outgoing) { reader in
                                SocialReaderRow(reader: reader) {
                                    Button(social.pending.contains(reader.userID) ? "Sending…" : "Cancel") {
                                        confirmation = (.cancel, reader)
                                    }
                                    .disabled(social.pending.contains(reader.userID))
                                }
                            }
                        }
                    }
                    if !social.friends.isEmpty {
                        section("Friends") {
                            ForEach(social.friends) { reader in
                                SocialReaderRow(reader: reader) { EmptyView() }
                                    .textualContextMenu {
                                        Button(role: .destructive) { confirmation = (.remove, reader) } label: {
                                            Label("Remove friend", textualIcon: .remove)
                                        }
                                    }
                                    .accessibilityAction(named: "Remove friend") { confirmation = (.remove, reader) }
                            }
                        }
                    } else if social.friendsLoaded && social.incoming.isEmpty && social.outgoing.isEmpty {
                        TextualEmptyState(title: "No friends yet", icon: .people,
                                          detail: "Search for readers you know by name or username.")
                            .foregroundStyle(Color.paper)
                            .padding(.top, 48)
                    }
                }
                if let message = social.friendsMessage {
                    Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                }
            }
            .padding(.horizontal, TextualLayout.pageInset)
            .padding(.top, TextualLayout.contentTop)
            .padding(.bottom, TextualNavigationLayout.bottomExtent + TextualLayout.pageInset)
            .frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await social.reloadFriends() }
        .task(id: query) {
            // Debounced; a newer query cancels this one and the store ignores stale replies.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await social.search(query)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation.action == .remove ? "Remove friend" : "Cancel request", role: .destructive) {
                    Task { await social.perform(confirmation.action, with: confirmation.reader) }
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if social.searchResults.isEmpty {
            if social.isSearching {
                ProgressView().tint(.paper).frame(maxWidth: .infinity)
            } else if let message = social.searchMessage {
                Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
            } else {
                Text("No readers by that name.").textStyle(.bodyMedium).foregroundStyle(Color.ghost)
            }
        } else {
            ForEach(social.searchResults) { reader in
                SocialReaderRow(reader: reader) { relationshipButton(reader) }
                    .onAppear {
                        if reader.id == social.searchResults.last?.id { Task { await social.loadMoreSearch() } }
                    }
            }
        }
    }

    /// Controls follow the server-confirmed relationship, including both request responses.
    @ViewBuilder
    private func relationshipButton(_ reader: SocialReader) -> some View {
        let state = reader.relationship?.state ?? .none
        let busy = social.pending.contains(reader.userID)
        Group {
            switch state {
            case .none:
                Button(busy ? "Sending…" : "Add") { Task { await social.perform(.send, with: reader) } }
            case .incoming:
                requestActions(reader)
            case .outgoing:
                Button(busy ? "Sending…" : "Requested") { confirmation = (.cancel, reader) }
            case .friends:
                Text("Friends").textStyle(.bodySmall).foregroundStyle(Color.ghost)
            }
        }
        .disabled(busy)
        .accessibilityIdentifier("community.relationship.\(reader.username)")
    }

    private func requestActions(_ reader: SocialReader) -> some View {
        FriendRequestActions(busy: social.pending.contains(reader.userID),
                             identifierPrefix: "community", username: reader.username,
                             accept: { Task { await social.perform(.accept, with: reader) } },
                             decline: { Task { await social.perform(.decline, with: reader) } })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TextualLayout.itemGap) {
            TextualHeading(title: title)
            content()
        }
    }

    private var confirmationTitle: String {
        guard let confirmation else { return "" }
        return confirmation.action == .remove ? "Remove \(confirmation.reader.firstName) as a friend?" : "Cancel your friend request?"
    }
}

/// One reader: avatar, name, and username open their profile; trailing actions stay separate.
struct SocialReaderRow<Actions: View>: View {
    let reader: SocialReader
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: TextualLayout.groupGap) {
            NavigationLink(value: ReaderRoute(username: reader.username)) {
                HStack(spacing: 12) {
                    ReaderAvatarBadge(reader: reader)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reader.firstName).textStyle(.bodyMedium).foregroundStyle(Color.paper).lineLimit(1)
                        Text("@\(reader.username)").textStyle(.bodySmall).foregroundStyle(Color.ghost).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens their profile")
            .accessibilityIdentifier("community.reader.\(reader.username)")
            HStack(spacing: TextualLayout.itemGap) { actions() }
                .buttonStyle(TextualHeaderActionStyle())
        }
        .frame(minHeight: 56)
    }
}

/// The library card's portrait at row size: the published photo, or a monogram.
struct ReaderAvatarBadge: View {
    let reader: SocialReader
    var size: CGFloat = 44
    var circle = false
    @Environment(\.socialStore) private var social
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.22)
            .fill(Color.velvet.opacity(0.4))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(String(reader.firstName.prefix(1)).lowercased())
                        .font(ReaderCardTypography.monogram.font(scale: size / 120))
                        .foregroundStyle(Color.paper.opacity(0.8))
                }
            }
            .frame(width: size, height: circle ? size : size * 1.24)
            .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.22))
            .accessibilityHidden(!circle)
            .task(id: reader.avatarPath) {
                image = nil
                guard let path = reader.avatarPath, let data = await social?.avatarData(path: path) else { return }
                image = UIImage(data: data)
            }
    }
}

// MARK: - Feed

private struct CommunityFeedPage: View {
    let social: SocialStore
    let openBook: (FeedBook) -> Void
    let findFriends: () -> Void
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !social.feedLoaded {
                    if let message = social.feedMessage, !social.isLoadingFeed {
                        unavailable(message)
                    } else {
                        ProgressView().tint(.paper).frame(maxWidth: .infinity).padding(.top, 96)
                    }
                } else if social.feedGroups.isEmpty {
                    if social.friendsLoaded && social.friends.isEmpty {
                        VStack(spacing: TextualLayout.groupGap) {
                            TextualEmptyState(title: "Your feed is quiet", icon: .people,
                                              detail: "Add friends to see what they’re reading.")
                            Button("Find friends", action: findFriends)
                                .buttonStyle(TextualButtonStyle(variant: .tonal))
                                .frame(maxWidth: 200)
                        }
                        .foregroundStyle(Color.paper)
                        .padding(.top, 72)
                    } else {
                        TextualEmptyState(title: "Nothing new yet", icon: .openBook,
                            detail: "When friends start or finish a book, save a quote, share a review, or add to their shelf, it shows up here.")
                            .foregroundStyle(Color.paper)
                            .padding(.top, 72)
                    }
                }
                ForEach(social.feedGroups) { group in
                    FeedGroupCard(group: group, openBook: openBook)
                        .onAppear {
                            if group.id == social.feedGroups.last?.id { Task { await social.loadMoreFeed() } }
                        }
                }
                if social.feedLoaded && social.isLoadingFeed {
                    ProgressView().tint(.paper).frame(maxWidth: .infinity).padding(.vertical, TextualLayout.groupGap)
                }
                if social.feedLoaded, let message = social.feedMessage {
                    Text(message).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        .padding(.vertical, TextualLayout.groupGap)
                }
            }
            .padding(.horizontal, TextualLayout.pageInset)
            .padding(.top, TextualLayout.contentTop)
            .padding(.bottom, TextualNavigationLayout.bottomExtent + TextualLayout.pageInset)
            .frame(maxWidth: 650).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: TextualLayout.groupGap) {
            Text(message).textStyle(.bodyMedium).foregroundStyle(Color.ghost).multilineTextAlignment(.center)
            Button("Try again") { Task { await refresh() } }
                .buttonStyle(TextualButtonStyle(variant: .tonal))
                .frame(maxWidth: 200)
                .accessibilityIdentifier("community.feed.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// One person's related updates on one book, newest first. View-only.
struct FeedGroupCard: View {
    let group: FeedGroup
    let openBook: (FeedBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                NavigationLink(value: ReaderRoute(username: group.actor.username)) {
                    HStack(spacing: 12) {
                        ReaderAvatarBadge(reader: group.actor, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.actor.firstName).font(.designSystem(.uiButton)).foregroundStyle(Color.paper)
                            Text(FeedSummary.phrase(group.events)).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens their profile")
                Spacer(minLength: TextualLayout.itemGap)
                if let date = FeedSummary.date(group) {
                    Text(FeedSummary.relative(date)).textStyle(.bodySmall).foregroundStyle(Color.ghost)
                }
            }
            Button { openBook(group.book) } label: {
                HStack(alignment: .top, spacing: 14) {
                    BookCoverImage(urlString: group.book.coverURL ?? "", width: 64, height: 96,
                                   identity: BookCoverIdentity(title: group.book.title ?? "", author: group.book.author ?? "",
                                                               isbn: group.book.isbn ?? "",
                                                               catalogID: group.book.catalogID.flatMap { $0.hasPrefix("storygraph:") ? nil : $0 }),
                                   showsProgress: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.book.title ?? "Untitled").textStyle(.bodyMedium).foregroundStyle(Color.paper)
                            .multilineTextAlignment(.leading)
                        Text(group.book.author ?? "").textStyle(.bodySmall).foregroundStyle(Color.ghost)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.book.title ?? "Untitled"), by \(group.book.author ?? "")")
            .accessibilityHint("Opens book details")
            ForEach(group.events.filter { $0.kind == .quote }) { event in
                if let quote = event.quote { ReadingQuoteText(text: quote.text, page: quote.page) }
            }
            if let review = group.events.first(where: { $0.kind == .review })?.review {
                ReaderReviewContentView(content: ReaderReviewContent(rating: review.rating, body: review.body ?? "",
                                                                     spoilers: review.spoilers ?? false))
            }
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { Divider().overlay(Color.ghost.opacity(0.3)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("community.feed.group")
    }
}

/// Wording for a feed card, in reading order regardless of event order.
enum FeedSummary {
    static func phrase(_ events: [FeedEvent]) -> String {
        var parts: [String] = []
        if let started = events.first(where: { $0.kind == .started }) {
            parts.append((started.readNumber ?? 1) > 1 ? "started a reread" : "started reading")
        }
        if let finished = events.first(where: { $0.kind == .finished }) {
            parts.append((finished.readNumber ?? 1) > 1 ? "finished a reread" : "finished reading")
        }
        if events.contains(where: { $0.kind == .review }) { parts.append("reviewed it") }
        let quotes = events.filter { $0.kind == .quote }.count
        if quotes == 1 { parts.append("saved a quote") } else if quotes > 1 { parts.append("saved \(quotes) quotes") }
        if events.contains(where: { $0.kind == .shelf }) { parts.append("added it to their shelf") }
        guard let last = parts.popLast() else { return "" }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }

    /// The newest event's display time, never later than its publication.
    static func date(_ group: FeedGroup) -> Date? {
        guard let event = group.events.first else { return nil }
        guard let occurred = event.occurredDate else { return event.publishedDate }
        return min(occurred, event.publishedDate ?? occurred)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
