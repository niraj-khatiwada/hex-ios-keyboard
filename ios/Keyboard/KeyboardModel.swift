import UIKit

/// Keyboard-side logic. Keyboards can't use the microphone, so recording happens in the
/// app: we signal it with Darwin notifications and poll its state from the App Group.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Phase: Equatable {
        case idle, opening, starting, recording, transcribing
        case message(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { DebugLog.log("phase \(oldValue) → \(phase)") } }
    }
    @Published private(set) var level: Float = 0
    @Published private(set) var sessionAlive = false

    var hasFullAccess: () -> Bool = { false }
    var openApp: (URL) -> Void = { _ in }
    var hostBundleID: () -> String? = { nil }
    var insertText: (String) -> Void = { _ in }

    private var poll: Timer?
    private var awaitingSince: Date?
    private var baselineResultID: String?
    private var sawAppWorking = false
    private var startRequestedAt: Date?
    /// The current recording was started by the app (after the keyboard opened it).
    private var adoptedRecording = false
    private var baselineStartCount = 0
    // Keyboards can only play haptics with Full Access, which recording already needs.
    private let startHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let stopHaptic = UIImpactFeedbackGenerator(style: .light)

    private var isListening: Bool { phase == .recording || phase == .starting }

    func appear() {
        if hasFullAccess() { AppGroup.markKeyboardFullAccess() }
        let s = AppGroup.readState()
        DebugLog.log("appear fullAccess=\(hasFullAccess()) sessionAlive=\(s.isSessionAlive) heartbeatAge=\(s.heartbeat.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none") appPhase=\(s.phase)")
        startHaptic.prepare()
        stopHaptic.prepare()
        // Don't re-insert a result from before this keyboard was shown.
        baselineResultID = s.resultID
        refresh()
        // React the moment the app changes phase; the timer below only drives the level meter
        // and catches the app going away.
        DarwinNotifications.shared.observe(.stateChanged) { [weak self] in self?.refresh() }
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func disappear() {
        // Hiding the keyboard abandons a recording it started. One the app started keeps going:
        // the keyboard is hidden precisely because the app is opening.
        if isListening, !adoptedRecording { DarwinNotifications.shared.post(.cancel) }
        poll?.invalidate()
        poll = nil
        phase = .idle
    }

    // MARK: Taps

    /// Tap to start listening, tap again to stop and send.
    func tap() {
        if isListening {
            stop()
        } else if phase != .transcribing, phase != .opening {
            start()
        }
    }

    /// Opens the app's settings screen without starting a session.
    func openSettingsApp() {
        openApp(AppURL.open)
    }

    /// Ends the session so the mic (and the orange dot) turns off.
    func turnOffMic() {
        if isListening { DarwinNotifications.shared.post(.cancel) }
        DarwinNotifications.shared.post(.endSession)
        phase = .idle
        sessionAlive = false
    }

    // MARK: Start / stop

    private func start() {
        guard hasFullAccess() else {
            phase = .message("Turn on Allow Full Access for hex-ios-keyboard in Settings")
            return
        }
        let state = AppGroup.readState()
        DebugLog.log("start sessionAlive=\(state.isSessionAlive) heartbeatAge=\(state.heartbeat.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "none")")
        guard state.isSessionAlive else {
            // The app starts the mic, starts recording, and sends the user back here.
            phase = .opening
            openApp(AppURL.startSession(host: hostBundleID()))
            return
        }
        adoptedRecording = false
        baselineResultID = state.resultID
        awaitingSince = nil
        sawAppWorking = false
        // Wait for the app to report the mic is on before saying "Listening".
        baselineStartCount = state.startCount
        startRequestedAt = Date()
        startHaptic.prepare()
        phase = .starting
        DarwinNotifications.shared.post(.start)
    }

    private func stop() {
        guard isListening else { return }
        if phase == .recording {
            stopHaptic.impactOccurred()
            startHaptic.prepare()
        }
        phase = .transcribing
        awaitingSince = Date()
        DarwinNotifications.shared.post(.stop)
    }

    // MARK: Polling

    private func refresh() {
        let state = AppGroup.readState()
        sessionAlive = state.isSessionAlive
        level = phase == .recording ? state.level : 0

        // The app started recording on its own after the keyboard opened it: take it over.
        if sessionAlive, state.phase == .recording, awaitingSince == nil, !isListening, phase != .transcribing {
            DebugLog.log("adopting recording started by the app")
            adoptedRecording = true
            baselineResultID = state.resultID
            phase = .recording
            startHaptic.impactOccurred()
            stopHaptic.prepare()
        }

        if phase == .starting, let requested = startRequestedAt {
            if state.startCount > baselineStartCount {
                if state.phase == .recording {
                    phase = .recording
                    startHaptic.impactOccurred()
                    stopHaptic.prepare()
                } else if state.phase == .error {
                    phase = .message(state.errorMessage ?? "The mic didn't start")
                }
            } else if Date().timeIntervalSince(requested) > 3 {
                phase = .message("The mic didn't start — try again")
            }
        }
        if phase == .recording, !sessionAlive {
            phase = .message("Mic session ended — try again to restart it")
        }

        guard let since = awaitingSince else { return }
        if state.phase == .transcribing || state.phase == .recording { sawAppWorking = true }

        if let id = state.resultID, id != baselineResultID {
            baselineResultID = id
            awaitingSince = nil
            phase = .idle
            if let text = state.resultText, !text.isEmpty { insertText(text) }
        } else if state.phase == .error {
            awaitingSince = nil
            phase = .message(state.errorMessage ?? "Something went wrong")
        } else if state.phase == .idle, sawAppWorking || Date().timeIntervalSince(since) > 1.5 {
            // Clip too short, or nothing came back.
            awaitingSince = nil
            phase = .idle
        } else if Date().timeIntervalSince(since) > 35 {
            awaitingSince = nil
            phase = .message("Timed out waiting for your Mac")
        }
    }
}
