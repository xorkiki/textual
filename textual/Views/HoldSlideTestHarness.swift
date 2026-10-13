#if DEBUG
import SwiftUI

/// Deterministic, local-only UI test surface. Never loads an account or its library.
struct HoldSlideTestHarness: View {
    @State private var result = "none"
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--archive-status-ui-test") {
            ArchiveStatusTestHarness()
        } else { gestureHarness }
    }
    private var gestureHarness: some View {
        VStack(spacing: 0) {
            Text(result).accessibilityIdentifier("hold.result").frame(height: 50)
            ScrollView {
                VStack(spacing: 24) {
                    Color.clear.frame(height: 140)
                    ScrollView(.horizontal) {
                        HStack(spacing: 20) {
                            ForEach(0..<8) { index in
                                HoldSlideSource(actions: BookQuickAction.allCases.map(\.menuAction), isEnabled: true,
                                                open: { result = "tap:\(index)" },
                                                select: { result = "\($0):\(index)" }) {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.moss)
                                        .overlay(Text("Book \(index)").foregroundStyle(Color.paper))
                                }
                                .frame(width: 100, height: 155)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Book \(index)")
                                .accessibilityIdentifier("hold.book.\(index)")
                            }
                        }.padding(.horizontal, 24)
                    }
                    ForEach(0..<20) { index in
                        Text("Shelf row \(index)").frame(height: 70)
                            .accessibilityIdentifier("hold.row.\(index)")
                    }
                }
            }
        }.background(Color.inkwell).foregroundStyle(Color.paper)
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.arguments.contains("--opaque-menu-ui-test") {
                Button { result = "menu:tap" } label: {
                    Text("Menu test book").padding(24).background(Color.moss)
                }
                .buttonStyle(.plain)
                .textualContextMenu {
                    Button("Disabled action") { result = "menu:disabled" }.disabled(true)
                    Button("Remove", role: .destructive) { result = "menu:remove" }
                }
                .accessibilityIdentifier("menu.source")
                .padding(24)
                .background(Color.inkwell)
            }
        }
    }
}
private struct ArchiveStatusTestHarness: View {
    @State private var result = "none"
    @State private var choosing = false
    @State private var model = AddBookViewModel()
    private let item = BookCatalogService.BookItem(id: "archive-fixture", volumeInfo: nil)
    var body: some View {
        VStack {
            Text(result).accessibilityIdentifier("archive.result")
            ScrollView {
                Color.clear.frame(height: 180)
                BookSearchResultRow(item: item, viewModel: model, onTap: { choosing = true },
                                    onChooseStatus: { result = $0.rawValue })
                    .padding(.horizontal, 24)
                ForEach(0..<20) { index in Text("Row \(index)").frame(height: 70) }
            }
        }
        .foregroundStyle(Color.paper).background(Color.inkwell)
        .sheet(isPresented: $choosing) {
            ArchiveStatusChooser(title: "Test book") {
                result = $0.rawValue
                choosing = false
            }.presentationDetents([.medium, .large])
        }
    }
}
#endif
