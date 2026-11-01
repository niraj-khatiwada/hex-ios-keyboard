import SwiftUI
import UIKit

/// Ends editing when you tap anywhere outside a text field. Taps still reach the
/// buttons and rows underneath.
struct TapToDismissKeyboard: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        // Attach to the window once the view is in the hierarchy.
        DispatchQueue.main.async { context.coordinator.install(in: view.window) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?

        func install(in window: UIWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        @objc private func dismiss() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Let taps inside a text field move the cursor instead of dismissing.
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
