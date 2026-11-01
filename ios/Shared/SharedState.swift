import Foundation

/// State the app publishes for the keyboard. Only the app writes it; the keyboard polls it.
struct SharedState: Codable, Equatable {
    enum Phase: String, Codable {
        case idle, recording, transcribing, error
    }

    /// Refreshed by the app every half second while a dictation session is running.
    var heartbeat: Date?
    var phase: Phase = .idle
    /// Input level 0...1 while recording.
    var level: Float = 0
    /// Changes every time a new transcription finishes.
    var resultID: String?
    var resultText: String?
    var errorMessage: String?
    /// Bumped each time the app handles a start signal, so the keyboard can tell a fresh
    /// result from an old one.
    var startCount = 0

    var isSessionAlive: Bool {
        guard let heartbeat else { return false }
        return Date().timeIntervalSince(heartbeat) < 2.5
    }
}

enum AppGroup {
    static let id: String = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
        ?? "group.com.niraj.voicekeyboard"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static var stateURL: URL? {
        containerURL?.appendingPathComponent("state.json")
    }

    static func readState() -> SharedState {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SharedState.self, from: data)
        else { return SharedState() }
        return state
    }

    static func writeState(_ state: SharedState) {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The keyboard can only write here with Full Access, so the file existing means it's on.
    private static var keyboardMarkerURL: URL? {
        containerURL?.appendingPathComponent("keyboard-full-access")
    }

    static func markKeyboardFullAccess() {
        guard let url = keyboardMarkerURL else { return }
        try? Data().write(to: url)
    }

    static var keyboardHasFullAccess: Bool {
        keyboardMarkerURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

/// Commands the keyboard sends to the app.
enum Command: String, CaseIterable {
    case start = "com.niraj.voicekeyboard.start"
    case stop = "com.niraj.voicekeyboard.stop"
    case cancel = "com.niraj.voicekeyboard.cancel"
    /// Turn the mic off and end the session.
    case endSession = "com.niraj.voicekeyboard.endSession"
    /// Sent by the app (not the keyboard) whenever its phase or result changes.
    case stateChanged = "com.niraj.voicekeyboard.stateChanged"
}

/// URL the keyboard opens to wake the app and start a session.
enum AppURL {
    /// Just brings the app to the front.
    static let open = URL(string: "voicekb://open")!

    /// `host` is the bundle ID of the app being typed in, when the keyboard can tell, so the
    /// app can send the user back to it.
    static func startSession(host: String?) -> URL {
        var components = URLComponents(string: "voicekb://start")!
        if let host { components.queryItems = [URLQueryItem(name: "host", value: host)] }
        return components.url!
    }
}
