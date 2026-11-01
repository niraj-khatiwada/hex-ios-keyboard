import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        DebugLog.log("keyboard loaded, fullAccess=\(hasFullAccess)")

        model.hasFullAccess = { [weak self] in self?.hasFullAccess ?? false }
        model.openApp = { [weak self] url in self?.openContainingApp(url) }
        model.hostBundleID = { [weak self] in self?.detectHostBundleID() }
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

        let height = view.heightAnchor.constraint(equalToConstant: 290)
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
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() }
        )
    }

    /// The app being typed in. iOS 26.4+ hides this from keyboards, so it's often nil; the app
    /// then falls back to the status bar's back link.
    private func detectHostBundleID() -> String? {
        let candidates: [NSObject?] = [self, parent, view.window?.rootViewController]
        for object in candidates.compactMap({ $0 }) {
            for key in ["_hostBundleID", "_hostApplicationBundleIdentifier"] {
                let selector = NSSelectorFromString(key)
                if object.responds(to: selector),
                   let id = object.perform(selector)?.takeUnretainedValue() as? String,
                   !id.isEmpty, id != "<null>" {
                    DebugLog.log("host app: \(id) (via \(type(of: object)).\(key))")
                    return id
                }
            }
        }
        DebugLog.log("host app: unknown")
        return nil
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
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var application: NSObject?
        var responder: UIResponder? = self
        while let current = responder, application == nil {
            if current is UIApplication { application = current }
            responder = current.next
        }
        var source = "responder chain"
        if application == nil, let shared = UIApplication.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject {
            application = shared
            source = "sharedApplication"
        }
        guard let application, application.responds(to: selector) else {
            DebugLog.log("openURL failed: no UIApplication found")
            extensionContext?.open(url) { ok in DebugLog.log("extensionContext.open → \(ok)") }
            return
        }
        typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
        let completion: @convention(block) (Bool) -> Void = { ok in DebugLog.log("openURL via \(source) → \(ok)") }
        unsafeBitCast(application.method(for: selector), to: OpenURL.self)(application, selector, url, NSDictionary(), completion)
    }
}
