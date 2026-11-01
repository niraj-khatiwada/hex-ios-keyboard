import SwiftUI

@main
struct VoiceKeyboardApp: App {
    @StateObject private var session = DictationSession.shared
    @StateObject private var mac = MacConnection()
    @State private var openedFromKeyboard = false

    var body: some Scene {
        WindowGroup {
            ContentView(openedFromKeyboard: $openedFromKeyboard)
                .environmentObject(session)
                .environmentObject(mac)
                .onOpenURL { url in
                    guard url.scheme == "voicekb" else { return }
                    // voicekb://pair?url=…&token=… comes from the QR code the Mac prints.
                    if mac.pair(with: url) { return }
                    // voicekb://start comes from the keyboard when no session is running.
                    openedFromKeyboard = true
                    Task { await session.startSession() }
                }
        }
    }
}
