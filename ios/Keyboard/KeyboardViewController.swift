import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        model.hasFullAccess = { [weak self] in self?.hasFullAccess ?? false }
        model.openApp = { [weak self] url in self?.openContainingApp(url) }
        model.insertText = { [weak self] text in self?.insert(text) }

        let host = UIHostingController(rootView: makeView())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host?.rootView = makeView()
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    private func makeView() -> KeyboardView {
        KeyboardView(
            model: model,
            showsGlobe: needsInputModeSwitchKey,
            onGlobe: { [weak self] in self?.advanceToNextInputMode() },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() }
        )
    }

    /// Adds a space between the existing text and the dictation when needed.
    private func insert(_ text: String) {
        var text = text
        if let last = textDocumentProxy.documentContextBeforeInput?.last,
           !last.isWhitespace,
           let first = text.first, !first.isPunctuation {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
    }

    /// Keyboards have no API to open their app. Find the UIApplication in the responder
    /// chain and call -openURL:options:completionHandler: on it. Fine for a sideloaded app.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                let imp = current.method(for: selector)
                unsafeBitCast(imp, to: OpenURL.self)(current, selector, url, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
