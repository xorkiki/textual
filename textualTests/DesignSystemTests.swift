import XCTest
import SwiftUI
@testable import textual

@MainActor
final class DesignSystemTests: XCTestCase {
    func testEveryRegisteredIconResolvesAndRenders() throws {
        for icon in DesignSystemIcon.allCases {
            if let asset = icon.assetName {
                XCTAssertNotNil(UIImage(named: asset), "Missing icon asset: \(asset)")
            } else if let name = icon.systemName {
                XCTAssertNotNil(UIImage(systemName: name), "Missing fallback symbol: \(name)")
            }
        }
        let gallery = VStack(spacing: 24) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 24) {
                ForEach(DesignSystemIcon.allCases, id: \.self) { icon in
                    VStack(spacing: 8) {
                        DesignSystemIconView(icon, size: 28)
                        Text(icon.rawValue).font(.designSystem(.uiLabel))
                    }
                }
            }
            HStack { RatingView(rating: 0); RatingView(rating: 2.5); RatingView(rating: 5) }
        }.padding(24)
        _ = try render(gallery, width: 390, size: .large, name: "Icon registry")
    }

    func testTypographyScalesAndNativeNavigationUsesSharedTheme() throws {
        let style = DesignSystemFont.heading3
        let normal = UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(
            for: style.baseUIFont, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let accessible = UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(
            for: style.baseUIFont, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThan(accessible.pointSize, normal.pointSize)
        TextualNavigationAppearance.configure()
        let appearance = UINavigationBar.appearance().standardAppearance
        XCTAssertEqual(appearance.backgroundColor, UIColor(Color.inkwell))
        XCTAssertEqual(appearance.titleTextAttributes[.foregroundColor] as? UIColor, UIColor(Color.paper))
        XCTAssertEqual((appearance.titleTextAttributes[.font] as? UIFont)?.fontName, style.baseUIFont.fontName)
    }

    func testHeaderWrapsAtNarrowWidthsAndLargeText() throws {
        let normal = try render(header, width: 320, size: .large, name: "Header — narrow")
        let large = try render(header, width: 320, size: .accessibility3, name: "Header — accessibility")
        XCTAssertEqual(normal.size.width, 320, accuracy: 1)
        XCTAssertEqual(large.size.width, 320, accuracy: 1)
        XCTAssertGreaterThan(large.size.height, normal.size.height)
        XCTAssertLessThan(large.size.height, 500, "Header must remain bounded after wrapping.")
    }

    func testSharedComponentsRenderTogether() throws {
        let gallery = VStack(alignment: .leading, spacing: 20) {
            TextualHeader(title: "PROFILE") {
                Button {} label: { DesignSystemIconView(.preview) }.buttonStyle(IconButtonStyle())
            }
            TextualHeader(title: "MY ARCHIVE") {
                Button {} label: { DesignSystemIconView(.add) }.buttonStyle(IconButtonStyle())
            }
            TextualHeader(title: "STATS") {
                HStack(spacing: TextualLayout.itemGap) {
                    TextualDropdown(label: "Status", title: "Read", options: [.init(value: 0, title: "Read")], selection: .constant(0))
                    TextualDropdown(label: "Period", title: "All time", options: [.init(value: 0, title: "All time")], selection: .constant(0))
                }
            }
            TextualHeader(title: "ALL BOOKS", backAction: {}) {
                Button {} label: { DesignSystemIconView(.add) }.buttonStyle(IconButtonStyle())
            }
            TextualHeader(title: "Add Book") { Button("Done") {} }
            VStack(alignment: .leading, spacing: 16) {
                ReaderLibraryCard(firstName: "Kiki", username: "reader", content:
                    ReaderPublicContent(stats: ReaderCardStats(reads: 42, genres: 8, rereads: 3),
                                        sentence: "drawn to strange worlds and familiar feelings.", favorites: []))
                TextualHeading(title: "Currently reading")
                Text("A shared body style, across every feature.").textStyle(.bodyMedium)
                TextualSearchField("Search your archive", text: .constant(""))
                FilledButton(title: "Continue") {}
                Button("Choose another file") {}.buttonStyle(TextualButtonStyle(variant: .secondary))
            }.padding(.horizontal, TextualLayout.pageInset)
        }
        .padding(.vertical, 20)
        .textualDropdownHost()
        let image = try render(gallery, width: 390, size: .large, name: "Shared components")
        XCTAssertEqual(image.size.width, 390, accuracy: 1)
    }

    private var header: some View {
        TextualHeader(title: "Add to your shelf", backLabel: "Cancel", backAction: {}) {
            Button("Done") {}
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, size: DynamicTypeSize, name: String) throws -> UIImage {
        // Render in a real view hierarchy: ImageRenderer omits UIKit fields and scroll views.
        let controller = UIHostingController(rootView: view
            .textualScreenDefaults()
            .environment(\.dynamicTypeSize, size)
            .frame(width: width)
            .background(Color.inkwell)
            .ignoresSafeArea())
        let fitted = controller.sizeThatFits(in: CGSize(width: width, height: 2000))
        let bounds = CGRect(x: 0, y: 0, width: width, height: ceil(fitted.height))
        let window = UIWindow(frame: bounds)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.frame = bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}
