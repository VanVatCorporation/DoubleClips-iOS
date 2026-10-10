import SwiftUI
import UIKit

// MARK: - Lifting a bottom panel above the keyboard
//
// EditingView ignores every safe area (`.ignoresSafeArea()`, keyboard region included) and lays the editing zone out
// at a fixed 300 pt at the bottom of the screen, so SwiftUI never moves it when the keyboard appears and the keyboard
// covered the whole Clip Properties / Edit Text panel. This modifier follows the keyboard's frame and lifts the view
// by the part of the screen the keyboard covers, so the panel sits right above it (the preview behind is overlapped,
// which is fine while a field is being edited). It does nothing while `enabled` is false.

struct KeyboardLift: ViewModifier {
    var enabled: Bool = true
    @State private var lift: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .offset(y: enabled ? -lift : 0)
            .animation(.easeOut(duration: 0.25), value: lift)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
                // The part of the screen from the keyboard's top edge down (0 for a hidden, floating or hardware keyboard).
                lift = max(0, UIScreen.main.bounds.height - end.minY)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                lift = 0
            }
    }
}

extension View {
    /// Lifts the view above the on-screen keyboard (see `KeyboardLift`).
    func keyboardLift(enabled: Bool = true) -> some View {
        modifier(KeyboardLift(enabled: enabled))
    }
}
