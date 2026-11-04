import SwiftUI
import UIKit

@MainActor
enum TextualKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// One passive recognizer per app window. It never consumes buttons, scrolling,
/// text selection, or touches inside the active search field (including Clear).
struct TextualKeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ uiView: Host, context: Context) {}
    static func dismantleUIView(_ uiView: Host, coordinator: ()) { uiView.detach() }

    final class Host: UIView, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private lazy var tap: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            return gesture
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== attachedWindow else { return }
            detach()
            attachedWindow = window
            window?.addGestureRecognizer(tap)
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(tap)
            attachedWindow = nil
        }

        @objc private func dismissKeyboard() { attachedWindow?.endEditing(true) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var ancestor = touch.view
            while let view = ancestor {
                if view is UITextField || view is UITextView || view is UIControl { return false }
                ancestor = view.superview
            }
            guard let window = attachedWindow else { return false }
            return !TextualKeyboardInputRegion.Region.activeRegions.allObjects.contains { region in
                region.isEditing && region.window === window &&
                region.bounds.contains(region.convert(touch.location(in: window), from: window))
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

/// Protect the complete search control while editing, so tapping Clear keeps
/// the keyboard open and switching between fields does not dismiss it.
struct TextualKeyboardInputRegion: UIViewRepresentable {
    var isEditing: Bool
    func makeUIView(context: Context) -> Region { Region() }
    func updateUIView(_ uiView: Region, context: Context) { uiView.isEditing = isEditing }

    final class Region: UIView {
        static let activeRegions = NSHashTable<Region>.weakObjects()
        var isEditing = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            Self.activeRegions.add(self)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

extension View {
    /// Use inside the screen's NavigationStack for number pads and multiline editors.
    func textualKeyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { TextualKeyboard.dismiss() }
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("keyboard.done")
            }
        }
    }
}
