import UIKit

/// Keyboard-side logic. Keyboards can't use the microphone, so recording happens in the
/// app: we signal it with Darwin notifications and poll its state from the App Group.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Phase: Equatable {
        case idle, opening, starting, recording, transcribing
        case message(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var sessionAlive = false

    var hasFullAccess: () -> Bool = { false }
    var openApp: (URL) -> Void = { _ in }
    var insertText: (String) -> Void = { _ in }

    private var poll: Timer?
    private var awaitingSince: Date?
    private var baselineResultID: String?
    private var sawAppWorking = false
    private var startRequestedAt: Date?
    private var baselineStartCount = 0
    // Keyboards can only play haptics with Full Access, which recording already needs.
    private let startHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let stopHaptic = UIImpactFeedbackGenerator(style: .light)

    func appear() {
        if hasFullAccess() { AppGroup.markKeyboardFullAccess() }
        startHaptic.prepare()
        stopHaptic.prepare()
        // Don't re-insert a result from before this keyboard was shown.
        baselineResultID = AppGroup.readState().resultID
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func disappear() {
        if phase == .recording || phase == .starting { DarwinNotifications.shared.post(.cancel) }
        poll?.invalidate()
        poll = nil
        phase = .idle
    }

    func pressBegan() {
        guard hasFullAccess() else {
            phase = .message("Turn on Allow Full Access for hex-ios-keyboard in Settings")
            return
        }
        let state = AppGroup.readState()
        guard state.isSessionAlive else {
            phase = .opening
            openApp(AppURL.startSession)
            return
        }
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

    func pressEnded() {
        guard phase == .recording || phase == .starting else {
            if phase == .opening { phase = .message("Starting the mic… tap ◀ to come back, then hold again") }
            return
        }
        if phase == .recording {
            stopHaptic.impactOccurred()
            startHaptic.prepare()
        }
        phase = .transcribing
        awaitingSince = Date()
        DarwinNotifications.shared.post(.stop)
    }

    private func refresh() {
        let state = AppGroup.readState()
        sessionAlive = state.isSessionAlive
        level = phase == .recording ? state.level : 0

        if phase == .opening, sessionAlive {
            phase = .message("Mic ready — hold to talk")
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
            phase = .message("Mic session ended — hold again to restart")
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
