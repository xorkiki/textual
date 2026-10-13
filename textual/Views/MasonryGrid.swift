import SwiftUI

/// Column assignment for a masonry grid. Greedy shortest-column placement depends
/// only on earlier items, so appending a page never moves a book already on screen.
enum MasonryLayout {
    /// Item indexes per column, from height ÷ width ratios.
    static func assign(aspects: [Double], columns: Int) -> [[Int]] {
        let count = max(1, columns)
        var result = Array(repeating: [Int](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for (index, aspect) in aspects.enumerated() {
            let column = heights.indices.min { heights[$0] < heights[$1] - 0.0001 } ?? 0
            result[column].append(index)
            heights[column] += max(0.2, min(aspect, 5))
        }
        return result
    }

    /// Extends a previous assignment with new items without changing earlier placements.
    static func extend(_ previous: [[Int]], previousCount: Int, aspects: [Double], columns: Int) -> [[Int]] {
        guard previous.count == columns, previousCount <= aspects.count,
              previous.reduce(0, { $0 + $1.count }) == previousCount else {
            return assign(aspects: aspects, columns: columns)
        }
        var result = previous
        var heights = previous.map { $0.reduce(0.0) { $0 + max(0.2, min(aspects[$1], 5)) } }
        for index in previousCount..<aspects.count {
            let column = heights.indices.min { heights[$0] < heights[$1] - 0.0001 } ?? 0
            result[column].append(index)
            heights[column] += max(0.2, min(aspects[index], 5))
        }
        return result
    }
}

/// Lazy two-column masonry: each column is its own LazyVStack, so only covers near
/// the viewport are built. Heights come from known aspect ratios before any image
/// loads, which keeps the layout still while covers arrive.
struct MasonryGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var columns = 2
    var spacing: CGFloat = TextualLayout.groupGap
    let aspect: (Item) -> Double
    /// Called when a cover near the end of the loaded items appears.
    var onNearEnd: () -> Void = {}
    @ViewBuilder let cell: (Item, CGSize) -> Cell

    @State private var assignment: [[Int]] = []
    @State private var assignedIDs: [Item.ID] = []
    @State private var width: CGFloat = 0

    var body: some View {
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { column in
                LazyVStack(spacing: spacing) {
                    if column < assignment.count {
                        ForEach(assignment[column].filter { $0 < items.count }, id: \.self) { index in
                            let item = items[index]
                            let size = CGSize(width: columnWidth, height: (columnWidth * aspect(item)).rounded())
                            cell(item, size)
                                .frame(width: size.width, height: size.height)
                                .onAppear { if index >= items.count - 6 { onNearEnd() } }
                        }
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { update() }
        .onChange(of: items.map(\.id)) { _, _ in update() }
    }

    private func update() {
        let ids = items.map(\.id)
        let aspects = items.map(aspect)
        if assignedIDs.count <= ids.count, Array(ids.prefix(assignedIDs.count)) == assignedIDs, !assignedIDs.isEmpty {
            assignment = MasonryLayout.extend(assignment, previousCount: assignedIDs.count, aspects: aspects, columns: columns)
        } else {
            assignment = MasonryLayout.assign(aspects: aspects, columns: columns)
        }
        assignedIDs = ids
    }
}
