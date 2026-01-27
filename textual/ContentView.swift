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
        Text("Library View")
            .font(.largeTitle)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
