import ObjectiveC
import UIKit

/// Goes back to the app the user was typing in after the keyboard opened us.
///
/// There's no public API for this. Two private routes, tried in order:
/// 1. The status bar's "◀ Notes" back link (UIKit's `_systemNavigationAction`).
/// 2. Opening the host app by bundle ID, if the keyboard could tell us which app that was.
/// Fine for a sideloaded app; if both fail, the user taps ◀ themselves.
@MainActor
enum ReturnToPreviousApp {
    static func now(hostBundleID: String?) {
        logRuntimeHints()
        attempt(remaining: 12, hostBundleID: hostBundleID)
    }

    /// The back link can take a moment to appear after launch, so retry for up to 3 seconds.
    private static func attempt(remaining: Int, hostBundleID: String?) {
        // Right after a URL opens the app it's still `.inactive`; only give up once it's gone.
        if UIApplication.shared.applicationState == .background {
            DebugLog.log("return: app already in the background")
            return
        }
        if sendBackLink() { return }
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                attempt(remaining: remaining - 1, hostBundleID: hostBundleID)
            }
            return
        }
        if let hostBundleID, open(bundleID: hostBundleID) { return }
        DebugLog.log("return: no route worked; user taps ◀")
    }

    // MARK: Route 1 — the "◀ App" back link

    private static func sendBackLink() -> Bool {
        guard let action = systemNavigationAction() else { return false }
        let send = NSSelectorFromString("sendResponseForDestination:")
        guard action.responds(to: send) else {
            DebugLog.log("return: navigation action can't send")
            return false
        }
        let destinations = (action.value(forKey: "destinations") as? [NSNumber]) ?? []
        guard let destination = destinations.first else {
            DebugLog.log("return: navigation action has no destinations")
            return false
        }
        typealias Send = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(action.method(for: send), to: Send.self)(action, send, destination.uintValue)
        DebugLog.log("return: sent back link (destination \(destination))")
        return true
    }

    private static func systemNavigationAction() -> NSObject? {
        let app = UIApplication.shared
        for name in ["_systemNavigationAction", "systemNavigationAction"] {
            let selector = NSSelectorFromString(name)
            if app.responds(to: selector), let action = app.perform(selector)?.takeUnretainedValue() as? NSObject {
                return action
            }
            if let ivar = class_getInstanceVariable(UIApplication.self, name),
               let action = object_getIvar(app, ivar) as? NSObject {
                return action
            }
        }
        // Newer UIKit keeps it on the scene.
        for scene in app.connectedScenes {
            for name in ["_systemNavigationAction", "systemNavigationAction"] {
                let selector = NSSelectorFromString(name)
                if scene.responds(to: selector), let action = scene.perform(selector)?.takeUnretainedValue() as? NSObject {
                    return action
                }
            }
        }
        return nil
    }

    // MARK: Route 2 — open the host app by bundle ID

    private static func open(bundleID: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else {
            DebugLog.log("return: LSApplicationWorkspace unavailable")
            return false
        }
        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else {
            DebugLog.log("return: workspace can't open by bundle ID")
            return false
        }
        let result = workspace.perform(openSelector, with: bundleID)
        let opened = result != nil
        DebugLog.log("return: open \(bundleID) → \(opened)")
        return opened
    }

    // MARK: Diagnostics

    /// Logs what this iOS version exposes, so a failed return tells us what to try next.
    private static func logRuntimeHints() {
        func names(_ cls: AnyClass, matching needle: String) -> [String] {
            var found: [String] = []
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[i]))
                    if name.localizedCaseInsensitiveContains(needle) { found.append(name) }
                }
                free(methods)
            }
            if let ivars = class_copyIvarList(cls, &count) {
                for i in 0..<Int(count) {
                    if let raw = ivar_getName(ivars[i]) {
                        let name = String(cString: raw)
                        if name.localizedCaseInsensitiveContains(needle) { found.append("ivar " + name) }
                    }
                }
                free(ivars)
            }
            return found
        }
        DebugLog.log("hints UIApplication: \(names(UIApplication.self, matching: "navigation"))")
        if let scene = UIApplication.shared.connectedScenes.first {
            DebugLog.log("hints \(type(of: scene)): \(names(type(of: scene), matching: "navigation"))")
        }
    }
}
