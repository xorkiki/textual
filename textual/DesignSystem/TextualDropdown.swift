import SwiftUI
import UIKit
import Observation

struct TextualDropdownOption<Value: Hashable>: Equatable {
    let value: Value
    let title: String
    var accessibilityTitle: String? = nil
}

/// Shared dropdown trigger; the host draws the menu above scrolling content.
struct TextualDropdown<Value: Hashable>: View {
    let label: String
    let title: String
    let options: [TextualDropdownOption<Value>]
    @Binding var selection: Value
    @Environment(TextualDropdownState.self) private var menu
    @State private var id = UUID()

    var body: some View {
        Button {
            if menu.activeID == id { menu.dismiss() }
            else {
                menu.items = options.enumerated().map { index, option in
                    TextualDropdownState.Item(id: index, title: option.title,
                        accessibilityTitle: option.accessibilityTitle ?? option.title,
                        selected: option.value == selection, action: { selection = option.value })
                }
                menu.label = label
                menu.activeID = id
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.custom("PlusJakartaSans-Regular", size: 14, relativeTo: .body))
                Image(systemName: menu.activeID == id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color.velvet.opacity(0.35), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: TextualDropdownAnchors.self, value: .bounds) { [id: $0] }
        .accessibilityLabel(label)
        .accessibilityValue(options.first(where: { $0.value == selection }).map { $0.accessibilityTitle ?? $0.title } ?? title)
        .accessibilityHint("Opens options")
        .onChange(of: options) { _, _ in if menu.activeID == id { menu.dismiss() } }
        .onDisappear { if menu.activeID == id { menu.dismiss() } }
    }
}

@Observable
private final class TextualDropdownState {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let accessibilityTitle: String
        let selected: Bool
        let action: () -> Void
    }
    var activeID: UUID?
    var label = ""
    var items: [Item] = []
    func dismiss() { activeID = nil; items = [] }
}

private struct TextualDropdownAnchors: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TextualDropdownHost: ViewModifier {
    @State private var menu = TextualDropdownState()
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44

    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(menu)
                .accessibilityHidden(menu.activeID != nil)
        }
            .overlayPreferenceValue(TextualDropdownAnchors.self) { anchors in
                GeometryReader { geometry in
                    if let id = menu.activeID, let anchor = anchors[id] {
                        let source = geometry[anchor]
                        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for:
                            UIFont(name: "PlusJakartaSans-Regular", size: 14) ?? .systemFont(ofSize: 14))
                        let labelWidth = menu.items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                        let width = min(max(source.width, ceil(labelWidth) + 96), max(0, geometry.size.width - 32))
                        let below = max(0, geometry.size.height - source.maxY - 24)
                        let above = max(0, source.minY - 24)
                        let desiredHeight = min(CGFloat(menu.items.count) * rowHeight + 16, 360)
                        let opensBelow = below >= desiredHeight || below >= above
                        let height = min(desiredHeight, opensBelow ? below : above)
                        let x = min(max(16, source.minX), max(16, geometry.size.width - width - 16))
                        let y = opensBelow ? source.maxY + 8 : source.minY - height - 8
                        let backdropTop = opensBelow ? source.maxY : max(0, y - 16)
                        let backdropHeight = opensBelow ? height + 24 : source.minY - backdropTop
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.2)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { menu.dismiss() }
                                .accessibilityLabel("Dismiss \(menu.label) options")
                                .accessibilityAddTraits(.isButton)
                            Color.clear
                                .frame(height: backdropHeight)
                                .background(Color.inkwell)
                                .overlay(alignment: opensBelow ? .bottom : .top) {
                                    TextualChromeFade(edge: opensBelow ? .top : .bottom)
                                        .frame(height: 64)
                                        .offset(y: opensBelow ? 64 : -64)
                                }
                                .offset(y: backdropTop)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(menu.items) { item in
                                        Button {
                                            let action = item.action
                                            menu.dismiss()
                                            action()
                                        } label: {
                                            HStack(spacing: 12) {
                                                Text(item.title)
                                                    .font(.custom("PlusJakartaSans-Regular", size: 14, relativeTo: .body))
                                                    .lineLimit(1)
                                                    .layoutPriority(1)
                                                Spacer(minLength: 8)
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .opacity(item.selected ? 1 : 0)
                                                    .accessibilityHidden(true)
                                            }
                                            .foregroundStyle(Color.paper)
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .frame(minHeight: rowHeight)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(item.selected ? Color.bloodletterFaded : .clear,
                                                        in: Capsule())
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(item.accessibilityTitle)
                                        .accessibilityAddTraits(item.selected ? [.isSelected] : [])
                                        .id(item.id)
                                    }
                                }
                                .padding(8)
                            }
                            .scrollIndicators(.hidden)
                            .frame(width: width, height: height)
                            .background(LinearGradient(colors: [.dropdownSurface, .inkwell],
                                startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 20))
                            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.ghost.opacity(0.16), lineWidth: 1).allowsHitTesting(false) }
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                            .accessibilityIdentifier("textual.dropdown.options")
                            .accessibilityAction(.escape) { menu.dismiss() }
                            .offset(x: x, y: max(8, y))
                        }
                    }
                }
            }
    }
}

extension View {
    func textualDropdownHost() -> some View { modifier(TextualDropdownHost()) }
}
