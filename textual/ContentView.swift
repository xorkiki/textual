//
//  ContentView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    let legacyContainer: ModelContainer
    @State private var account = AccountSession()

    var body: some View {
        Group {
            if !account.isRestoring, !account.needsPasswordReset,
               !account.isLoadingProfile, account.profile != nil,
               let userID = account.userID {
                AccountLibraryHost(userID: userID, session: account, legacyContainer: legacyContainer)
                    .id(userID)
            } else {
                AccountView(session: account)
            }
        }
        .task { await account.start() }
        .onOpenURL { url in
            Task { await account.handleOpenURL(url) }
        }
        .preferredColorScheme(.dark)
    }
}


/// The account host stays above these tabs, so switching pages never reopens its store.
struct TextualTabView: View {
    let repository: LibraryRepository
    let account: AccountSession
    let legacyBookCount: Int
    let importLegacy: (() async throws -> Void)?
    @State private var selectedTab: TextualTab = .home
    @State private var shelfDrag = ReaderShelfDrag()
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var cachedBooks: [Book]

    private var statsCacheKey: String {
        cachedBooks.map { "\($0.id)|\($0.isbn)|\($0.title)|\($0.author)|\($0.googleBooksVolumeId ?? "")|\($0.storyGraphData?.hashValue ?? 0)" }.sorted().joined()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                ForEach(TextualTab.allCases) { tab in
                    destination(for: tab)
                        .tag(tab)
                        .tabItem { Label(tab.title, systemImage: tab.symbol) }
                        .toolbar(.hidden, for: .tabBar)
                }
            }
            .toolbar(.hidden, for: .tabBar)

            TextualBottomBar(selection: $selectedTab)
                .frame(maxWidth: 440)
                .padding(.horizontal, TextualNavigationLayout.outerPadding)
                .padding(.bottom, TextualNavigationLayout.bottomPadding)
                .frame(maxWidth: .infinity)
                .textualChromeBackground(edge: .bottom, fadeLength: 36)
        }
        // Keep the compact footer at the physical bottom edge without counting
        // the home-indicator safe area twice. Keyboard avoidance stays on.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.inkwell)
        .environment(\.readerShelfDrag, shelfDrag)
        .onChange(of: selectedTab) { _, _ in shelfDrag.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { shelfDrag.cancel() } }
        .onDisappear { shelfDrag.cancel() }
        .onOpenURL { url in
            if ReaderProfileRoute.username(url) != nil { selectedTab = .home }
        }
        .task(id: statsCacheKey) {
            await StatsMetadataCache.warm(cachedBooks)
        }
    }

    @ViewBuilder
    private func destination(for tab: TextualTab) -> some View {
        switch tab {
        case .library:
            LibraryView(repository: repository, bottomNavigationInset: TextualNavigationLayout.bottomExtent)
        case .menu:
            TextualMenuPage(repository: repository, account: account,
                            legacyBookCount: legacyBookCount, importLegacy: importLegacy,
                            openArchive: { selectedTab = .library })
        case .stats:
            TextualStatsPage()
        case .home:
            ReaderProfileView(account: account)
        case .discover:
            NavigationStack {
                Color.inkwell.ignoresSafeArea()
                    .textualPageTitle(tab.title)
            }
        }
    }
}

/// Filters stay local to this account's Stats page; years follow the imported history.
private struct TextualStatsPage: View {
    @Query(filter: #Predicate<Book> { !$0.isRemovedFromLibrary }) private var books: [Book]
    @State private var category: StatsCategory = .read
    @State private var selectedYear: Int? = nil

    private enum StatsCategory: String, CaseIterable, Identifiable {
        case read, tbr, dnf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .read: return "Read"
            case .tbr: return "TBR"
            case .dnf: return "DNF"
            }
        }
        var accessibleTitle: String {
            switch self {
            case .read: return "Read"
            case .tbr: return "To be read"
            case .dnf: return "Did not finish"
            }
        }
    }

    private var statsFilter: ReadingStatsFilter {
        ReadingStatsFilter(status: category == .read ? "read" : (category == .tbr ? "to-read" : "did-not-finish"), year: selectedYear)
    }

    // Every stats component receives the same filtered library and date scope.
    private var statsBooks: [Book] {
        books.filter { book in book.importedReading.map { statsFilter.includes($0) } ?? false }
    }

    private var recordedYears: [Int] {
        let dates = books.compactMap(\.importedReading).flatMap { reading -> [Date] in
            ReadingStatsFilter.completedDates(reading) + [ReadingStatsFilter.date(reading.dateAdded)].compactMap { $0 }
        }
        return Set(dates.map { Calendar(identifier: .gregorian).component(.year, from: $0) }).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    ReadingStatsCharts(books: statsBooks, filter: statsFilter)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, TextualNavigationLayout.bottomExtent + 24)
                }
                .scrollIndicators(.hidden)
                .textualPageHeader(compact: true) {
                    HStack(spacing: 10) {
                        Text("STATS")
                            .font(.custom("CormorantGaramond-Regular", size: 28))
                            .foregroundStyle(Color.paper)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        TextualDropdown(label: "Reading status", title: category.title,
                            options: StatsCategory.allCases.map {
                                TextualDropdownOption(value: $0, title: $0.title, accessibilityTitle: $0.accessibleTitle)
                            }, selection: $category)
                            .accessibilityIdentifier("stats.category")
                        TextualDropdown(label: "Time period", title: selectedYear.map(String.init) ?? "All time",
                            options: [TextualDropdownOption(value: Int?.none, title: "All time")]
                                + recordedYears.map { TextualDropdownOption(value: Optional($0), title: String($0)) },
                            selection: $selectedYear)
                            .accessibilityIdentifier("stats.period")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }
            }
            .textualDropdownHost()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: recordedYears) { _, years in
                if let selectedYear, !years.contains(selectedYear) { self.selectedYear = nil }
            }
        }
    }


}

enum TextualNavigationLayout {
    static let itemHeight: CGFloat = 44
    static let innerPadding: CGFloat = 6
    static let outerPadding: CGFloat = 24
    static let bottomPadding: CGFloat = 12
    static var bottomExtent: CGFloat { itemHeight + innerPadding * 2 + bottomPadding }
}

enum TextualTab: String, CaseIterable, Identifiable {
    case home, library, discover, stats, menu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Profile"
        case .library: return "My Archive"
        case .discover: return "The Archive"
        default: return rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .home: return "person.crop.circle"
        case .library: return "books.vertical"
        case .discover: return "safari"
        case .stats: return "chart.bar"
        case .menu: return "line.3.horizontal"
        }
    }
}

private struct TextualBottomBar: View {
    @Binding var selection: TextualTab
    @Environment(\.readerShelfDrag) private var shelfDrag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dragging: Bool { shelfDrag?.isDragging == true }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                tabs
                    .frame(width: geometry.size.width)
                    .opacity(dragging ? 0 : 1)
                    .scaleEffect(dragging && !reduceMotion ? 0.94 : 1)
                    .allowsHitTesting(!dragging)
                    .accessibilityHidden(dragging)
                if dragging, let shelfDrag {
                    Image(systemName: "trash")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(shelfDrag.isOverTrash ? Color.paper : Color.ghost)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
                        .accessibilityHidden(true)
                    ReaderShelfTrashTarget(state: shelfDrag)
                        .frame(width: 56, height: 56)
                        .accessibilityLabel("Remove book from shelf")
                        .accessibilityHint("Drop the lifted book here. It stays in your archive.")
                        .accessibilityIdentifier("profile.shelfTrash")
                }
            }
            .frame(width: dragging ? 56 : geometry.size.width, height: 56)
            .background {
                Capsule()
                    .fill(dragging && shelfDrag?.isOverTrash == true ? Color.bloodletter : Color.velvet.opacity(0.35))
                    .animation(.easeInOut(duration: 0.16), value: dragging && shelfDrag?.isOverTrash == true)
            }
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .animation(motion, value: dragging)
        }
        .frame(height: 56)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(TextualTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    tabIcon(tab)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.ghost)
                        .frame(maxWidth: .infinity, minHeight: TextualNavigationLayout.itemHeight,
                               maxHeight: TextualNavigationLayout.itemHeight)
                        .background {
                            if selection == tab { Capsule().fill(Color.bloodletterFaded) }
                        }
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("navigation.\(tab.rawValue)")
            }
        }
        .padding(TextualNavigationLayout.innerPadding)
    }

    @ViewBuilder
    private func tabIcon(_ tab: TextualTab) -> some View {
        switch tab {
        case .home:
            Image(designSystemIcon: .profile)
                .renderingMode(.template).resizable().scaledToFit()
        case .menu:
            Image(designSystemIcon: .menu)
                .renderingMode(.template).resizable().scaledToFit()
        default:
            Image(systemName: tab.symbol)
                .font(.system(size: 23, weight: .regular))
        }
    }
}

/// Existing account tools remain reachable while the rest of Menu is still unbuilt.
private struct TextualMenuPage: View {
    let repository: LibraryRepository
    let account: AccountSession
    let legacyBookCount: Int
    let importLegacy: (() async throws -> Void)?
    let openArchive: () -> Void
    @State private var showImport = false
    @State private var showAccount = false
    @State private var confirmImport = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        menuRow("Account") { showAccount = true }
                            .accessibilityIdentifier("menu.account")
                        Divider().overlay(Color.velvet)
                        menuRow("Import reading data") { showImport = true }
                            .accessibilityIdentifier("menu.import")
                        Divider().overlay(Color.velvet)
                    }
                    .frame(maxWidth: 480)
                    .padding(28)
                    .padding(.bottom, TextualNavigationLayout.bottomExtent)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .textualPageTitle("Menu")
            .sheet(isPresented: $showImport) {
                StoryGraphImportView(repository: repository, accountEmail: account.email, openArchive: openArchive)
            }
            .sheet(isPresented: $showAccount) {
                VStack(spacing: 0) {
                    if legacyBookCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(legacyBookCount) books are saved on this device.")
                            Button("Import existing library") { confirmImport = true }
                        }
                        .padding()
                    }
                    AccountView(session: account)
                }
                .background(Color.inkwell)
                .preferredColorScheme(.dark)
                .confirmationDialog("Import the device library into this account?", isPresented: $confirmImport) {
                    Button("Import books") {
                        Task {
                            do {
                                try await importLegacy?()
                                await repository.synchronize()
                            } catch {
                                importError = "The import couldn’t finish. Your original books are safe; please try again."
                                showAccount = false
                            }
                        }
                    }
                } message: {
                    Text("These books will be uploaded to \(account.email ?? "your account"). The original device library will be preserved.")
                }
            }
            .alert("Couldn’t import library", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
        }
    }
    private func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("PlusJakartaSans-Regular", size: 16, relativeTo: .body))
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

private extension View {
    func textualPageTitle(_ title: String) -> some View {
        self
            .toolbar(.hidden, for: .navigationBar)
            .textualPageHeader {
                Text(title.uppercased())
                    .font(.custom("CormorantGaramond-Regular", size: 28, relativeTo: .title2))
                    .foregroundStyle(Color.paper)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 24)
            }
    }
}
