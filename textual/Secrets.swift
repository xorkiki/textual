//
//  Secrets.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import Foundation

enum Secrets {
    static var url: String {
        guard let url = Bundle.main.infoDictionary?["SUPABASE_URL"] as? String else {
            fatalError("SUPABASE_URL not found in Info.plist")
        }
        return url
    }
    
    static var key: String {
        guard let key = Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String else {
            fatalError("SUPABASE_ANON_KEY not found in Info.plist")
        }
        return key
    }
}