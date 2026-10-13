//
//  textualApp.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

@main
struct textualApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Book.self,
            Tag.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    init() {
        configureNavigationBarAppearance()
    }
    
    private func configureNavigationBarAppearance() {
        TextualNavigationAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--hold-slide-ui-test") {
                HoldSlideTestHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--discover-ui-test") {
                DiscoverTestHarness()
            } else {
                ContentView(legacyContainer: sharedModelContainer)
            }
            #else
            ContentView(legacyContainer: sharedModelContainer)
            #endif
        }
        .modelContainer(sharedModelContainer)
    }
}
