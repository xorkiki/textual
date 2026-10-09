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
    @State private var selectedTab: TextualTab = .discover

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
                .padding(.bottom, TextualNavigationLayout.outerPadding)
                .frame(maxWidth: .infinity)
        }
        // Match the side margin at the physical bottom edge, without adding
        // the home-indicator safe area a second time. Keyboard avoidance stays on.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.inkwell)
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
        case .home, .discover, .stats:
            NavigationStack {
                Color.inkwell.ignoresSafeArea()
                    .textualPageTitle(tab.title)
            }
        }
    }
}

enum TextualNavigationLayout {
    static let itemHeight: CGFloat = 44
    static let innerPadding: CGFloat = 8
    static let outerPadding: CGFloat = 24
    static var bottomExtent: CGFloat { itemHeight + innerPadding * 2 + outerPadding }
}

enum TextualTab: String, CaseIterable, Identifiable {
    case home, library, discover, stats, menu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "My Archive"
        case .discover: return "The Archive"
        default: return rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .library: return "books.vertical"
        case .discover: return "safari"
        case .stats: return "chart.bar"
        case .menu: return "line.3.horizontal"
        }
    }
}

private struct TextualBottomBar: View {
    @Binding var selection: TextualTab

    var body: some View {
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
        .background(Color.velvet.opacity(0.35), in: Capsule())
    }

    @ViewBuilder
    private func tabIcon(_ tab: TextualTab) -> some View {
        switch tab {
        case .home:
            Image(designSystemIcon: .homeSimple)
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
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.inkwell, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title.uppercased())
                        .font(.custom("CormorantGaramond-Regular", size: 28))
                        .foregroundStyle(Color.paper)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}
