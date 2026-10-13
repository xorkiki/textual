import Foundation
import Testing
import UIKit

@MainActor
struct AppFontTests {
    @Test
    func designSystemFontsAreBundledAndRegistered() throws {
        let registered = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        let fonts = [
            (name: "PlusJakartaSans-Regular", resource: "PlusJakartaSans-Regular", ext: "ttf"),
            (name: "PlusJakartaSans-Medium", resource: "PlusJakartaSans-Medium", ext: "ttf"),
            (name: "CormorantGaramond-Regular", resource: "CormorantGaramond-Regular", ext: "ttf"),
            (name: "LaLuxesSerifW05-Regular", resource: "LaLuxes", ext: "otf"),
        ]
        for (name, resource, ext) in fonts {
            #expect(registered.contains("\(resource).\(ext)"), "The app must register \(name) in UIAppFonts.")
            _ = try #require(Bundle.main.url(forResource: resource, withExtension: ext), "Missing bundled font: \(name)")
            let font = try #require(UIFont(name: name, size: 17), "UIFont could not load \(name).")
            #expect(font.fontName == name)
        }
    }
}
