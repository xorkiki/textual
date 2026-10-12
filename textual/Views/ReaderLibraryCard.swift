import SwiftUI

struct ReaderLibraryCard: View {
    let firstName: String
    let username: String
    let content: ReaderPublicContent
    var avatarData: Data? = nil
    var avatarTransport: (any ReaderAvatarTransport)? = nil
    var choosePhoto: (() -> Void)? = nil
    var isPreparingPhoto = false

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 350
            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                    Text("TEXTUAL")
                        .font(.custom("CormorantGaramond-Regular", fixedSize: 28 * scale))
                    Spacer(minLength: 0)
                    Text("Library Card")
                        .font(.custom("CormorantGaramond-SemiBold", fixedSize: 29 * scale))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack(alignment: .top, spacing: 14 * scale) {
                    ReaderCardAvatar(firstName: firstName, path: content.avatarPath,
                                     localData: avatarData, transport: avatarTransport,
                                     choosePhoto: choosePhoto, isPreparing: isPreparingPhoto, scale: scale)
                    .frame(width: 74 * scale, height: 92 * scale)
                    VStack(alignment: .leading, spacing: 12 * scale) {
                        Text(firstName)
                            .font(.custom("CormorantGaramond-Regular", fixedSize: 31 * scale))
                            .lineLimit(1).minimumScaleFactor(0.45)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12 * scale) {
                            stat(content.stats.reads, "READS", scale: scale)
                            stat(content.stats.genres, "GENRES", scale: scale)
                            stat(content.stats.rereads, "REREADS", scale: scale)
                        }
                    }
                    .frame(height: 92 * scale, alignment: .center)
                }
                Text(content.sentence)
                    .font(.custom("CormorantGaramond-Regular", fixedSize: 15.5 * scale))
                    .foregroundStyle(Color.paper.opacity(0.9))
                    .lineLimit(3).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 41 * scale, maxHeight: 41 * scale, alignment: .leading)
                    .accessibilityIdentifier("profile.readerSentence")
            }
            .foregroundStyle(Color.paper)
            .padding(16 * scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.moss.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .aspectRatio(1.586, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.libraryCard")
    }

    private func stat(_ count: Int, _ label: String, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(count.formatted()).font(.custom("CormorantGaramond-Regular", fixedSize: 23 * scale))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.custom("PlusJakartaSans-Regular", fixedSize: 7 * scale))
                .tracking(0.5 * scale)
                .foregroundStyle(Color.paper.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        .accessibilityElement(children: .combine)
    }

}

private struct ReaderCardAvatar: View {
    let firstName: String
    let path: String?
    let localData: Data?
    let transport: (any ReaderAvatarTransport)?
    let choosePhoto: (() -> Void)?
    let isPreparing: Bool
    let scale: CGFloat
    @State private var downloadedData: Data?
    @State private var downloadedPath: String?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var retry = 0

    private var photo: UIImage? {
        let data = localData ?? (downloadedPath == path ? downloadedData : nil)
        return data.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        Group {
            if let choosePhoto {
                Button(action: choosePhoto) { portrait }
                    .buttonStyle(.plain).disabled(isPreparing)
                    .accessibilityLabel(path == nil ? "Add profile photo" : "Change profile photo")
                    .accessibilityHint("Choose a photo for your public library card")
                    .accessibilityIdentifier("profile.choosePhoto")
            } else if loadFailed {
                Button { retry += 1 } label: { portrait }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry loading \(firstName)’s profile photo")
            } else {
                portrait.accessibilityLabel("\(firstName)’s profile photo")
            }
        }
        .task(id: "\(path ?? "")-\(retry)") {
            downloadedData = nil; downloadedPath = nil; loadFailed = false
            guard localData == nil, let path, let transport else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let data = try await transport.downloadAvatar(path: path)
                try Task.checkCancellation()
                guard UIImage(data: data) != nil else { throw ReaderAvatar.PhotoError.invalid }
                downloadedPath = path; downloadedData = data
            } catch is CancellationError { }
            catch { loadFailed = true }
        }
    }

    private var portrait: some View {
        RoundedRectangle(cornerRadius: 10 * scale)
            .fill(Color.velvet.opacity(0.4))
            .overlay {
                if let photo {
                    GeometryReader { geometry in
                        Image(uiImage: photo).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else if choosePhoto != nil {
                    RoundedRectangle(cornerRadius: 10 * scale)
                        .strokeBorder(Color.ghost.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Image(systemName: "plus")
                        .font(.system(size: 23 * scale, weight: .light)).foregroundStyle(Color.ghost)
                } else {
                    Text(String(firstName.prefix(1)).lowercased())
                        .font(.custom("CormorantGaramond-Regular", fixedSize: 64 * scale))
                        .foregroundStyle(Color.paper.opacity(0.8))
                }
            }
            .overlay {
                if isPreparing || isLoading {
                    Color.inkwell.opacity(0.35)
                    ProgressView().tint(.paper)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
            .contentShape(RoundedRectangle(cornerRadius: 10 * scale))
    }
}

struct ReaderBookshelf: View {
    let readerName: String
    let favorites: [ReaderFavorite]
    var isOwner = false
    var add: (() -> Void)?
    var move: ((UUID, UUID) -> Void)?
    var remove: ((UUID) -> Void)?
    var onCoverResolved: ((ReaderFavorite, String) -> Void)? = nil
    let open: (ReaderFavorite) -> Void
    @Environment(\.readerShelfDrag) private var shelfDrag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsAddTile: Bool { isOwner && favorites.count < ReaderShelf.limit }
    private var rowCount: Int { (favorites.count + (showsAddTile ? 1 : 0) + 2) / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(readerName)’s book shelf")
                .font(.custom("CormorantGaramond-Regular", size: 28, relativeTo: .title2))
                .foregroundStyle(Color.paper)
            shelfGrid
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.bookshelf")
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86), value: favorites.map(\.id))
    }

    // One identity scope for every cover. Nested row ForEachs destroy and reload
    // a book's hosting controller and image state whenever it crosses a row.
    private var shelfGrid: some View {
        GeometryReader { geometry in
            let width = max(32, (geometry.size.width - 24) / 3)
            ZStack(alignment: .topLeading) {
                ForEach(0..<rowCount, id: \.self) { row in
                    Rectangle()
                        .fill(Color.ghost.opacity(0.3))
                        .frame(width: geometry.size.width, height: 6)
                        .position(x: geometry.size.width / 2, y: CGFloat(row) * 210 + 179)
                }
                ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
                    shelfBook(favorite, width: width)
                        .position(x: CGFloat(index % 3) * (width + 12) + width / 2,
                                  y: CGFloat(index / 3) * 210 + 176 - coverHeight(favorite, width: width) / 2)
                }
                if showsAddTile {
                    addTile(width: width)
                        .position(x: CGFloat(favorites.count % 3) * (width + 12) + width / 2,
                                  y: CGFloat(favorites.count / 3) * 210 + 176 - min(170, width * 1.55) / 2)
                }
            }
        }
        .frame(height: CGFloat(max(0, rowCount * 210 - 28)))
    }

    private func coverHeight(_ favorite: ReaderFavorite, width: CGFloat) -> CGFloat {
        min(170, width * (favorite.id.uuidString.utf8.first.map { $0 % 3 == 0 } == true ? 1.35 : 1.55))
    }

    private func addTile(width: CGFloat) -> some View {
        Button { add?() } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.velvet.opacity(0.4))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.ghost.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(Color.ghost)
                }
                .frame(width: width, height: min(170, width * 1.55))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("Add books to your shelf")
        .accessibilityHint("Choose favorites from your archive")
        .accessibilityIdentifier("profile.addFavorites")
    }

    @ViewBuilder
    private func shelfBook(_ favorite: ReaderFavorite, width: CGFloat) -> some View {
        let height = coverHeight(favorite, width: width)
        let cover = Button { open(favorite) } label: {
            BookCoverImage(urlString: favorite.coverURL, width: width, height: height,
                identity: BookCoverIdentity(title: favorite.title, author: favorite.author,
                    isbn: favorite.isbn, catalogID: favorite.catalogID),
                onResolved: { onCoverResolved?(favorite, $0) })
                .shadow(color: .black.opacity(0.4), radius: 4, x: 2, y: 2)
        }
        .accessibilityLabel("\(favorite.title), by \(favorite.author)")
        .accessibilityHint(isOwner ? "Opens book details. Drag to reorder, or use actions to move or remove." : "Opens book details")
        .accessibilityIdentifier("profile.favorite.\(favorite.id)")

        if isOwner, let shelfDrag {
            ReaderShelfDragSource(id: favorite.id, order: favorites.map(\.id), state: shelfDrag,
                                  move: { move?($0, $1) }, remove: { remove?($0) }, open: { open(favorite) }) { cover }
                .frame(width: width, height: height)
                .opacity(shelfDrag.bookID == favorite.id ? 0 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(favorite.title), by \(favorite.author)")
                .accessibilityHint("Drag to reorder or drop on the trash. Double tap for details.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("profile.favorite.\(favorite.id)")
                .accessibilityAction { open(favorite) }
                .accessibilityAction(named: "Move earlier") { moveBy(-1, favorite) }
                .accessibilityAction(named: "Move later") { moveBy(1, favorite) }
                .accessibilityAction(named: "Remove from shelf") { remove?(favorite.id) }
        } else { cover }
    }

    private func moveBy(_ offset: Int, _ favorite: ReaderFavorite) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }),
              favorites.indices.contains(index + offset) else { return }
        move?(favorite.id, favorites[index + offset].id)
    }
}
