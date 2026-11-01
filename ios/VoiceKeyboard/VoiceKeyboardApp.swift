import SwiftUI

@main
struct VoiceKeyboardApp: App {
    @StateObject private var session = DictationSession.shared
    @StateObject private var mac = MacConnection()
    @StateObject private var returner = ReturnController.shared
    @State private var openedFromKeyboard = false

    init() {
        // Must start at launch: the app the keyboard was in shows up about a second after
        // the keyboard opens us, and is cleared soon after.
        HostAppObserver.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(openedFromKeyboard: $openedFromKeyboard)
                .environmentObject(session)
                .environmentObject(mac)
                .environmentObject(returner)
                .onOpenURL { url in
                    guard url.scheme == "voicekb" else { return }
                    // voicekb://pair?url=…&token=… comes from the QR code on the Mac dashboard.
                    if mac.pair(with: url) { return }
                    // voicekb://open is the keyboard's open-app button: just show the app.
                    guard url.host == "start" else { return }
                    // voicekb://start comes from the keyboard when no session is running:
                    // start the mic, start recording, then go back to the user's app.
                    let invokedAt = Date()
                    openedFromKeyboard = !session.testingInApp
                    let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "host" })?.value
                    DebugLog.log("opened by keyboard, keyboard saw host=\(host ?? "unknown")")
                    Task {
                        await session.startSession()
                        guard session.isActive else { return }
                        session.beginRecordingFromKeyboard()
                        if !session.testingInApp {
                            returner.returnToHost(keyboardHost: host, invokedAt: invokedAt)
                        }
                    }
                }
        }
    }
}
