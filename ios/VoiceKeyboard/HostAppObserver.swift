import UIKit

/// Learns which app the user was typing in when the keyboard opened us.
///
/// Since iOS 26.4 a keyboard can't see its host app (`_hostBundleID` reads "<null>"). UIKit in
/// this app still receives it, in `_UIRemoteKeyboards.sharedRemoteKeyboards.currentState
/// .sourceBundleIdentifier`, about a second after the keyboard opens us. The value is cleared
/// soon after, so it's observed from launch rather than polled.
///
/// This is a UIKit implementation detail, not API. Every step is checked; if one is missing the
/// observer stays inert and returns fall back to the swipe-back hint. Same approach as OpenWhispr.
final class HostAppObserver: NSObject {
    static let shared = HostAppObserver()

    private(set) var isAvailable = false
    private var remoteKeyboards: NSObject?
    private var lastBundle: String?
    private var lastObservedAt: Date?
    private var waiters: [UUID: (since: Date, completion: (String?) -> Void)] = [:]

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard remoteKeyboards == nil else { return }
        guard let remoteKeyboardsClass = NSClassFromString("_UIRemoteKeyboards") as? NSObject.Type else {
            DebugLog.log("host observer unavailable: no _UIRemoteKeyboards")
            return
        }
        let sharedSelector = NSSelectorFromString("sharedRemoteKeyboards")
        guard remoteKeyboardsClass.responds(to: sharedSelector),
              let shared = remoteKeyboardsClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
              shared.responds(to: NSSelectorFromString("currentState"))
        else {
            DebugLog.log("host observer unavailable: no sharedRemoteKeyboards.currentState")
            return
        }
        remoteKeyboards = shared
        shared.addObserver(self, forKeyPath: "currentState", options: [.new, .initial], context: nil)
        isAvailable = true
    }

    /// The host seen at or after `since`, if any.
    func latest(since: Date) -> String? {
        guard let lastBundle, let lastObservedAt, lastObservedAt >= since else { return nil }
        return lastBundle
    }

    /// Calls back with the host as soon as it's seen, or nil after `timeout`.
    func waitForHost(since: Date, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let bundle = latest(since: since) {
            completion(bundle)
            return
        }
        guard isAvailable else {
            completion(nil)
            return
        }
        let id = UUID()
        waiters[id] = (since, completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let waiter = self?.waiters.removeValue(forKey: id) else { return }
            waiter.completion(nil)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // A cleared state comes through as NSNull, which doesn't respond and so reads as nil.
        let state = change?[.newKey] as? NSObject
        let selector = NSSelectorFromString("sourceBundleIdentifier")
        let bundle = state?.responds(to: selector) == true
            ? state?.perform(selector)?.takeUnretainedValue() as? String
            : nil
        DispatchQueue.main.async { self.record(bundle) }
    }

    private func record(_ raw: String?) {
        guard let bundle = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !bundle.isEmpty else { return }
        // Typing in our own app (or its keyboard) isn't somewhere to go back to.
        let ownBundle = (Bundle.main.bundleIdentifier ?? "").lowercased()
        let lowered = bundle.lowercased()
        guard lowered != ownBundle, !lowered.hasPrefix(ownBundle + ".") else { return }

        let now = Date()
        lastBundle = bundle
        lastObservedAt = now
        DebugLog.log("host app seen: \(bundle)")
        for (id, waiter) in waiters where now >= waiter.since {
            waiters.removeValue(forKey: id)
            waiter.completion(bundle)
        }
    }
}
