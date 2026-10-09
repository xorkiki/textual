//
//  Secrets.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation

enum Secrets {
    /// Optional: searches use Open Library until a Google Books project key is configured.
    static var googleBooksAPIKey: String? {
        guard let key = Bundle.main.infoDictionary?["GOOGLE_BOOKS_API_KEY"] as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }

    struct SupabaseConfiguration {
        let url: URL
        let anonKey: String
    }

    /// Only a publishable/anon key belongs in the app. Privileged keys stay on the server.
    static var supabaseConfiguration: SupabaseConfiguration? {
        configuration(from: Bundle.main.infoDictionary ?? [:])
    }

    static func configuration(from info: [String: Any]) -> SupabaseConfiguration? {
        guard let rawURL = info["SUPABASE_URL"] as? String,
              let rawKey = info["SUPABASE_ANON_KEY"] as? String else { return nil }
        let urlText = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.contains("$("), !key.isEmpty, !key.contains("$("),
              let url = URL(string: urlText), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              !key.hasPrefix("sb_secret_") else { return nil }
        if key.split(separator: ".").count == 3 {
            let encoded = String(key.split(separator: ".")[1])
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: padded),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["role"] as? String == "anon" else { return nil }
        } else if !key.hasPrefix("sb_publishable_") { return nil }
        return SupabaseConfiguration(url: url, anonKey: key)
    }
}
