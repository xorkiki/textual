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
        // Debug: Print all available font families
        printAvailableFonts()
        configureNavigationBarAppearance()
    }
    
    private func printAvailableFonts() {
        print("🔍 Available Font Families:")
        for family in UIFont.familyNames.sorted() {
            print("  Family: \(family)")
            for name in UIFont.fontNames(forFamilyName: family) {
                if name.contains("Cormorant") || name.contains("Lamar") || name.contains("Jakarta") || name.contains("Special") {
                    print("    - \(name)")
                }
            }
        }
    }
    
    private func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1.0) // inkwell
        
        // Paper color (light) for dark background - #F2F2F2
        let paperColor = UIColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1.0)
        
        // Try to find the correct font name
        let cormorantFont = findFont(containing: "Cormorant") ?? UIFont.systemFont(ofSize: 28, weight: .bold)
        print("📝 Using font: \(cormorantFont.fontName)")
        
        appearance.largeTitleTextAttributes = [
            .font: cormorantFont.withSize(28),
            .foregroundColor: paperColor
        ]
        appearance.titleTextAttributes = [
            .font: cormorantFont.withSize(17),
            .foregroundColor: paperColor
        ]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    private func findFont(containing searchString: String) -> UIFont? {
        for family in UIFont.familyNames {
            for name in UIFont.fontNames(forFamilyName: family) {
                if name.contains(searchString) {
                    return UIFont(name: name, size: 17)
                }
            }
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
