import SwiftUI

/// A page's top-level sections (The Archive's Discover tabs, Community's Friends/Feed).
protocol TextualTabItem: CaseIterable, Hashable, Identifiable where AllCases: RandomAccessCollection {
    var title: String { get }
    /// Stable suffix for accessibility identifiers.
    var identifier: String { get }
}

/// The text tab row shared by The Archive and Community. Paired with a horizontal
/// paging ScrollView whose scroll position is the same selection binding.
struct TextualTabBar<Tab: TextualTabItem>: View {
    @Binding var selection: Tab?
    /// For example "discover.tab" produces "discover.tab.forYou".
    let identifierPrefix: String
    var notice: (Tab) -> Bool = { _ in false }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs.frame(maxWidth: .infinity)
            ScrollView(.horizontal) { tabs.padding(.horizontal, TextualLayout.pageInset) }
                .scrollIndicators(.hidden)
        }
        .frame(minHeight: TextualLayout.touchTarget)
    }

    private var tabs: some View {
        HStack(spacing: 28) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.designSystem(.uiButton))
                        .foregroundStyle(selection == tab ? Color.paper : Color.ghost)
                        .fixedSize()
                        .overlay(alignment: .topTrailing) {
                            if notice(tab) {
                                Circle().fill(Color.bloodletter).frame(width: 6, height: 6)
                                    .offset(x: 9, y: -2).accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: TextualLayout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(notice(tab) ? "New updates" : "")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("\(identifierPrefix).\(tab.identifier)")
            }
        }
    }
}
