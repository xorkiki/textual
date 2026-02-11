//
//  AttributedString+HTML.swift
//  textual
//
//  Created by kiki o on 1/30/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension AttributedString {
    /// Renders HTML string to AttributedString with design system paper color, or returns plain text if parsing fails.
    /// Google Books descriptions use simple HTML (b, i, br). We parse and convert, falling back to stripped text.
    init(html: String, color: Color = .paper) {
        if let data = html.data(using: .utf8),
           let nsAttr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ) {
            let mutable = NSMutableAttributedString(attributedString: nsAttr)
            let range = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.foregroundColor, value: UIColor(color), range: range)
            do {
                self = try AttributedString(mutable, including: \.uiKit)
            } catch {
                self = AttributedString(html.strippingHTMLTags)
            }
        } else {
            self = AttributedString(html.strippingHTMLTags)
        }
    }
}

extension String {
    /// Strips HTML tags for fallback plain text
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
