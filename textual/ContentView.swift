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
        .textualScreenDefaults()
    }
}


/// The account host stays above these tabs, so switching pages never reopens its store.
struct TextualTabView: View {
    let repository: LibraryRepository
    let account: AccountSession
    let legacyBookCount: Int
    let importLegacy: (() async throws -> Void)?
    @State private var selectedTab: TextualTab = .home
    @State private var visitedTabs: Set<TextualTab> = [.home]
    @State private var shelfDrag = ReaderShelfDrag()
    @State private var queueDrag = ReaderShelfDrag()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.socialStore) private var social
    @State private var readingLibrary = ReadingLibraryCache()

    var body: some View {
        ZStack(alignment: .bottom) {
            // The custom bar owns all six destinations. A native TabView adds a
            // More navigation stack after five tabs, including its own header/back button.
            // Keep visited pages mounted so their navigation and filters survive switching.
            ZStack {
                ForEach(TextualTab.allCases) { tab in
                    if tab == selectedTab || visitedTabs.contains(tab) {
                        destination(for: tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(tab == selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == selectedTab)
                            .accessibilityHidden(tab != selectedTab)
                            .zIndex(tab == selectedTab ? 1 : 0)
                    }
                }
            }

            TextualBottomBar(selection: $selectedTab)
                .environment(\.readerShelfDrag, selectedTab == .library ? queueDrag : shelfDrag)
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
        .onChange(of: selectedTab) { _, tab in
            visitedTabs.insert(tab)
            shelfDrag.cancel()
            queueDrag.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { shelfDrag.cancel(); queueDrag.cancel() }
            // Revalidate friend content and privacy settings on every return to the app.
            if phase == .active { Task { await social?.revalidate() } }
        }
        // Settings first: new actions can only be shared once sharing is known to be on.
        .task { await social?.settings.refresh() }
        .onDisappear { shelfDrag.cancel(); queueDrag.cancel() }
        .onOpenURL { url in
            if ReaderProfileRoute.username(url) != nil { selectedTab = .profile }
        }
        .environment(\.readingLibrary, readingLibrary)
        .background { ReadingLibraryObserver(cache: readingLibrary) }
    }

    @ViewBuilder
    private func destination(for tab: TextualTab) -> some View {
        switch tab {
        case .library:
            LibraryView(repository: repository, bottomNavigationInset: TextualNavigationLayout.bottomExtent)
                // The same book can appear on both mounted tabs. Keep their drag targets separate.
                .environment(\.readerShelfDrag, queueDrag)
        case .menu:
            TextualMenuPage(repository: repository, account: account,
                            legacyBookCount: legacyBookCount, importLegacy: importLegacy,
                            openArchive: { selectedTab = .library })
        case .stats:
            TextualStatsPage()
        case .profile:
            ReaderProfileView(account: account)
        case .home:
            DiscoverView(repository: repository, isActive: selectedTab == .home,
                         openCommunity: { selectedTab = .community })
        case .community:
            CommunityView(isActive: selectedTab == .community)
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

    @Environment(\.readingLibrary) private var readingLibrary
    private var recordedYears: [Int] { readingLibrary?.snapshot.years ?? [] }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.inkwell.ignoresSafeArea()
                ScrollView {
                    CachedReadingStatsCharts(books: books, filter: statsFilter)
                    .padding(.horizontal, TextualLayout.pageInset)
                    .padding(.top, 12)
                    .padding(.bottom, TextualNavigationLayout.bottomExtent + 24)
                }
                .scrollIndicators(.hidden)
                .textualPageHeader {
                    TextualHeader(title: "STATS") {
                        HStack(spacing: TextualLayout.itemGap) {
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
                    }
                }
            }
            .textualDropdownHost()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: recordedYears) { _, years in
                if readingLibrary?.isReady == true, let selectedYear, !years.contains(selectedYear) { self.selectedYear = nil }
            }
        }
    }


}

enum TextualTab: String, CaseIterable, Identifiable {
    case profile, library, stats, home, community, menu

    var id: String { rawValue }
    var title: String { self == .library ? "My Archive" : rawValue.capitalized }
    var icon: DesignSystemIcon {
        switch self {
        case .profile: return .profile
        case .stats: return .stats
        case .library: return .archive
        case .home: return .home
        case .community: return .people
        case .menu: return .menu
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
                    DesignSystemIconView(.remove, size: TextualIconStyle.navigation.size)
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
                    .fill(dragging && shelfDrag?.isOverTrash == true ? Color.bloodletter : Color.controlSurface)
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

    private func tabIcon(_ tab: TextualTab) -> some View {
        DesignSystemIconView(tab.icon)
    }

}

/// Existing account tools remain reachable while the rest of Menu is still unbuilt.
private struct TextualMenuPage: View {
    let repository: LibraryRepository
    let account: AccountSession
    let legacyBookCount: Int
    let importLegacy: (() async throws -> Void)?
    let openArchive: () -> Void
    @State private var openArchiveAfterImport = false
    @State private var showImport = false
    @State private var showAccount = false
    @State private var showPrivacy = false
    @Environment(\.socialStore) private var social
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
                        menuRow("Privacy & sharing") { showPrivacy = true }
                            .accessibilityIdentifier("menu.privacy")
                        Divider().overlay(Color.velvet)
                    }
                    .frame(maxWidth: 480)
                    .padding(TextualLayout.pageInset)
                    .padding(.bottom, TextualNavigationLayout.bottomExtent)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .textualPageTitle("Menu")
            .sheet(isPresented: $showImport, onDismiss: {
                if openArchiveAfterImport {
                    openArchiveAfterImport = false
                    openArchive()
                }
            }) {
                StoryGraphImportView(repository: repository, accountEmail: account.email,
                                     openArchive: { openArchiveAfterImport = true })
            }
            .sheet(isPresented: $showPrivacy) {
                SocialPrivacySettingsView().environment(\.socialStore, social)
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
                .presentationBackground(Color.inkwell)
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
                .font(.designSystem(.bodyMedium))
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}
