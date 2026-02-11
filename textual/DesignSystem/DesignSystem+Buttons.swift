//
//  DesignSystem+Buttons.swift
//  textual
//
//  Created by kiki o on 1/26/26.
//

import SwiftUI

// MARK: - Filled Button
struct FilledButton: View {
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .textStyle(.uiButton)
                .foregroundColor(.inkwell)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.paper)
                .cornerRadius(8)
        }
    }
}

// MARK: - Tonal Button
struct TonalButton: View {
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .textStyle(.uiButton)
                .foregroundColor(.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.bloodletterFaded)
                .cornerRadius(8)
        }
    }
}

// MARK: - Icon Button
struct IconButton: View {
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(.paper)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Button Style Modifiers
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.uiButton)
            .foregroundColor(.inkwell)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.paper)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

struct TonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.uiButton)
            .foregroundColor(.paper)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.bloodletterFaded)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .regular))
            .foregroundColor(.paper)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - View Extensions
extension View {
    func filledButtonStyle() -> some View {
        self.buttonStyle(FilledButtonStyle())
    }
    
    func tonalButtonStyle() -> some View {
        self.buttonStyle(TonalButtonStyle())
    }
    
    func iconButtonStyle() -> some View {
        self.buttonStyle(IconButtonStyle())
    }
}
