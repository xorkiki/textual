import SwiftUI
import UIKit

extension AttributedString {
    /// Catalog descriptions need text formatting, not a web document renderer.
    /// Foundation's HTML importer can run a nested run loop during a SwiftUI update.
    init(html: String, color: Color = .paper, font: DesignSystemFont? = nil) {
        let text = CatalogDescriptionHTML.render(html, color: UIColor(color),
                                                 font: font?.uiFont ?? UIFont.systemFont(ofSize: UIFont.systemFontSize))
        self = (try? AttributedString(text, including: \.uiKit)) ?? AttributedString(text.string)
    }
}

enum CatalogDescriptionHTML {
    private static let tags = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>|</?[a-zA-Z][^>]*>"#,
        options: .caseInsensitive)
    private static let entities = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z][a-zA-Z0-9]+);"#)
    private static let namedEntities = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
        "eacute": "é", "Eacute": "É", "aacute": "á", "ouml": "ö", "uuml": "ü"
    ]

    static func render(_ html: String, color: UIColor, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let source = html as NSString
        let matches = tags.matches(in: html, range: NSRange(location: 0, length: source.length))
        var bold = 0, italic = 0

        func append(_ raw: String) {
            var text = raw
            if !matches.isEmpty {
                text = text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                if result.length == 0 || result.string.hasSuffix("\n") {
                    text = String(text.drop(while: { $0 == " " }))
                }
            }
            var traits = font.fontDescriptor.symbolicTraits
            if bold > 0 { traits.insert(.traitBold) }
            if italic > 0 { traits.insert(.traitItalic) }
            let styledFont = font.fontDescriptor.withSymbolicTraits(traits)
                .map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            result.append(NSAttributedString(string: decodeEntities(text),
                attributes: [.font: styledFont, .foregroundColor: color]))
        }

        func lineBreak(_ count: Int) {
            while result.string.last == " " {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            }
            guard result.length > 0 else { return }
            let existing = result.string.reversed().prefix(while: { $0 == "\n" }).count
            if existing < count {
                result.append(NSAttributedString(string: String(repeating: "\n", count: count - existing),
                    attributes: [.font: font, .foregroundColor: color]))
            }
        }

        var cursor = 0
        for match in matches {
            append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let rawTag = source.substring(with: match.range).lowercased()
            cursor = NSMaxRange(match.range)
            if rawTag.hasPrefix("<!--") || rawTag.hasPrefix("<script") || rawTag.hasPrefix("<style") { continue }
            let closing = rawTag.hasPrefix("</")
            let name = rawTag.dropFirst(closing ? 2 : 1).prefix(while: { $0.isLetter || $0.isNumber })
            switch name {
            case "b", "strong": bold = max(0, bold + (closing ? -1 : 1))
            case "i", "em": italic = max(0, italic + (closing ? -1 : 1))
            case "br": lineBreak(1)
            case "p", "div", "h1", "h2", "h3", "h4", "blockquote", "ul", "ol": lineBreak(2)
            case "li":
                lineBreak(1)
                if !closing { append("• ") }
            default: break
            }
        }
        append(source.substring(from: cursor))
        let visible = (result.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard visible.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = (result.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        return result.attributedSubstring(from: NSRange(location: visible.location, length: NSMaxRange(last) - visible.location))
    }

    /// Imported reviews contain HTML, including entity-escaped spoiler wrappers.
    /// Parse as inert text without invoking a web view or Foundation's HTML importer.
    static func plainReview(_ source: String) -> (body: String, spoilers: Bool) {
        var decoded = source
        // Exports can escape markup more than once. Keep decoding work bounded.
        for _ in 0..<3 {
            let next = decodeEntities(decoded)
            if next == decoded { break }
            decoded = next
        }
        let input = decoded as NSString
        let matches = tags.matches(in: decoded, range: NSRange(location: 0, length: input.length))
        var pieces: [String] = []
        var cursor = 0
        var spoilers = false
        for match in matches {
            pieces.append(input.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let tag = input.substring(with: match.range).lowercased()
            cursor = NSMaxRange(match.range)
            if tag.hasPrefix("<!--") || tag.hasPrefix("<script") || tag.hasPrefix("<style") { continue }
            let closing = tag.hasPrefix("</")
            let name = tag.dropFirst(closing ? 2 : 1).prefix(while: { $0.isLetter || $0.isNumber })
            switch name {
            case "spoiler": spoilers = true
            case "br": pieces.append("\n")
            case "p", "div", "h1", "h2", "h3", "h4", "blockquote", "ul", "ol": pieces.append("\n\n")
            case "li": if !closing { pieces.append("\n• ") }
            default: break
            }
        }
        pieces.append(input.substring(from: cursor))
        let body = pieces.joined()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, spoilers)
    }

    private static func decodeEntities(_ text: String) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in entities.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let entity = source.substring(with: match.range(at: 1))
            let replacement: String?
            if entity.hasPrefix("#") {
                let hex = entity.lowercased().hasPrefix("#x")
                let digits = String(entity.dropFirst(hex ? 2 : 1))
                replacement = UInt32(digits, radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = namedEntities[entity]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

extension String {
    var strippingHTMLTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
