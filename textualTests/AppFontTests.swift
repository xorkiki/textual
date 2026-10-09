import Foundation
import Testing
import UIKit

@MainActor
struct AppFontTests {
    @Test
    func onboardingFontsAreBundledAndRegistered() throws {
        let registered = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        for name in ["PlusJakartaSans-Regular", "PlusJakartaSans-Medium", "CormorantGaramond-Regular"] {
            #expect(registered.contains("\(name).ttf"), "The app must register \(name) in UIAppFonts.")
            _ = try #require(Bundle.main.url(forResource: name, withExtension: "ttf"), "Missing bundled font: \(name)")
            let font = try #require(UIFont(name: name, size: 17), "UIFont could not load \(name).")
            #expect(font.fontName == name)
        }
    }
}
