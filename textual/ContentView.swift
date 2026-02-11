//
//  ContentView.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
